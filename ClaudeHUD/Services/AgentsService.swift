import Foundation
import Combine
import AppKit
import os

private let logger = Logger(subsystem: "com.claudehud", category: "AgentsService")

/// Reads the Claude Code daemon's on-disk state and exposes it as live
/// `AgentSession` rows, plus the documented scriptable management verbs.
///
/// Sources (see https://code.claude.com/docs/en/agent-view):
///   ~/.claude/daemon/roster.json   → workers currently alive (pid, cwd)
///   ~/.claude/jobs/<id>/state.json → per-session state agent view renders
///   ~/.claude/jobs/pins.json       → pinned ids
///
/// Decoding is deliberately tolerant: Agent View is research-preview and the
/// schema may shift, so a renamed/added field must never drop a row.
@MainActor
final class AgentsService: ObservableObject {
    @Published private(set) var agents: [AgentSession] = []
    @Published private(set) var lastError: String?
    @Published private(set) var lastRefresh: Date?

    private var pollTimer: DispatchSourceTimer?

    /// Process-tree-derived "is this short attached anywhere" map. Each
    /// `claude attach <short>` process is walked up to its terminal owner;
    /// when the owner is a Ghostty process we also capture its
    /// `--title=` and pid so the view can raise the exact window. This is
    /// the honest answer to "can the user actually see and answer this
    /// session right now" — title-matching on parent folder names was
    /// happily routing two unrelated shorts to the same window.
    ///
    /// Scanned at most every 5s — `reload()` runs every 2s, but `ps` is
    /// cheap enough that this matters only under load.
    struct AttachInfo {
        let windowTitle: String?   // nil when no Ghostty ancestor
        let ghosttyPid: pid_t?
    }
    private var attachCache: (map: [String: AttachInfo], at: Date)?

    private func attachScan() -> [String: AttachInfo] {
        if let c = attachCache, Date().timeIntervalSince(c.at) < 5 {
            return c.map
        }
        let map = Self.scanAttaches()
        attachCache = (map, Date())
        return map
    }

    /// One `ps` invocation gets the full process table. We index by pid
    /// (ppid + raw command), then locate every `claude attach <short>`
    /// process and walk parents (capped) to find a Ghostty owner. A short
    /// can appear without a Ghostty parent (attached in Terminal/iTerm) —
    /// still record it as attached, just without a window pid.
    nonisolated static func scanAttaches() -> [String: AttachInfo] {
        struct PInfo { let ppid: Int; let command: String }
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/bin/ps")
        proc.arguments = ["-axo", "pid=,ppid=,command="]
        let pipe = Pipe()
        proc.standardOutput = pipe
        proc.standardError = Pipe()
        do { try proc.run() } catch { return [:] }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        proc.waitUntilExit()
        guard let out = String(data: data, encoding: .utf8) else { return [:] }

        var procs: [Int: PInfo] = [:]
        for raw in out.split(separator: "\n") {
            let line = raw.drop(while: { $0 == " " })
            guard let sp1 = line.firstIndex(of: " ") else { continue }
            let pidStr = line[..<sp1]
            let afterPid = line[line.index(after: sp1)...].drop(while: { $0 == " " })
            guard let sp2 = afterPid.firstIndex(of: " ") else { continue }
            let ppidStr = afterPid[..<sp2]
            let cmd = afterPid[afterPid.index(after: sp2)...].drop(while: { $0 == " " })
            guard let pid = Int(pidStr), let ppid = Int(ppidStr) else { continue }
            procs[pid] = PInfo(ppid: ppid, command: String(cmd))
        }

        // Regex matches `claude attach <8hex>` whether `claude` is the bare
        // command or a path ending in `/claude`. We anchor to a word so it
        // does not match prose inside a shell command argument.
        guard let regex = try? NSRegularExpression(
            pattern: #"(?:^|/)claude\s+attach\s+([0-9a-f]{8})\b"#
        ) else { return [:] }

        var result: [String: AttachInfo] = [:]
        for (_, info) in procs {
            let cmd = info.command
            let range = NSRange(cmd.startIndex..., in: cmd)
            guard let match = regex.firstMatch(in: cmd, range: range),
                  match.numberOfRanges >= 2,
                  let r = Range(match.range(at: 1), in: cmd) else { continue }
            let short = String(cmd[r])
            // Already recorded by a sibling (rare — multiple attach procs for
            // the same short)? Keep the first; they pin the same window.
            guard result[short] == nil else { continue }

            // Walk ancestors, capped at 16 hops, looking for Ghostty.
            var (cur, hops) = (info.ppid, 0)
            var attach = AttachInfo(windowTitle: nil, ghosttyPid: nil)
            while cur > 1, hops < 16, let p = procs[cur] {
                hops += 1
                if p.command.contains("/Ghostty.app/") {
                    let title = Self.parseTitle(from: p.command)
                    attach = AttachInfo(windowTitle: title, ghosttyPid: pid_t(cur))
                    break
                }
                cur = p.ppid
            }
            result[short] = attach
        }
        return result
    }

