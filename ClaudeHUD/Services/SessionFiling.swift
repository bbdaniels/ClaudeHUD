import Foundation
import Darwin

// MARK: - Session filing

/// Which vault project a Claude Code session is filed under. ONE rule for
/// history rows, project recency and the live badges, so the three cannot
/// disagree:
///
///   1. the session's claim record, `~/.claude/session-projects/<sessionId>.json`,
///      written by `~/.claude/hooks/session-context.py` when a session opens
///      or runs `/project` (ClaudeHUD only reads it; the latest write wins);
///   2. else the project its transcript's records worked in: each record's
///      own `cwd` is resolved through `ProjectResolver`, directories that
///      resolve to no project are ignored, and the project with the most
///      records wins (a tie files nothing here);
///   3. else the directory the session was started in, resolved as before.
///
/// Step 2 exists for sessions started from the Claude iOS app: the Remote
/// Control server runs in ~/Projects, so every phone session starts there,
/// and only the directories its records name show the project. A probe of
/// 249 listed transcripts on 2026-11-03 found the dominant record directory
/// outside the start directory in 8, all scratchpads that resolve to no
/// project, so step 2 leaves the filing of terminal sessions unchanged.
///
/// The rule is the same for both hosts (`SessionHost`); only its inputs
/// differ. A session that ran on the iMac reads its claim from the iMac's
/// claims mirrored to this Mac (`SessionHost.claimsDir`, which `IMacMirror`
/// copies from the iMac's `~/.claude/session-projects`), and every directory
/// it names, in its records and as its start directory, is first mapped onto
/// this Mac (`SessionHost.macPath`: `/home/bbdaniels/Projects/<rest>` is
/// `~/Projects/<rest>` here), so an iMac session files under the same vault
/// project as a Mac session in the same checkout.
///
/// Filing is attribution only. A session resumes from its transcript's own
/// directory (`SessionInfo.projectPath`), never from the claimed project.
enum SessionFiling {

    /// The Mac's own claims directory.
    static var claimsDir: URL { SessionHost.mac.claimsDir() }

    /// One claim record. Only `folder` is required; it matches `Project.name`.
    struct Claim: Equatable {
        let sessionId: String?
        let folder: String
        let vaultPath: String?
        let cwd: String?
        let source: String?
    }

