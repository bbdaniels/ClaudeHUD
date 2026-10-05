import Foundation

// Pure model + classifier for Claude Code processes. Foundation only, no
// AppKit and no I/O inside `classify`, so the unit tests feed it fixture
// process tables. The live gathering (ps, lsof, the daemon roster and the job
// state files) is `ClaudeProcessSnapshot.capture()` at the bottom.
//
// How the daemon lays processes out (observed 2026-10-05, CLI 2.1.289):
//
//   claude daemon run …                              the supervisor
//     claude bg-pty-host --bg-pty-host …/spare/<x>.pty.sock … --bg-spare …
//       claude bg-spare --bg-spare …/spare/<x>.claim.sock   the worker (REPL)
//   ghostty --title=<project> --command=/tmp/claude-resume-*.sh
//     login → zsh → claude attach <short>                  an attach client
//
// The daemon keeps one unclaimed spare warm (cwd = …/spare, no rv socket).
// Claiming it hands it a session: the worker then holds
// `/tmp/cc-daemon-<uid>/<hash>/rv/<short>.sock` open and moves its cwd into
// the project. A pty-host outlives a daemon restart reparented to launchd
// (ppid 1) and stays in the new daemon's roster, so ppid 1 alone is NOT a
// sign of an orphan: on 2026-10-05 a process that looked orphaned that way
// was a live 8-day monitoring job.

/// One row of `ps -axo pid=,ppid=,rss=,etime=,tty=,command=`.
struct ProcRow: Equatable {
    let pid: Int
    let ppid: Int
    let rssKB: Int
    let elapsed: TimeInterval
    let tty: String
    let command: String
}

/// What a process is, read off its command line alone.
enum ClaudeProcKind: Equatable {
    case daemon
    case ptyHost
    case worker
    case attachClient(String)
    /// Any other `claude …` invocation: an interactive session in a terminal,
    /// `claude -p`, an MCP server, `claude agents`.
    case cli
    case notClaude

    /// argv[0] must be `claude` or a path ending in `/claude` (or the
    /// versioned binary the daemon execs). That excludes Claude.app and its
    /// Electron helpers, whose paths contain "Claude" but are not the CLI.
    static func of(command: String) -> ClaudeProcKind {
        let parts = command.split(separator: " ", omittingEmptySubsequences: true)
        guard let argv0 = parts.first else { return .notClaude }
        let isClaude = argv0 == "claude" || argv0.hasSuffix("/claude")
            || argv0.contains("/.local/share/claude/versions/")
        guard isClaude else { return .notClaude }
        let sub = parts.count > 1 ? String(parts[1]) : ""
        switch sub {
        case "daemon": return .daemon
        case "bg-pty-host": return .ptyHost
        case "bg-spare": return .worker
        case "attach":
            if parts.count > 2 {
                let id = String(parts[2])
                if id.count == 8, id.allSatisfy({ $0.isHexDigit }) { return .attachClient(id.lowercased()) }
            }
            return .cli
        default: return .cli
        }
    }
}

/// The whole process table, indexed for tree walks.
struct ProcessTable: Equatable {
    let rows: [Int: ProcRow]

    init(rows: [ProcRow]) {
        var m: [Int: ProcRow] = [:]
        for r in rows { m[r.pid] = r }
        self.rows = m
    }

    /// Parse `ps -axo pid=,ppid=,rss=,etime=,tty=,command=`. Five leading
    /// whitespace-separated fields, then the command with its spaces intact.
    static func parse(psOutput: String) -> ProcessTable {
        var out: [ProcRow] = []
        for raw in psOutput.split(separator: "\n") {
            var rest = Substring(raw)
            var fields: [Substring] = []
            for _ in 0..<5 {
                rest = rest.drop(while: { $0 == " " || $0 == "\t" })
                guard let sp = rest.firstIndex(where: { $0 == " " || $0 == "\t" }) else { break }
                fields.append(rest[..<sp])
                rest = rest[sp...]
            }
            let cmd = rest.drop(while: { $0 == " " || $0 == "\t" })
            guard fields.count == 5, !cmd.isEmpty,
                  let pid = Int(fields[0]), let ppid = Int(fields[1]),
                  let rss = Int(fields[2]) else { continue }
            out.append(ProcRow(pid: pid, ppid: ppid, rssKB: rss,
                               elapsed: parseEtime(String(fields[3])) ?? 0,
                               tty: String(fields[4]), command: String(cmd)))
        }
        return ProcessTable(rows: out)
    }

