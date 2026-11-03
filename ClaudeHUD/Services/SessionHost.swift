import Foundation

// MARK: - Session host

/// The machine a Claude Code session ran on. History lists both: the Mac's
/// own transcripts, and the iMac's (Ubuntu, `ssh imac`), read from a local
/// read-only mirror that `IMacMirror` refreshes with rsync. One scan, one
/// filing rule and one index serve both; the host only says where the
/// transcript and its claim live, how its paths map onto this Mac, and where
/// it resumes.
///
/// Foundation only (no AppKit), so the tests compile it directly.
enum SessionHost: String, CaseIterable, Sendable {
    case mac
    case iMac

    /// The iMac's home directory, where its `~/.claude` and `~/Projects` live.
    static let iMacHome = "/home/bbdaniels"

    /// Where the iMac's mirror lives on this Mac:
    /// `~/Library/Caches/ClaudeHUD/hosts/imac`, holding `projects/` (its
    /// transcripts) and `session-projects/` (its claim records).
    static func iMacMirrorRoot(home: String = NSHomeDirectory()) -> String {
        home + "/Library/Caches/ClaudeHUD/hosts/imac"
    }

    /// The directory of per-project transcript directories this host's scan reads.
    func projectsDir(home: String = NSHomeDirectory()) -> String {
        switch self {
        case .mac: return home + "/.claude/projects"
        case .iMac: return Self.iMacMirrorRoot(home: home) + "/projects"
        }
    }

    /// The directory of this host's claim records (`SessionFiling`).
    func claimsDir(home: String = NSHomeDirectory()) -> URL {
        switch self {
        case .mac:
            return URL(fileURLWithPath: home).appendingPathComponent(".claude/session-projects", isDirectory: true)
        case .iMac:
            return URL(fileURLWithPath: Self.iMacMirrorRoot(home: home))
                .appendingPathComponent("session-projects", isDirectory: true)
        }
    }

    // MARK: Path mapping

    /// A path as this host wrote it, on this Mac. The Mac's paths are its
    /// own. The iMac's `~/Projects` holds the same checkouts as the Mac's, so
    /// `/home/bbdaniels/Projects/<rest>` maps to `<home>/Projects/<rest>`
    /// and an iMac session files under the same vault project as a Mac one.
    /// Any other iMac path is returned unchanged: this Mac has no copy of it.
    func macPath(_ path: String, home: String = NSHomeDirectory()) -> String {
        guard self == .iMac else { return path }
        let root = Self.iMacHome + "/Projects"
        if path == root { return home + "/Projects" }
        guard path.hasPrefix(root + "/") else { return path }
        return home + "/Projects" + path.dropFirst(root.count)
    }

    /// Claude Code's encoding of a directory as a project directory name:
    /// every character that is not an ASCII letter or digit becomes "-".
    static func encodeDirName(_ path: String) -> String {
        String(path.unicodeScalars.map {
            CharacterSet.alphanumerics.contains($0) && $0.isASCII ? Character($0) : "-"
        })
    }

    /// An iMac project directory name under `~/Projects`
    /// (`-home-bbdaniels-Projects-heat-tv`) as the Mac would have named the
    /// same directory (`-Users-bbdaniels-Projects-heat-tv`), so the Mac's
    /// decoder resolves it against the Mac's own checkouts. Nil for an iMac
    /// directory outside `~/Projects`, and for every Mac directory name.
    func macDirName(_ dirName: String, home: String = NSHomeDirectory()) -> String? {
        guard self == .iMac else { return nil }
        let iMacRoot = Self.encodeDirName(Self.iMacHome + "/Projects")
        guard dirName == iMacRoot || dirName.hasPrefix(iMacRoot + "-") else { return nil }
        return Self.encodeDirName(home + "/Projects") + dirName.dropFirst(iMacRoot.count)
    }
}

// MARK: - The iMac mirror