    static func parseClaim(_ data: Data) -> Claim? {
        guard let j = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let folder = (j["folder"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines),
              !folder.isEmpty else { return nil }
        return Claim(sessionId: j["sessionId"] as? String, folder: folder,
                     vaultPath: j["vaultPath"] as? String, cwd: j["cwd"] as? String,
                     source: j["source"] as? String)
    }

    /// The claim for `sessionId`, if one exists and names that session.
    static func readClaim(sessionId: String, in dir: URL = claimsDir) -> Claim? {
        guard !sessionId.isEmpty, !sessionId.contains("/"),
              let data = try? Data(contentsOf: dir.appendingPathComponent("\(sessionId).json")),
              let claim = parseClaim(data) else { return nil }
        if let id = claim.sessionId, id != sessionId { return nil }
        return claim
    }

    /// A claims directory's modification time: it changes when a claim is
    /// created or atomically replaced (the mirror's rsync also replaces by
    /// rename), so a view can key a re-prime on it.
    static func claimsSignature(in dir: URL) -> Double {
        ((try? FileManager.default.attributesOfItem(atPath: dir.path))?[.modificationDate] as? Date)?
            .timeIntervalSince1970 ?? 0
    }

    /// Every host's claims directory, combined: changes when either does.
    static func claimsSignature() -> Double {
        SessionHost.allCases.reduce(0) { $0 + claimsSignature(in: $1.claimsDir()) }
    }

    /// Collapse a worktree path back to its parent repo cwd.
    static func repoCwd(_ p: String) -> String {
        if let range = p.range(of: "/.claude/worktrees/") {
            return String(p[..<range.lowerBound])
        }
        return p
    }

    /// Step 2: the project most of the transcript's records ran in, counting
    /// only directories that resolve to a project. Nil when none resolves or
    /// two projects tie.
    static func dominantFolder(cwdCounts: [String: Int], resolve: (String) -> String?) -> String? {
        var byFolder: [String: Int] = [:]
        for (cwd, n) in cwdCounts where n > 0 {
            guard let folder = resolve(repoCwd(cwd)) else { continue }
            byFolder[folder, default: 0] += n
        }
        guard let best = byFolder.values.max() else { return nil }
        let winners = byFolder.filter { $0.value == best }
        return winners.count == 1 ? winners.first!.key : nil
    }

    /// The whole rule. `resolve` maps a directory on this Mac to a project
    /// folder name (`ProjectResolver.resolveFolder`, or a cache of it); the
    /// directories of a session that ran on `host` are mapped onto this Mac
    /// before it sees them (`SessionHost.macPath`, the identity for the Mac).
    /// The claim is read by the caller, from `host.claimsDir()`.
    static func resolveFolder(claim: Claim?, cwdCounts: [String: Int], fallbackCwd: String,
                              host: SessionHost = .mac, home: String = NSHomeDirectory(),
                              resolve: (String) -> String?) -> String? {
        if let claim { return claim.folder }
        var counts: [String: Int] = [:]
        for (cwd, n) in cwdCounts { counts[host.macPath(cwd, home: home), default: 0] += n }
        if let folder = dominantFolder(cwdCounts: counts, resolve: resolve) { return folder }
        let cwd = repoCwd(host.macPath(fallbackCwd, home: home))
        return cwd.isEmpty ? nil : resolve(cwd)
    }
}

// MARK: - Live session records

/// One `~/.claude/sessions/<pid>.json`: the record every running Claude Code
/// process keeps of itself (session id, directory, status, name, and, when
/// Remote Control is on, the `bridgeSessionId` that claude.ai and the phone
/// address it by).
struct ClaudeSessionRecord: Equatable {
    let pid: Int
    let sessionId: String
    let cwd: String
    let kind: String?
    let entrypoint: String?
    let name: String?
    let bridgeSessionId: String?
    let jobId: String?
    /// "busy", "idle" or "waiting" (with `waitingFor`, for example
    /// "permission prompt"); the CLI also writes "shell" while a shell
    /// command runs, which it reports as busy.
    let status: String?
    let waitingFor: String?
    let startedAt: Date?
    let updatedAt: Date?
    /// The process's start time as the CLI recorded it, used to tell a live
    /// record from a stale one whose pid was reused.
    let procStart: String?
    /// The tmux pane the session runs in, as "<session>:@<window>.%<pane>",
    /// when it runs in one (the iMac's pi-gate sessions do).
    var tmux: String? = nil
    /// The command that attaches a terminal to that tmux session, as the
    /// iMac's gate reports it (`live`): on the gate's own tmux server for a
    /// session it launched or adopted, else on the default server.
    var attach: String? = nil
    /// Set by the iMac's gate (`live`) on a session that is a service, not
    /// Ben's work: "duet", the runner's Duet session, which systemd starts
    /// again whenever it ends (2026-11-06).
    var service: String? = nil

    /// A session started from the Claude app through Remote Control: an
    /// interactive `--print` child of `claude remote-control` (entrypoint
    /// "sdk-cli", no daemon job) with a bridge id. Daemon background jobs and
    /// terminal sessions also carry a bridge id once Remote Control is on for
    /// every session; they are not these, since they have a window or a job.
    var isRemoteControlChild: Bool {
        bridgeSessionId != nil && entrypoint == "sdk-cli" && jobId == nil && kind == "interactive"
    }

    /// Where the session opens in a browser: claude.ai's page for it.
    var remoteControlURL: URL? {
        bridgeSessionId.flatMap { URL(string: "https://claude.ai/code/\($0)") }
    }

    /// The status as the state token `AgentDisplayState.derive` reads, in the
    /// CLI's own mapping: waiting needs input, idle is idle, anything else
    /// is busy (working).
    var displayState: String {
        switch status {
        case "idle": return "idle"
        case "waiting": return "waiting"
        default: return "busy"
        }
    }
}

enum ClaudeSessionRecords {

    static var dir: URL {
        URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent(".claude/sessions", isDirectory: true)
    }