    /// `ps` etime: `[[dd-]hh:]mm:ss`.
    static func parseEtime(_ s: String) -> TimeInterval? {
        var days = 0.0
        var clock = Substring(s)
        if let dash = s.firstIndex(of: "-") {
            guard let d = Double(s[..<dash]) else { return nil }
            days = d
            clock = s[s.index(after: dash)...]
        }
        let parts = clock.split(separator: ":").map { Double($0) }
        guard !parts.isEmpty, parts.allSatisfy({ $0 != nil }) else { return nil }
        var secs = 0.0
        for p in parts { secs = secs * 60 + p! }
        return days * 86400 + secs
    }

    func children(of pid: Int) -> [ProcRow] {
        rows.values.filter { $0.ppid == pid }.sorted { $0.pid < $1.pid }
    }

    /// `pid` and every descendant, breadth-first.
    func subtree(of pid: Int) -> [Int] {
        guard rows[pid] != nil else { return [] }
        var kids: [Int: [Int]] = [:]
        for r in rows.values { kids[r.ppid, default: []].append(r.pid) }
        var out = [pid], i = 0
        while i < out.count {
            out += (kids[out[i]] ?? []).sorted()
            i += 1
        }
        return out
    }

    func rssKB(of pids: [Int]) -> Int { pids.reduce(0) { $0 + (rows[$1]?.rssKB ?? 0) } }
}

/// What `lsof` says a worker holds: the rv socket names it (the session's
/// short id) and its cwd.
struct OpenFileFacts: Equatable {
    var rvShort: [Int: String] = [:]
    var cwd: [Int: String] = [:]
    var holdsSpareClaim: Set<Int> = []

    /// Parse `lsof -nP -F pfn` output (`p<pid>`, `f<fd>`, `n<name>` lines).
    static func parse(lsofOutput: String) -> OpenFileFacts {
        var facts = OpenFileFacts()
        var pid: Int?
        var fd = ""
        for raw in lsofOutput.split(separator: "\n") {
            guard let tag = raw.first else { continue }
            let value = String(raw.dropFirst())
            switch tag {
            case "p": pid = Int(value); fd = ""
            case "f": fd = value
            case "n":
                guard let p = pid else { continue }
                if fd == "cwd" {
                    facts.cwd[p] = value
                } else if let short = rvShort(inSocketPath: value) {
                    facts.rvShort[p] = short
                } else if value.contains("/spare/"), value.hasSuffix(".claim.sock") {
                    facts.holdsSpareClaim.insert(p)
                }
            default: continue
            }
        }
        return facts
    }

    /// `/tmp/cc-daemon-501/<hash>/rv/<short>.sock` → `<short>`.
    static func rvShort(inSocketPath path: String) -> String? {
        guard let r = path.range(of: "/rv/"), path.hasSuffix(".sock") else { return nil }
        let name = path[r.upperBound...].dropLast(".sock".count)
        guard name.count == 8, name.allSatisfy({ $0.isHexDigit }) else { return nil }
        return String(name).lowercased()
    }
}

/// One worker entry from `~/.claude/daemon/roster.json`.
struct RosterWorker: Equatable {
    let short: String
    let pid: Int?        // the pty-host
    let replPid: Int?    // the worker
    let cwd: String?
    let sessionId: String?
}

/// `~/.claude/daemon/roster.json`: the daemon's own list of live workers.
struct DaemonRoster: Equatable {
    var supervisorPid: Int?
    var workers: [String: RosterWorker] = [:]

    static func parse(_ data: Data) -> DaemonRoster {
        guard let root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { return DaemonRoster() }
        var r = DaemonRoster(supervisorPid: root["supervisorPid"] as? Int)
        for (short, raw) in (root["workers"] as? [String: Any]) ?? [:] {
            let w = raw as? [String: Any]
            r.workers[short] = RosterWorker(short: short, pid: w?["pid"] as? Int, replPid: w?["replPid"] as? Int,
                                            cwd: w?["cwd"] as? String, sessionId: w?["sessionId"] as? String)
        }
        return r
    }
}

/// The fields of `~/.claude/jobs/<short>/state.json` the menu needs.
struct JobRecord: Equatable {
    let short: String
    let name: String
    let state: String
    let detail: String
    let tempo: String?
    let cwd: String?
    let createdAt: Date?
    let updatedAt: Date?
    let transcriptPath: String?
    let transcriptMtime: Date?

