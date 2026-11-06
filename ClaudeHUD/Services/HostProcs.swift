import Foundation

/// One process tree the gate's `procs` lists on a machine (pi-gate,
/// bbdaniels/personal `deploy/mac/pi-gate.py`): a process a Claude session
/// started that outlived the turn it came from. `out` while its session still
/// runs (a dev server it left up), `lost` once its session is gone, when
/// nothing will ever stop it but Ben.
struct StrayTree: Identifiable, Equatable, Sendable {
    let host: SessionHost
    let pid: Int
    /// The gate's start stamp, passed back to `reap` so a reused pid is never hit.
    let start: Int
    let state: String
    let command: String
    /// On this Mac's paths (an iMac cwd mapped by `SessionHost.macPath`).
    let cwd: String
    let sessionId: String?
    let seconds: Int
    let processes: Int

    var id: String { "\(host.rawValue):\(pid):\(start)" }
    var isLost: Bool { state == "lost" }
}

/// What the gates' `procs` answered, both machines together.
struct HostProcsSnapshot: Equatable, Sendable {
    var trees: [StrayTree] = []
    /// Session id → background agents and shell tasks it launched that have
    /// not reported back (the gate's `tasks`).
    var openTasks: [String: Int] = [:]

    /// True when this running session has work out: a background agent or
    /// shell task not yet reported back, or a process tree it started on
    /// either machine (`SessionLight.holding`). Called for live sessions
    /// only, so any tree stamped with its id counts, even one the other
    /// machine's gate called lost.
    func hasWorkOut(sessionId: String?) -> Bool {
        guard let sid = sessionId else { return false }
        return (openTasks[sid] ?? 0) > 0 || trees.contains { $0.sessionId == sid }
    }

    /// The trees nothing owns: those no session running on either machine
    /// started (Ben, 2026-11-06: "any running process with a claude launcher
    /// identified should have a watcher/owner identified. then it need not be
    /// shown"). Each gate sees only its own machine's sessions, so a tree an
    /// iMac gate calls lost may belong to a session running on this Mac over
    /// ssh; `live` is both machines' running session ids.
    func lost(live: Set<String>) -> [StrayTree] {
        trees.filter { t in t.isLost && !(t.sessionId.map(live.contains) ?? false) }
    }
}

/// The poll of both gates' `procs`: this Mac's `~/bin/pi-gate` run here and
/// the iMac's over ssh, in the background every `interval`, the way
/// `IMacLive` polls `live`. The Mac's scan cannot read the environment of
/// Apple's own binaries (`/bin/bash`, `/bin/sleep`), so a tree there is found
/// by its first non-Apple process; an empty list on the Mac is not proof that
/// nothing is left.
enum HostProcs {
    static let interval: TimeInterval = 30

    /// One gate's answer, read. Nil when it is not the gate's (`ok` missing or false).
    static func snapshot(from stdout: Data, host: SessionHost) -> HostProcsSnapshot? {
        guard let obj = try? JSONSerialization.jsonObject(with: stdout) as? [String: Any],
              obj["ok"] as? Bool == true else { return nil }
        var s = HostProcsSnapshot()
        for p in obj["procs"] as? [[String: Any]] ?? [] {
            guard let pid = p["pid"] as? Int, let start = p["start"] as? Int,
                  let state = p["state"] as? String else { continue }
            let cwd = p["cwd"] as? String ?? ""
            s.trees.append(StrayTree(
                host: host, pid: pid, start: start, state: state,
                command: p["command"] as? String ?? "",
                cwd: host == .iMac ? host.macPath(cwd) : cwd,
                sessionId: p["sessionId"] as? String,
                seconds: p["seconds"] as? Int ?? 0,
                processes: p["processes"] as? Int ?? 1))
        }
        for t in obj["tasks"] as? [[String: Any]] ?? [] {
            if let sid = t["sessionId"] as? String, let n = t["open"] as? Int { s.openTasks[sid, default: 0] += n }
        }
        return s
    }

    /// The gate on `host` run with `args`: this Mac's directly, the iMac's
    /// over ssh. Blocks up to `timeout`: call it off the main thread.
    static func runGate(_ host: SessionHost, _ args: [String], timeout: TimeInterval) -> (status: Int32, stdout: Data)? {
        let process = Process()
        switch host {
        case .mac:
            process.executableURL = URL(fileURLWithPath: NSHomeDirectory() + "/bin/pi-gate")
            process.arguments = args
        case .iMac:
            process.executableURL = URL(fileURLWithPath: "/usr/bin/ssh")
            process.arguments = ["-o", "BatchMode=yes", "-o", "ConnectTimeout=5", IMacLauncher.sshHost,
                                 ([IMacLauncher.gatePath] + args.map(IMacLauncher.shellQuote)).joined(separator: " ")]
        }
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
        if finished.wait(timeout: .now() + timeout) == .timedOut {
            process.terminate()
            finished.wait()
        }
        process.waitUntilExit()
        return (process.terminationStatus, data)
    }

    /// Both machines' answers merged; a machine that does not answer adds nothing.
    static func fetch() -> HostProcsSnapshot {
        var merged = HostProcsSnapshot()
        for host in SessionHost.allCases {
            guard let r = runGate(host, ["procs"], timeout: 20), r.status == 0,
                  let s = snapshot(from: r.stdout, host: host) else { continue }
            merged.trees += s.trees
            merged.openTasks.merge(s.openTasks, uniquingKeysWith: +)
        }
        return merged
    }

    /// Stop one tree with the gate's `reap <pid> <start>` on its machine. Nil
    /// when it is stopped, else why not.
    static func reap(_ tree: StrayTree) -> String? {
        guard let r = runGate(tree.host, ["reap", String(tree.pid), String(tree.start)], timeout: 30) else {
            return "the gate could not start"
        }
        if let obj = try? JSONSerialization.jsonObject(with: r.stdout) as? [String: Any] {
            if obj["ok"] as? Bool == true { forget(tree); return nil }
            if let e = obj["error"] as? String { return e }
        }
        return "the gate answered nothing readable (exit \(r.status))"
    }

    private static let lock = NSLock()
    private static var last = HostProcsSnapshot()
    private static var fetchedAt: Date?
    private static var fetching = false

    /// The last fetch's answer (empty before the first).
    static var cached: HostProcsSnapshot {
        lock.lock(); defer { lock.unlock() }
        return last
    }

    /// Drop a reaped tree from the cache at once, so its line goes before the next poll.
    private static func forget(_ tree: StrayTree) {
        lock.lock(); last.trees.removeAll { $0.id == tree.id }; lock.unlock()
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
            let got = fetch()
            lock.lock()
            last = got; fetchedAt = Date(); fetching = false
            lock.unlock()
            DispatchQueue.main.async(execute: done)
        }
    }
}