/// Copies the iMac's transcripts and claim records into this Mac's mirror
/// (`SessionHost.iMacMirrorRoot`) with rsync over ssh. Read-only toward the
/// iMac: nothing is ever written there.
///
/// What is copied: each top-level `*.jsonl` of every project directory of the
/// iMac's `~/.claude/projects` (not the subagent transcripts in deeper
/// folders, which history never lists), and every `*.json` claim of its
/// `~/.claude/session-projects`. `--delete` drops what the iMac removed.
///
/// The Mac's `/usr/bin/rsync` is openrsync (protocol 29), which has neither
/// `--append-verify` nor working compression against the iMac's rsync 3.4.1
/// (a `-z` transfer stalled until its I/O timeout in two probes on 2026-11-03).
/// So the transfer is rsync's default: a file whose size and modification
/// time are unchanged is skipped, and a grown transcript sends only its new
/// blocks through the delta algorithm, then replaces the mirror's copy by an
/// atomic rename, so a scan never reads a half-written file. `-t` keeps the
/// iMac's modification times, which History shows as the session's time.
/// `--partial-dir` keeps an interrupted file's bytes in a hidden folder so the
/// next run resumes it: a first mirror larger than one run's time limit
/// completes over several refreshes.
///
/// One run at a time (a second call while one runs returns `.busy`), a hard
/// limit of `timeLimit` seconds, after which rsync is stopped and the mirror
/// keeps what it had. Blocks: call it off the main thread.
enum IMacMirror {
    static let timeLimit: TimeInterval = 30
    static let rsyncPath = "/usr/bin/rsync"

    enum Outcome: Equatable {
        case synced
        case busy
        case failed(String)
    }

    /// rsync's arguments for one run into `root`.
    static func rsyncArguments(root: String = SessionHost.iMacMirrorRoot()) -> [String] {
        [
            "-rtm", "--delete",
            "--timeout=20",
            "--partial-dir=.rsync-partial",
            "-e", "ssh -o BatchMode=yes -o ConnectTimeout=10",
            "--include=/projects/",
            "--include=/projects/*/",
            "--include=/projects/*/*.jsonl",
            "--include=/session-projects/",
            "--include=/session-projects/*.json",
            "--exclude=*",
            "\(IMacLauncher.sshHost):.claude/",
            root.hasSuffix("/") ? root : root + "/",
        ]
    }

    /// A cheap fingerprint of the mirror (every file's path, size and
    /// modification time), so a caller rescans only when a run changed it.
    static func signature(root: String = SessionHost.iMacMirrorRoot()) -> Int {
        var hasher = Hasher()
        let fm = FileManager.default
        for sub in ["projects", "session-projects"] {
            guard let e = fm.enumerator(at: URL(fileURLWithPath: root + "/" + sub),
                                        includingPropertiesForKeys: [.fileSizeKey, .contentModificationDateKey],
                                        options: [.skipsHiddenFiles]) else { continue }
            for case let url as URL in e {
                let v = try? url.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey])
                hasher.combine(url.path)
                hasher.combine(v?.fileSize ?? -1)
                hasher.combine(v?.contentModificationDate?.timeIntervalSince1970 ?? 0)
            }
        }
        return hasher.finalize()
    }

    private static let lock = NSLock()
    private static var running = false

    /// Run rsync once. Returns `.busy` without starting anything while
    /// another run is in progress.
    static func run(root: String = SessionHost.iMacMirrorRoot()) -> Outcome {
        lock.lock()
        if running { lock.unlock(); return .busy }
        running = true
        lock.unlock()
        defer { lock.lock(); running = false; lock.unlock() }

        do {
            try FileManager.default.createDirectory(atPath: root, withIntermediateDirectories: true)
        } catch {
            return .failed("the mirror directory could not be made: \(error.localizedDescription)")
        }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: rsyncPath)
        process.arguments = rsyncArguments(root: root)
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = FileHandle.nullDevice
        let errors = Pipe()
        process.standardError = errors
        let finished = DispatchSemaphore(value: 0)
        process.terminationHandler = { _ in finished.signal() }
        do {
            try process.run()
        } catch {
            return .failed("rsync could not start: \(error.localizedDescription)")
        }
        // Read stderr while rsync runs, so a full pipe can never stall it.
        var stderrData = Data()
        let reader = DispatchQueue(label: "com.claudehud.imac-mirror.stderr")
        reader.async { stderrData = errors.fileHandleForReading.readDataToEndOfFile() }
        if finished.wait(timeout: .now() + timeLimit) == .timedOut {
            process.terminate()
            finished.wait()
            reader.sync {}
            return .failed("rsync stopped after \(Int(timeLimit)) s; the mirror keeps what it had")
        }
        reader.sync {}
        guard process.terminationStatus == 0 else {
            let message = String(data: stderrData, encoding: .utf8)?
                .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            return .failed("rsync exit \(process.terminationStatus)\(message.isEmpty ? "" : ": " + message)")
        }
        return .synced
    }
}