    var isEnded: Bool { Self.endedStates.contains(state.lowercased()) }
    static let endedStates: Set<String> = [
        "done", "completed", "complete", "success", "failed", "error", "errored",
        "crashed", "stopped", "killed", "cancelled", "canceled",
    ]
    /// An ending the user did not ask for. A `stopped`/`done` job ended on
    /// purpose (a closed HUD window stops its session) and is not news.
    var endedBadly: Bool { ["failed", "error", "errored", "crashed"].contains(state.lowercased()) }
}

enum WorkerClass: Equatable {
    /// A `claude attach <short>` client is open on it.
    case attached
    /// A daemon session nobody is attached to, transcript written recently.
    case backgroundJob
    /// The daemon's pre-started, unclaimed worker. Normal, never flagged.
    case warmSpare
    /// An interactive `claude` in a terminal (not daemon-managed).
    case foreground
    case orphan(String)

    var isOrphan: Bool { if case .orphan = self { return true }; return false }
}

struct ClassifiedWorker: Equatable, Identifiable {
    /// The pty-host when there is one, else the worker / CLI process.
    let rootPid: Int
    let workerPid: Int?
    let short: String?
    let cls: WorkerClass
    let cwd: String?
    let age: TimeInterval
    /// RSS of the root and all its descendants (worker, MCP servers, shells).
    let rssKB: Int
    let job: JobRecord?
    /// Every pid Close would signal, with the command it had when classified
    /// so a reused pid is never hit.
    let killList: [ProcRow]

    var id: Int { rootPid }
    var project: String {
        guard let c = cwd, !c.isEmpty else { return short ?? "pid \(rootPid)" }
        return URL(fileURLWithPath: c).lastPathComponent
    }
}

struct ClaudeProcessReport: Equatable {
    var workers: [ClassifiedWorker] = []
    /// Jobs whose record ended badly (crashed/failed) recently and that have
    /// no live worker: shown as ended, never as something to close.
    var recentlyEnded: [JobRecord] = []
    var totalRSSKB = 0
    var processCount = 0
    var scannedAt = Date.distantPast

    var backgroundJobs: [ClassifiedWorker] { workers.filter { $0.cls == .backgroundJob } }
    var orphans: [ClassifiedWorker] { workers.filter { $0.cls.isOrphan } }
    var attached: [ClassifiedWorker] { workers.filter { $0.cls == .attached } }
    var warmSpares: [ClassifiedWorker] { workers.filter { $0.cls == .warmSpare } }
}

enum ClaudeProcessClassifier {
    /// A background job whose transcript has not moved for this long is
    /// flagged. Flagged, never closed: Close is always a confirmed click.
    static let staleTranscriptAge: TimeInterval = 24 * 3600
    /// How long a crashed/failed job stays visible as "ended".
    static let endedVisibleFor: TimeInterval = 24 * 3600

