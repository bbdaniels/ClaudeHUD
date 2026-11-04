import Foundation

/// Starts ClaudeHUD's Claude sessions on the iMac, through the iMac's one
/// launcher (Ben, 2026-11-03: every session lives on the iMac, and
/// "claudehuds sessions should start that way").
///
/// The launcher is `~/bin/pi-gate launch` on the iMac (bbdaniels/personal,
/// `deploy/mac/pi-gate.py`; design in `deploy/mac/pi-gate-launch.md`, "The
/// one iMac launcher"). It starts `claude --dangerously-skip-permissions
/// --remote-control <name>` in the tmux session `rc-<name>` of its own tmux
/// server, in `~/Projects/<folder>`, and answers one JSON object naming the
/// command that attaches a terminal to it. The runner's `mac_launch` and a
/// session handing its work off call the same launcher, so nothing here
/// builds a tmux or claude command line of its own.
///
/// Idempotent on the name: a session already there is reported, not started
/// twice. A new session is named after its project and the minute it was
/// asked for; a resumed one after its project and its transcript, so a second
/// resume of one transcript attaches to the first instead of starting a
/// second writer.
///
/// Foundation only (no AppKit), so the tests compile it directly.
enum IMacLauncher {
    static let sshHost = "imac"
    /// Unquoted in the remote command, so the iMac's shell expands `~`.
    static let gatePath = "~/bin/pi-gate"
    static let maxName = 40              // pi-gate's NAME: [a-z0-9][a-z0-9-]{0,39}

    /// The launcher's refusals that mean "this is not on the iMac": the
    /// project folder is not there yet, or the transcript to resume is the
    /// Mac's. Such a session starts on this Mac instead, where it lives.
    static let folderMissing = "the folder is not a folder of ~/Projects on this machine"
    static let transcriptMissing = "no transcript of that session on this machine"

    struct Request: Equatable {
        var name: String
        /// Relative to ~/Projects ("." for ~/Projects itself).
        var folder: String
        var resume: String? = nil
        /// The session's first message, sent on ssh's stdin (`--prompt`).
        var prompt: String? = nil
    }

    struct Answer: Equatable {
        var started: Bool
        var session: String
        var attach: String
        var dir: String?
    }

    enum Outcome: Equatable {
        /// Running on the iMac: started now, or already there.
        case running(Answer)
        /// Not on the iMac (`folderMissing`, `transcriptMissing`): start it on this Mac.
        case notOnIMac(String)
        /// The iMac refused, or did not answer.
        case failed(String)
    }

    // MARK: Names and folders

    /// Lowercase letters and digits, every other run of characters one
    /// hyphen, none leading or trailing.
    static func slug(_ text: String) -> String {
        var out = ""
        var pendingDash = false
        for scalar in text.lowercased().unicodeScalars {
            let v = scalar.value
            if (97...122).contains(v) || (48...57).contains(v) {
                if pendingDash && !out.isEmpty { out.append("-") }
                out.unicodeScalars.append(scalar)
                pendingDash = false
            } else {
                pendingDash = true
            }
        }
        return out
    }

    /// `<project>-<suffix>`, at most `maxName` characters, the project part
    /// cut to fit; a valid launcher name whatever the project is called.
    static func name(project: String, suffix: String) -> String {
        let tail = slug(suffix)
        var head = slug(project)
        if head.isEmpty { head = "session" }
        guard !tail.isEmpty else { return String(head.prefix(maxName)) }
        let room = maxName - tail.count - 1
        if head.count > room {
            head = String(head.prefix(room))
            while head.hasSuffix("-") { head.removeLast() }
        }
        return head + "-" + tail
    }