    static func parse(_ data: Data) -> ClaudeSessionRecord? {
        guard let j = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let pid = (j["pid"] as? NSNumber)?.intValue, pid > 0,
              let sessionId = j["sessionId"] as? String, !sessionId.isEmpty else { return nil }
        func string(_ k: String) -> String? {
            (j[k] as? String).flatMap { $0.isEmpty ? nil : $0 }
        }
        func millis(_ k: String) -> Date? {
            (j[k] as? NSNumber).map { Date(timeIntervalSince1970: $0.doubleValue / 1000) }
        }
        return ClaudeSessionRecord(
            pid: pid, sessionId: sessionId, cwd: string("cwd") ?? "",
            kind: string("kind"), entrypoint: string("entrypoint"), name: string("name"),
            bridgeSessionId: string("bridgeSessionId"), jobId: string("jobId"),
            status: string("status"), waitingFor: string("waitingFor"),
            startedAt: millis("startedAt"), updatedAt: millis("updatedAt"),
            procStart: string("procStart"), tmux: string("tmux"), attach: string("attach"),
            service: string("service"))
    }

    /// Every record in `dir` whose process is still the one that wrote it.
    static func readLive(in dir: URL = dir,
                         isRunning: (ClaudeSessionRecord) -> Bool = isRunning) -> [ClaudeSessionRecord] {
        let files = (try? FileManager.default.contentsOfDirectory(
            at: dir, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles])) ?? []
        return files.filter { $0.pathExtension == "json" }
            .compactMap { (try? Data(contentsOf: $0)).flatMap(parse) }
            .filter(isRunning)
    }

    /// The transcript Claude Code keeps for a session started in `cwd`:
    /// ~/.claude/projects/<cwd with every non-alphanumeric character as "-">/<id>.jsonl.
    /// Nil when that file does not exist yet.
    static func transcriptPath(sessionId: String, cwd: String,
                               projectsDir: URL = URL(fileURLWithPath: NSHomeDirectory())
                                   .appendingPathComponent(".claude/projects", isDirectory: true)) -> String? {
        guard !sessionId.isEmpty, !cwd.isEmpty else { return nil }
        let encoded = String(cwd.unicodeScalars.map {
            CharacterSet.alphanumerics.contains($0) && $0.isASCII ? Character($0) : "-"
        })
        let path = projectsDir.appendingPathComponent(encoded)
            .appendingPathComponent("\(sessionId).jsonl").path
        return FileManager.default.fileExists(atPath: path) ? path : nil
    }

    /// The live record holding `sessionId`, if any process still has it open.
    static func liveHolder(of sessionId: String, in records: [ClaudeSessionRecord]) -> ClaudeSessionRecord? {
        records.first { $0.sessionId == sessionId }
    }

    /// The pid exists and, when the record carries the process start time,
    /// started then (within two seconds), so a reused pid is not a live session.
    static func isRunning(_ r: ClaudeSessionRecord) -> Bool {
        guard pidExists(r.pid) else { return false }
        guard let recorded = r.procStart.flatMap(parseProcStart),
              let actual = processStartTime(pid: r.pid) else { return true }
        return abs(recorded.timeIntervalSince(actual)) < 2
    }

    static func pidExists(_ pid: Int) -> Bool {
        kill(pid_t(pid), 0) == 0 || errno == EPERM
    }

    /// `procStart` is the `ps -o lstart` form in UTC: "Tue Nov  3 00:08:48 2026".
    /// Claude Code runs `LC_ALL=C TZ=UTC ps -o lstart= -p <pid>` (2.1.317).
    /// Read as local time, every record was five hours off its process and
    /// looked stale, so no Mac session was ever "Still running" (2026-11-03).
    static func parseProcStart(_ s: String) -> Date? {
        let collapsed = s.split(separator: " ", omittingEmptySubsequences: true).joined(separator: " ")
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone(identifier: "UTC")
        f.dateFormat = "EEE MMM d HH:mm:ss yyyy"
        return f.date(from: collapsed)
    }

    static func processStartTime(pid: Int) -> Date? {
        var info = kinfo_proc()
        var size = MemoryLayout<kinfo_proc>.stride
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, Int32(pid)]
        guard sysctl(&mib, 4, &info, &size, nil, 0) == 0, size > 0 else { return nil }
        let tv = info.kp_proc.p_un.__p_starttime
        // lstart has whole seconds; drop the fraction so the comparison is fair.
        return Date(timeIntervalSince1970: TimeInterval(tv.tv_sec))
    }
}