    /// - Parameters:
    ///   - jobs: state records by short id; must include every short that the
    ///     table's workers resolve to (the capture reads exactly those) and,
    ///     for `recentlyEnded`, any recently updated job.
    ///   - daemonPid: the live supervisor's pid when known.
    static func classify(table: ProcessTable, files: OpenFileFacts, roster: DaemonRoster,
                         jobs: [String: JobRecord], daemonPid: Int?, now: Date) -> ClaudeProcessReport {
        var report = ClaudeProcessReport(scannedAt: now)

        var kind: [Int: ClaudeProcKind] = [:]
        var attachedShorts = Set<String>()
        for r in table.rows.values {
            let k = ClaudeProcKind.of(command: r.command)
            guard k != .notClaude else { continue }
            kind[r.pid] = k
            if case .attachClient(let s) = k { attachedShorts.insert(s) }
        }

        // Footer total: every claude process plus everything below one (MCP
        // servers, tool shells), each pid counted once.
        var counted = Set<Int>()
        for pid in kind.keys { counted.formUnion(table.subtree(of: pid)) }
        report.processCount = counted.count
        report.totalRSSKB = table.rssKB(of: Array(counted))

        let rosterByRepl = Dictionary(roster.workers.values.compactMap { w in w.replPid.map { ($0, w) } },
                                      uniquingKeysWith: { a, _ in a })
        let rosterByHost = Dictionary(roster.workers.values.compactMap { w in w.pid.map { ($0, w) } },
                                      uniquingKeysWith: { a, _ in a })
        let liveDaemon = daemonPid ?? roster.supervisorPid

        // Units: each pty-host with its worker; a worker with no pty-host
        // parent stands alone.
        var units: [(root: ProcRow, worker: ProcRow?)] = []
        for r in table.rows.values where kind[r.pid] == .ptyHost {
            units.append((r, table.children(of: r.pid).first { kind[$0.pid] == .worker }))
        }
        for r in table.rows.values where kind[r.pid] == .worker {
            if let p = table.rows[r.ppid], kind[p.pid] == .ptyHost { continue }
            units.append((r, r))
        }

        for (root, worker) in units {
            let w = worker
            let short = w.flatMap { files.rvShort[$0.pid] }
                ?? w.flatMap { rosterByRepl[$0.pid]?.short }
                ?? rosterByHost[root.pid]?.short
            let job = short.flatMap { jobs[$0] }
            let rosterEntry = short.flatMap { roster.workers[$0] }
            let cwd = job?.cwd ?? rosterEntry?.cwd ?? w.flatMap { files.cwd[$0.pid] }
            let pids = table.subtree(of: root.pid)
            let cls: WorkerClass
            if let short {
                if attachedShorts.contains(short) {
                    cls = .attached
                } else if job == nil {
                    cls = .orphan("daemon worker with no job record")
                } else if let m = job?.transcriptMtime, now.timeIntervalSince(m) > staleTranscriptAge {
                    cls = .orphan("no transcript activity for \(Self.ageString(now.timeIntervalSince(m)))")
                } else if job?.transcriptMtime == nil, (w?.elapsed ?? root.elapsed) > staleTranscriptAge {
                    cls = .orphan("no transcript found")
                } else {
                    cls = .backgroundJob
                }
            } else if w == nil {
                cls = root.ppid == 1 ? .orphan("pty host with no worker") : .warmSpare
            } else {
                // Unclaimed spare. The live daemon's own spare is normal; one
                // left by a dead daemon (host reparented to launchd, or under
                // some other supervisor) is not.
                let underLiveDaemon = liveDaemon.map { root.ppid == $0 } ?? (root.ppid != 1)
                cls = underLiveDaemon ? .warmSpare : .orphan("spare left by a previous daemon")
            }
            report.workers.append(ClassifiedWorker(
                rootPid: root.pid, workerPid: w?.pid, short: short, cls: cls, cwd: cwd,
                age: (w ?? root).elapsed, rssKB: table.rssKB(of: pids), job: job,
                killList: pids.compactMap { table.rows[$0] }))
        }

        // Interactive CLIs. Only one whose terminal is gone (no tty, parent
        // is launchd) is flagged. Children of another claude (MCP servers,
        // subagents) are part of that claude, not sessions.
        for r in table.rows.values where kind[r.pid] == .cli {
            if let p = kind[r.ppid], p != .notClaude { continue }
            guard Self.looksInteractive(r.command) else { continue }
            let pids = table.subtree(of: r.pid)
            let orphaned = r.ppid == 1 && (r.tty == "??" || r.tty.isEmpty)
            report.workers.append(ClassifiedWorker(
                rootPid: r.pid, workerPid: r.pid, short: nil,
                cls: orphaned ? .orphan("terminal gone") : .foreground,
                cwd: files.cwd[r.pid], age: r.elapsed, rssKB: table.rssKB(of: pids), job: nil,
                killList: pids.compactMap { table.rows[$0] }))
        }

        let live = Set(report.workers.compactMap(\.short))
        report.recentlyEnded = jobs.values
            .filter { !live.contains($0.short) && $0.endedBadly }
            .filter { j in (j.updatedAt ?? j.createdAt).map { now.timeIntervalSince($0) < endedVisibleFor } ?? false }
            .sorted { ($0.updatedAt ?? .distantPast) > ($1.updatedAt ?? .distantPast) }

        report.workers.sort { a, b in
            if a.project.lowercased() != b.project.lowercased() { return a.project.lowercased() < b.project.lowercased() }
            return a.rootPid < b.rootPid
        }
        return report
    }

    /// `claude`, `claude --resume …`, `claude "prompt"`: a session someone
    /// typed into a terminal. Excludes one-shot and tooling subcommands.
    static func looksInteractive(_ command: String) -> Bool {
        let parts = command.split(separator: " ").map(String.init)
        guard parts.count >= 1 else { return false }
        if parts.contains("-p") || parts.contains("--print") { return false }
        let tooling: Set<String> = ["mcp", "agents", "logs", "stop", "kill", "rm", "respawn", "doctor",
                                    "config", "update", "install", "setup-token", "plugin", "--version", "-v"]
        if parts.count > 1, tooling.contains(parts[1]) { return false }
        return true
    }