// MARK: - The iMac's live sessions

/// The iMac's running Claude Code sessions, from its gate's `live` verb
/// (`ssh imac ~/bin/pi-gate live`): the CLI's own `~/.claude/sessions/<pid>.json`
/// records whose process still runs, each checked there against its process's
/// start time. Read-only toward the iMac.
///
/// `cached` is what the last fetch returned and when; `refresh` fetches again
/// off the main thread at most every `interval` seconds, so the Agents poll
/// (every 2 s) never waits on ssh. `fetch` blocks and answers fresh, for the
/// History resume guard. A failed fetch (the iMac asleep, ssh refused) keeps
/// nothing: an empty list, so a stale row never claims a session is running.
enum IMacLive {
    static let interval: TimeInterval = 10

    /// The gate's answer, read: each element of `live` as a record. Nil when
    /// the answer is not the gate's (`ok` missing or false).
    static func records(from stdout: Data) -> [ClaudeSessionRecord]? {
        guard let obj = try? JSONSerialization.jsonObject(with: stdout) as? [String: Any],
              obj["ok"] as? Bool == true,
              let live = obj["live"] as? [[String: Any]] else { return nil }
        return live.compactMap {
            (try? JSONSerialization.data(withJSONObject: $0)).flatMap(ClaudeSessionRecords.parse)
        }
    }

    /// One fetch over ssh. Blocks up to about 10 s: call it off the main thread.
    static func fetch() -> [ClaudeSessionRecord]? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/ssh")
        process.arguments = ["-o", "BatchMode=yes", "-o", "ConnectTimeout=5",
                             IMacLauncher.sshHost, IMacLauncher.gatePath + " live"]
        let output = Pipe()
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        do { try process.run() } catch { return nil }
        let finished = DispatchSemaphore(value: 0)
        var data = Data()
        DispatchQueue.global(qos: .utility).async {
            data = output.fileHandleForReading.readDataToEndOfFile()
            finished.signal()
        }
        if finished.wait(timeout: .now() + 10) == .timedOut {
            process.terminate()
            finished.wait()
        }
        process.waitUntilExit()
        guard process.terminationStatus == 0 else { return nil }
        return records(from: data)
    }

    private static let lock = NSLock()
    private static var last: [ClaudeSessionRecord] = []
    private static var fetchedAt: Date?
    private static var fetching = false

    /// The last fetch's records ([] before the first and after a failure).
    static var cached: [ClaudeSessionRecord] {
        lock.lock(); defer { lock.unlock() }
        return last
    }

    /// Start a fetch in the background when the last is older than
    /// `interval` and none is running; `done` runs on the main queue after it.
    static func refresh(done: @escaping @Sendable () -> Void = {}) {
        lock.lock()
        if fetching || (fetchedAt.map { Date().timeIntervalSince($0) < interval } ?? false) {
            lock.unlock(); return
        }
        fetching = true
        lock.unlock()
        DispatchQueue.global(qos: .utility).async {
            let got = fetch() ?? []
            lock.lock()
            last = got; fetchedAt = Date(); fetching = false
            lock.unlock()
            DispatchQueue.main.async(execute: done)
        }
    }
}