    /// Parse a Ghostty `--title=<value>` arg out of a command line. The
    /// kernel-returned command joins args with single spaces, so we read
    /// until the next space (project titles ClaudeHUD launches with don't
    /// contain whitespace).
    nonisolated private static func parseTitle(from cmd: String) -> String? {
        guard let r = cmd.range(of: "--title=") else { return nil }
        let tail = cmd[r.upperBound...]
        let end = tail.firstIndex(where: { $0 == " " || $0 == "\n" }) ?? tail.endIndex
        let title = tail[..<end].trimmingCharacters(in: .whitespaces)
        return title.isEmpty ? nil : title
    }

    static var claudeDir: URL {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".claude", isDirectory: true)
    }
    private static var jobsDir: URL { claudeDir.appendingPathComponent("jobs", isDirectory: true) }
    private static var rosterFile: URL { claudeDir.appendingPathComponent("daemon/roster.json") }
    private static var pinsFile: URL { jobsDir.appendingPathComponent("pins.json") }

    init() {}

    deinit { pollTimer?.cancel() }

    // MARK: - Lifecycle

    /// A directory vnode source can't see writes to `jobs/<id>/state.json`
    /// (one level deeper than the dir it watches), so live updates rely on a
    /// GCD timer. Unlike `Timer.scheduledTimer`, a DispatchSourceTimer fires
    /// regardless of the panel's run-loop mode, so the tab stays live while
    /// open. Reload is cheap (a handful of small JSON files).
    func start() {
        reload()
        guard pollTimer == nil else { return }
        let t = DispatchSource.makeTimerSource(queue: .main)
        t.schedule(deadline: .now() + 2, repeating: 2.0, leeway: .milliseconds(250))
        t.setEventHandler { [weak self] in
            Task { @MainActor in self?.reload() }
        }
        t.resume()
        pollTimer = t
    }

    func stop() {
        pollTimer?.cancel()
        pollTimer = nil
    }

    // MARK: - Read

    func reload() {
        let fm = FileManager.default
        var alive: [String: (pid: Int?, cwd: String?)] = [:]

        if let data = try? Data(contentsOf: Self.rosterFile),
           let root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
           let workers = root["workers"] as? [String: Any] {
            for (short, raw) in workers {
                let w = raw as? [String: Any]
                alive[short] = (w?["pid"] as? Int, w?["cwd"] as? String)
            }
        }

        let pins: Set<String> = {
            guard let data = try? Data(contentsOf: Self.pinsFile),
                  let arr = (try? JSONSerialization.jsonObject(with: data)) as? [String] else { return [] }
            return Set(arr)
        }()

        var result: [AgentSession] = []

        // Honest open-ness: a session is open iff a `claude attach <short>`
        // process exists for it. Scanned once per refresh (throttled).
        let attaches = attachScan()

        let jobDirs = (try? fm.contentsOfDirectory(at: Self.jobsDir,
                                                   includingPropertiesForKeys: nil,
                                                   options: [.skipsHiddenFiles])) ?? []
        for dir in jobDirs {
            var isDir: ObjCBool = false
            guard fm.fileExists(atPath: dir.path, isDirectory: &isDir), isDir.boolValue else { continue }
            let id = dir.lastPathComponent
            let stateURL = dir.appendingPathComponent("state.json")
            guard let data = try? Data(contentsOf: stateURL),
                  let s = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { continue }

            let rawState = (s["state"] as? String) ?? "unknown"
            let intent = (s["intent"] as? String) ?? ""
            let detail = (s["detail"] as? String) ?? (s["output"] as? [String: Any]).flatMap { $0["result"] as? String } ?? ""
            let cwd = (s["cwd"] as? String) ?? alive[id]?.cwd ?? ""
            let projectName = cwd.isEmpty ? "" : URL(fileURLWithPath: cwd).lastPathComponent
            let template = s["template"] as? String
            let tempo = s["tempo"] as? String
            let inFlightTasks = ((s["inFlight"] as? [String: Any])?["tasks"] as? Int) ?? 0
            let transcriptPath = s["linkScanPath"] as? String
            let transcriptMtime: Date? = {
                guard let p = transcriptPath,
                      let attrs = try? fm.attributesOfItem(atPath: p),
                      let m = attrs[.modificationDate] as? Date else { return nil }
                return m
            }()
            let name = Self.resolveName(
                id: id,
                stateName: s["name"] as? String,
                intent: intent,
                transcriptPath: transcriptPath,
                projectName: projectName,
                template: template)

            let attach = attaches[id]
            result.append(AgentSession(
                id: id,
                name: name,
                rawState: rawState,
                detail: detail,
                intent: intent,
                cwd: cwd,
                createdAt: Self.parseDate(s["createdAt"]),
                updatedAt: Self.parseDate(s["updatedAt"]),
                isAlive: alive[id] != nil,
                pid: alive[id]?.pid,
                isPinned: pins.contains(id),
                template: template,
                tempo: tempo,
                inFlightTasks: inFlightTasks,
                isOpen: attach != nil,
                attachedWindowTitle: attach?.windowTitle,
                attachedGhosttyPid: attach?.ghosttyPid,
                transcriptMtime: transcriptMtime
            ))
        }

        // Pinned first, then by effective bucket (open: needs-input →
        // working → idle → completed → detached at the very bottom), then
        // most-recently-updated (recency sort within the detached bucket).
        result.sort { a, b in
            if a.isPinned != b.isPinned { return a.isPinned }
            if a.bucket.groupRank != b.bucket.groupRank {
                return a.bucket.groupRank < b.bucket.groupRank
            }
            return (a.updatedAt ?? .distantPast) > (b.updatedAt ?? .distantPast)
        }

        self.agents = result
        self.lastRefresh = Date()
        self.lastError = result.isEmpty && jobDirs.isEmpty ? "No daemon jobs found in ~/.claude/jobs." : nil
    }

    private static func parseDate(_ any: Any?) -> Date? {
        if let s = any as? String {
            let iso = ISO8601DateFormatter()
            iso.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            if let d = iso.date(from: s) { return d }
            iso.formatOptions = [.withInternetDateTime]
            return iso.date(from: s)
        }
        if let ms = any as? Double { return Date(timeIntervalSince1970: ms / 1000.0) }
        return nil
    }

    /// Title resolution. Bare `claude --bg` sessions have no name and no
    /// intent, so fall back to the transcript's first user prompt (the same
    /// source the History tab uses), then "project · template", then the id —
    /// never a bare hash if anything better exists.
    nonisolated private static func resolveName(id: String, stateName: String?, intent: String,
                                                transcriptPath: String?, projectName: String,
                                                template: String?) -> String {
        if let n = stateName?.trimmingCharacters(in: .whitespacesAndNewlines), !n.isEmpty { return n }
        let it = intent.trimmingCharacters(in: .whitespacesAndNewlines)
        if !it.isEmpty { return String(it.prefix(60)) }
        if let p = transcriptPath, let msg = firstUserPrompt(path: p) { return String(msg.prefix(70)) }
        if !projectName.isEmpty { return "\(projectName) · \(template ?? "bg")" }
        return id
    }

    /// First real user message from a Claude Code `.jsonl` transcript. Mirrors
    /// SessionHistoryService.readPreview: scan the first 16KB / 50 lines,
    /// skip internal `<…>` command/skill-selector prompts.
    nonisolated private static func firstUserPrompt(path: String) -> String? {
        guard let handle = FileHandle(forReadingAtPath: path) else { return nil }
        defer { try? handle.close() }
        guard let text = String(data: handle.readData(ofLength: 16384), encoding: .utf8) else { return nil }
        for line in text.components(separatedBy: "\n").prefix(50) {
            guard !line.isEmpty, let d = line.data(using: .utf8),
                  let json = try? JSONSerialization.jsonObject(with: d) as? [String: Any] else { continue }
            var role: String?
            if let r = json["role"] as? String { role = r }
            else if let t = json["type"] as? String { role = (t == "human" ? "user" : t) }
            else if let m = json["message"] as? [String: Any], let r = m["role"] as? String { role = r }
            guard role == "user" else { continue }
            let content: Any? = json["content"] ?? (json["message"] as? [String: Any])?["content"]
            if let s = content as? String {
                let t = s.trimmingCharacters(in: .whitespacesAndNewlines)
                if !t.isEmpty, !t.hasPrefix("<") { return t.replacingOccurrences(of: "\n", with: " ") }
            } else if let arr = content as? [[String: Any]] {
                for block in arr where (block["type"] as? String) == "text" {
                    let t = (block["text"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
                    if !t.isEmpty, !t.hasPrefix("<") { return t.replacingOccurrences(of: "\n", with: " ") }
                }
            }
        }
        return nil
    }

    // MARK: - Manage (documented scriptable verbs)

    /// Dispatch a new background session in `directory` (the chosen project's
    /// repo root). Without a directory the daemon would root the session at
    /// ClaudeHUD's cwd (`/`), so a target is required. Empty name → daemon
    /// auto-names it.
    func dispatch(prompt: String, name: String, directory: String) {
        let p = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        guard p.count >= 4 else { lastError = "Prompt too short."; return }
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: directory, isDirectory: &isDir), isDir.boolValue else {
            lastError = "Dispatch target is not a directory: \(directory)"
            return
        }
        var args = ["--bg"]
        let n = name.trimmingCharacters(in: .whitespacesAndNewlines)
        if !n.isEmpty { args += ["--name", n] }
        args.append(p)
        run(args, cwd: directory)
    }

    func stop(_ id: String)    { run(["stop", id], cwd: nil) }
    func respawn(_ id: String) { run(["respawn", id], cwd: nil) }
    func remove(_ id: String)  { run(["rm", id], cwd: nil) }

    /// Fetch recent output for the logs sheet.
    func fetchLogs(_ id: String) async -> String {
        await Self.runCapture(Self.resolveClaude(), ["logs", id], cwd: nil).output
    }

    /// Fire a claude verb, then refresh once it returns.
    private func run(_ args: [String], cwd: String?) {
        let claude = Self.resolveClaude()
        Task.detached {
            let r = await Self.runCapture(claude, args, cwd: cwd)
            await MainActor.run {
                if r.code != 0 {
                    self.lastError = "claude \(args.first ?? "") failed: \(r.output.prefix(160))"
                }
                self.reload()
            }
        }
    }

    private static func resolveClaude() -> String {
        let paths = [
            "\(NSHomeDirectory())/.local/bin/claude",
            "/usr/local/bin/claude",
            "/opt/homebrew/bin/claude",
            "\(NSHomeDirectory())/.npm-global/bin/claude",
            "\(NSHomeDirectory())/.claude/local/claude",
        ]
        for p in paths where FileManager.default.isExecutableFile(atPath: p) { return p }
        return "claude"
    }

    /// Run a process with array args (no shell → no injection) and capture
    /// combined stdout/stderr, capped.
    nonisolated private static func runCapture(_ claude: String, _ args: [String], cwd: String?) async -> (code: Int32, output: String) {
        await withCheckedContinuation { cont in
            let proc = Process()
            if claude.hasPrefix("/") {
                proc.executableURL = URL(fileURLWithPath: claude)
                proc.arguments = args
            } else {
                proc.executableURL = URL(fileURLWithPath: "/usr/bin/env")
                proc.arguments = [claude] + args
            }
            if let cwd, !cwd.isEmpty {
                proc.currentDirectoryURL = URL(fileURLWithPath: cwd)
            }
            let pipe = Pipe()
            proc.standardOutput = pipe
            proc.standardError = pipe
            do {
                try proc.run()
            } catch {
                cont.resume(returning: (-1, "launch failed: \(error.localizedDescription)"))
                return
            }
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            proc.waitUntilExit()
            let out = String(data: data.prefix(20_000), encoding: .utf8) ?? ""
            cont.resume(returning: (proc.terminationStatus, out))
        }
    }
}