    static func ageString(_ t: TimeInterval) -> String {
        let s = max(0, Int(t))
        if s < 60 { return "\(s)s" }
        if s < 3600 { return "\(s / 60)m" }
        if s < 86400 { return "\(s / 3600)h" }
        let d = s / 86400, h = (s % 86400) / 3600
        return h > 0 ? "\(d)d \(h)h" : "\(d)d"
    }

    static func memoryString(kb: Int) -> String {
        let mb = Double(kb) / 1024
        return mb >= 1024 ? String(format: "%.1f GB", mb / 1024) : String(format: "%.0f MB", mb)
    }
}

// MARK: - Live capture

enum ClaudeProcessSnapshot {
    static var claudeDir: URL {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".claude", isDirectory: true)
    }
    static var rosterFile: URL { claudeDir.appendingPathComponent("daemon/roster.json") }
    static var jobsDir: URL { claudeDir.appendingPathComponent("jobs", isDirectory: true) }

    static func readRoster() -> DaemonRoster {
        (try? Data(contentsOf: rosterFile)).map(DaemonRoster.parse) ?? DaemonRoster()
    }

    /// The live supervisor, from `~/.claude/daemon.lock`.
    static func readDaemonPid() -> Int? {
        guard let data = try? Data(contentsOf: claudeDir.appendingPathComponent("daemon.lock")),
              let o = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let pid = o["pid"] as? Int, kill(pid_t(pid), 0) == 0 else { return nil }
        return pid
    }

    static func processTable() -> ProcessTable {
        ProcessTable.parse(psOutput: run("/bin/ps", ["-axo", "pid=,ppid=,rss=,etime=,tty=,command="]))
    }

    static func openFiles(pids: [Int]) -> OpenFileFacts {
        guard !pids.isEmpty else { return OpenFileFacts() }
        let list = pids.map(String.init).joined(separator: ",")
        return OpenFileFacts.parse(lsofOutput: run("/usr/sbin/lsof", ["-nP", "-a", "-p", list, "-d", "cwd,0-255", "-F", "pfn"]))
    }

    static func readJob(_ short: String, roster: DaemonRoster) -> JobRecord? {
        let url = jobsDir.appendingPathComponent(short).appendingPathComponent("state.json")
        guard let data = try? Data(contentsOf: url),
              let s = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { return nil }
        let cwd = (s["cwd"] as? String) ?? roster.workers[short]?.cwd
        var transcript = s["linkScanPath"] as? String
        if transcript == nil, let c = cwd, let sid = (s["sessionId"] as? String) ?? roster.workers[short]?.sessionId {
            let slug = c.map { ($0 == "/" || $0 == ".") ? "-" : $0 }
            transcript = claudeDir.appendingPathComponent("projects/\(String(slug))/\(sid).jsonl").path
        }
        let mtime = transcript.flatMap {
            (try? FileManager.default.attributesOfItem(atPath: $0))?[.modificationDate] as? Date
        }
        let name = ((s["name"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)).flatMap { $0.isEmpty ? nil : $0 }
            ?? (s["intent"] as? String).map { String($0.prefix(60)) } ?? short
        return JobRecord(short: short, name: name, state: (s["state"] as? String) ?? "unknown",
                         detail: (s["detail"] as? String) ?? "", tempo: s["tempo"] as? String, cwd: cwd,
                         createdAt: parseDate(s["createdAt"]), updatedAt: parseDate(s["updatedAt"]),
                         transcriptPath: transcript, transcriptMtime: mtime)
    }

    /// One full scan: ps, one lsof over the workers, the roster, and the job
    /// records of the live workers plus any job touched in the last day.
    /// About 0.1 s; call off the main thread.
    static func capture(now: Date = Date()) -> ClaudeProcessReport {
        let table = processTable()
        let workerPids = table.rows.values
            .filter { ClaudeProcKind.of(command: $0.command) == .worker || ClaudeProcKind.of(command: $0.command) == .cli }
            .map(\.pid)
        let files = openFiles(pids: workerPids)
        let roster = readRoster()

        var shorts = Set(files.rvShort.values).union(roster.workers.keys)
        let fm = FileManager.default
        let cutoff = now.addingTimeInterval(-ClaudeProcessClassifier.endedVisibleFor)
        for dir in (try? fm.contentsOfDirectory(at: jobsDir, includingPropertiesForKeys: nil)) ?? [] {
            let state = dir.appendingPathComponent("state.json")
            if let m = (try? fm.attributesOfItem(atPath: state.path))?[.modificationDate] as? Date, m > cutoff {
                shorts.insert(dir.lastPathComponent)
            }
        }
        var jobs: [String: JobRecord] = [:]
        for s in shorts { if let j = readJob(s, roster: roster) { jobs[s] = j } }

        return ClaudeProcessClassifier.classify(table: table, files: files, roster: roster, jobs: jobs,
                                                daemonPid: readDaemonPid(), now: now)
    }

    static func parseDate(_ any: Any?) -> Date? {
        if let s = any as? String {
            let iso = ISO8601DateFormatter()
            iso.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            if let d = iso.date(from: s) { return d }
            iso.formatOptions = [.withInternetDateTime]
            return iso.date(from: s)
        }
        if let ms = any as? Double { return Date(timeIntervalSince1970: ms / 1000.0) }
        if let ms = any as? Int { return Date(timeIntervalSince1970: Double(ms) / 1000.0) }
        return nil
    }

    static func run(_ exe: String, _ args: [String]) -> String {
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: exe)
        proc.arguments = args
        let pipe = Pipe()
        proc.standardOutput = pipe
        proc.standardError = FileHandle.nullDevice
        do { try proc.run() } catch { return "" }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        proc.waitUntilExit()
        return String(data: data, encoding: .utf8) ?? ""
    }
}