    /// A new session's name: the project and the minute it was asked for
    /// (`claudehud-1103-1842`). Two clicks in one minute attach to one session.
    static func newSessionName(project: String, at date: Date = Date()) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "MMdd-HHmm"
        return name(project: project, suffix: f.string(from: date))
    }

    /// A resumed session's name: the project and the transcript's first 8
    /// characters, so a second resume of it attaches to the first.
    static func resumeName(project: String, sessionId: String) -> String {
        name(project: project, suffix: String(sessionId.prefix(8)))
    }

    /// The folder the launcher takes: `cwd` relative to ~/Projects, "." for
    /// ~/Projects itself; nil when `cwd` is outside ~/Projects, which the
    /// iMac does not mirror.
    static func projectsFolder(forMacPath cwd: String, home: String = NSHomeDirectory()) -> String? {
        let path = URL(fileURLWithPath: cwd).standardizedFileURL.path
        let root = URL(fileURLWithPath: home).standardizedFileURL.path + "/Projects"
        if path == root { return "." }
        guard path.hasPrefix(root + "/") else { return nil }
        let rel = String(path.dropFirst(root.count + 1))
        return rel.isEmpty ? "." : rel
    }

    // MARK: Where a session starts

    /// Where a launch goes, decided before anything runs.
    enum Route: Equatable {
        /// The iMac first; when it answers that the folder or transcript is
        /// not there (`Outcome.notOnIMac`), this Mac, and when it fails, an
        /// alert that offers this Mac.
        case iMacThenMac(folder: String)
        /// The iMac only: a session whose transcript is the iMac's. Every
        /// refusal or failure is reported; nothing starts on this Mac, which
        /// has only the mirror's read-only copy of the transcript.
        case iMacOnly(folder: String)
        /// This Mac only: a folder outside ~/Projects, which the iMac does not mirror.
        case macOnly
        /// Nowhere: an iMac session outside ~/Projects, which the launcher cannot reach.
        case refused(String)
    }

    static let outsideProjectsOnIMac = "the session ran outside ~/Projects on the iMac, where the launcher cannot start it"

    /// The route for a session that ran on `host` in `cwd` (a path on this
    /// Mac, as `SessionInfo.projectPath` holds it). A new session is the
    /// Mac's case: it starts on the iMac when the folder is under ~/Projects.
    static func route(host: SessionHost, cwd: String, home: String = NSHomeDirectory()) -> Route {
        let folder = projectsFolder(forMacPath: cwd, home: home)
        switch host {
        case .mac:
            return folder.map { .iMacThenMac(folder: $0) } ?? .macOnly
        case .iMac:
            return folder.map { .iMacOnly(folder: $0) } ?? .refused(outsideProjectsOnIMac)
        }
    }

    // MARK: The ssh call

    static func shellQuote(_ s: String) -> String {
        "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    /// What the iMac's shell runs: the launcher with its arguments quoted.
    static func remoteCommand(_ r: Request) -> String {
        var args = ["launch", r.name, "--dir", r.folder]
        if let id = r.resume { args += ["--resume", id] }
        if r.prompt != nil { args.append("--prompt") }
        return ([gatePath] + args.map(shellQuote)).joined(separator: " ")
    }

    static func sshArguments(_ r: Request) -> [String] {
        ["-o", "BatchMode=yes", "-o", "ConnectTimeout=10", sshHost, remoteCommand(r)]
    }

    /// What a Ghostty window runs to show the session: its terminal on the
    /// iMac. Closing the window detaches; the session runs on.
    static func attachCommand(_ a: Answer) -> String {
        "ssh -t \(sshHost) \(shellQuote(a.attach))"
    }

    /// The launcher's answer, read. `status` is ssh's exit status: 255 is
    /// ssh's own failure (the iMac asleep, offline, or the key refused).
    static func outcome(status: Int32, stdout: Data) -> Outcome {
        if status == 255 {
            return .failed("the iMac did not answer (asleep, offline, or ssh refused)")
        }
        guard let obj = try? JSONSerialization.jsonObject(with: stdout) as? [String: Any],
              let ok = obj["ok"] as? Bool else {
            return .failed(status == 1 ? "the iMac's launcher refused the request"
                                       : "the iMac's launcher did not answer as it does (exit \(status))")
        }
        guard ok else {
            let error = obj["error"] as? String ?? "no reason given"
            if error == folderMissing || error == transcriptMissing { return .notOnIMac(error) }
            return .failed(error)
        }
        guard let session = obj["session"] as? String, let attach = obj["attach"] as? String else {
            return .failed("the iMac's launcher did not name the session")
        }
        return .running(Answer(started: obj["started"] as? Bool ?? false, session: session, attach: attach,
                               dir: obj["dir"] as? String))
    }

    /// What the iMac's shell runs to move a session the Remote Control
    /// server spawned (one from the phone or claude.ai, with no terminal)
    /// into the gate's tmux as `name`: the gate's `adopt` verb, which stops
    /// the server's copy and resumes the conversation (pi-gate-launch.md).
    /// The reason in a gate's `end` answer (`AgentsService.end`, on either
    /// machine), nil for `"ok": true`.
    static func endFailure(status: Int32, stdout: Data) -> String? {
        guard let answer = try? JSONSerialization.jsonObject(with: stdout) as? [String: Any] else {
            return status == 255 ? "the iMac did not answer" : "the gate gave no answer (exit \(status))"
        }
        if answer["ok"] as? Bool == true { return nil }
        return answer["error"] as? String ?? "the gate refused"
    }

    static func adoptCommand(name: String, sessionId: String) -> String {
        ([gatePath] + ["adopt", name, sessionId].map(shellQuote)).joined(separator: " ")
    }

    /// Run the launcher over ssh. Blocks until it answers (it waits for the
    /// session's channel, up to about a minute): call it off the main thread.
    static func run(_ r: Request) -> Outcome {
        run(arguments: sshArguments(r), prompt: r.prompt)
    }

    /// `adopt` over ssh; blocks like `run`.
    static func adopt(name: String, sessionId: String) -> Outcome {
        run(arguments: ["-o", "BatchMode=yes", "-o", "ConnectTimeout=10", sshHost,
                        adoptCommand(name: name, sessionId: sessionId)], prompt: nil)
    }

    private static func run(arguments: [String], prompt: String?) -> Outcome {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/ssh")
        process.arguments = arguments
        let input = Pipe(), output = Pipe()
        process.standardInput = input
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
        } catch {
            return .failed("ssh could not start: \(error.localizedDescription)")
        }
        if let prompt { input.fileHandleForWriting.write(Data(prompt.utf8)) }
        try? input.fileHandleForWriting.close()
        let data = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return outcome(status: process.terminationStatus, stdout: data)
    }

    /// The tmux session an `ssh <iMac> tmux [-L <server>] attach -t '=<name>'`
    /// command line attaches to, or nil for any other command.
    static func attachTarget(command: String) -> String? {
        let parts = command.split(separator: " ", omittingEmptySubsequences: true).map(String.init)
        guard let argv0 = parts.first, argv0 == "ssh" || argv0.hasSuffix("/ssh"),
              parts.contains(sshHost),
              let a = parts.firstIndex(of: "attach"), a > 0,
              parts[..<a].contains(where: { $0.trimmingCharacters(in: CharacterSet(charactersIn: "'\"")).hasSuffix("tmux") }),
              let t = parts[a...].firstIndex(of: "-t"), t + 1 < parts.count else { return nil }
        let name = parts[t + 1].trimmingCharacters(in: CharacterSet(charactersIn: "'\"="))
        return name.isEmpty ? nil : name
    }
}