// MARK: - Menu text

/// The words the menu-bar menu shows, shared by the menu and by
/// `ClaudeHUD --process-report`, so the text dump is the menu.
enum ProcessMenuText {
    typealias Lines = (top: String, bottom: String)
    typealias Age = ClaudeProcessClassifier

    static func backgroundJob(_ w: ClassifiedWorker, now: Date) -> Lines {
        let state = [w.job?.tempo ?? w.job?.state, w.job?.detail]
            .compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: " · ")
        let activity = w.job?.transcriptMtime
            .map { "last write \(Age.ageString(now.timeIntervalSince($0))) ago" } ?? "no transcript"
        return ("\(w.project)  ·  \(Age.ageString(w.age))",
                [state, activity].filter { !$0.isEmpty }.joined(separator: "  ·  "))
    }

    static func ended(_ j: JobRecord, now: Date) -> Lines {
        let project = j.cwd.map { URL(fileURLWithPath: $0).lastPathComponent } ?? j.short
        let when = (j.updatedAt ?? j.createdAt).map { " \(Age.ageString(now.timeIntervalSince($0))) ago" } ?? ""
        return ("\(project)  ·  ended (\(j.state))\(when)", j.detail)
    }

    static func orphan(_ w: ClassifiedWorker) -> Lines {
        let reason: String
        if case .orphan(let r) = w.cls { reason = r } else { reason = "" }
        return ("\(w.project)  ·  \(Age.ageString(w.age))  ·  \(Age.memoryString(kb: w.rssKB))", "\(reason)  ·  Close…")
    }

    static func footer(_ r: ClaudeProcessReport) -> String {
        let spares = r.warmSpares.count
        return "Claude Code: \(Age.memoryString(kb: r.totalRSSKB)) in \(r.processCount) processes"
            + " · \(r.attached.count) attached, \(r.backgroundJobs.count) background"
            + (spares > 0 ? ", \(spares) warm spare" : "")
    }

    /// The menu's process sections as plain text, plus one line per
    /// classified worker for diagnosis.
    static func dump(_ r: ClaudeProcessReport, now: Date = Date()) -> String {
        var out: [String] = []
        if !r.backgroundJobs.isEmpty || !r.recentlyEnded.isEmpty {
            out.append("Background Jobs")
            for w in r.backgroundJobs { let l = backgroundJob(w, now: now); out += ["  \(l.top)", "      \(l.bottom)"] }
            for j in r.recentlyEnded { let l = ended(j, now: now); out += ["  (disabled) \(l.top)", "      \(l.bottom)"] }
        }
        if !r.orphans.isEmpty {
            out.append("Orphans (\(r.orphans.count))")
            for w in r.orphans { let l = orphan(w); out += ["  \(l.top)", "      \(l.bottom)"] }
        }
        out.append(footer(r))
        out.append("")
        out.append("-- all classified --")
        for w in r.workers {
            out.append("  \(w.cls)  \(w.project)  short=\(w.short ?? "-")  root=\(w.rootPid) worker=\(w.workerPid.map(String.init) ?? "-")  age=\(Age.ageString(w.age))  rss=\(Age.memoryString(kb: w.rssKB))")
        }
        return out.joined(separator: "\n") + "\n"
    }
}
