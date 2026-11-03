import XCTest

/// `IMacLauncher`: the names, folder and command ClaudeHUD gives the iMac's
/// one launcher (`~/bin/pi-gate launch`, bbdaniels/personal
/// `deploy/mac/pi-gate.py`), and how its answer is read. The launcher's own
/// behavior is tested in personal (`runner/tests/test_pi_gate.py`).
final class IMacLauncherTests: XCTestCase {

    /// pi-gate's NAME, `[a-z0-9][a-z0-9-]{0,39}`, whole.
    func isLauncherName(_ s: String) -> Bool {
        s.range(of: "^[a-z0-9][a-z0-9-]{0,39}$", options: .regularExpression) != nil
    }

    func testNamesAreAlwaysLauncherNames() {
        for project in ["ClaudeHUD", "Raspberry Pi", "personal", "Été 2026 (draft)", "---", "",
                        String(repeating: "Long Project Name ", count: 6)] {
            let fresh = IMacLauncher.newSessionName(project: project, at: Date(timeIntervalSince1970: 0))
            let resumed = IMacLauncher.resumeName(project: project, sessionId: "440f7b4f-2a14-4330-b46e-77f90ca7b096")
            XCTAssertTrue(isLauncherName(fresh), fresh)
            XCTAssertTrue(isLauncherName(resumed), resumed)
        }
        XCTAssertEqual(IMacLauncher.slug("Raspberry Pi / plans"), "raspberry-pi-plans")
        XCTAssertEqual(IMacLauncher.resumeName(project: "ClaudeHUD", sessionId: "440f7b4f-2a14-4330-b46e-77f90ca7b096"),
                       "claudehud-440f7b4f")
        XCTAssertEqual(IMacLauncher.name(project: String(repeating: "a", count: 50), suffix: "1103-1842"),
                       String(repeating: "a", count: 30) + "-1103-1842")
        XCTAssertEqual(IMacLauncher.name(project: "", suffix: "x"), "session-x")
    }

    func testOneTranscriptResumesUnderOneName() {
        let id = "440f7b4f-2a14-4330-b46e-77f90ca7b096"
        XCTAssertEqual(IMacLauncher.resumeName(project: "ClaudeHUD", sessionId: id),
                       IMacLauncher.resumeName(project: "ClaudeHUD", sessionId: id))
    }

    func testTheFolderIsTheCwdUnderProjects() {
        let home = "/Users/bbdaniels"
        XCTAssertEqual(IMacLauncher.projectsFolder(forMacPath: "/Users/bbdaniels/Projects/ClaudeHUD", home: home),
                       "ClaudeHUD")
        XCTAssertEqual(IMacLauncher.projectsFolder(forMacPath: "/Users/bbdaniels/Projects/a b/sub/", home: home),
                       "a b/sub")
        XCTAssertEqual(IMacLauncher.projectsFolder(forMacPath: "/Users/bbdaniels/Projects", home: home), ".")
        XCTAssertNil(IMacLauncher.projectsFolder(forMacPath: "/Users/bbdaniels/Documents/x", home: home))
        XCTAssertNil(IMacLauncher.projectsFolder(forMacPath: "/Users/bbdaniels/ProjectsOld/x", home: home))
        XCTAssertNil(IMacLauncher.projectsFolder(forMacPath: "/Users/bbdaniels/Projects/../Documents", home: home))
    }

    func testTheRemoteCommandQuotesEveryArgumentButTheLaunchersPath() {
        let r = IMacLauncher.Request(name: "claudehud-440f7b4f", folder: "Ben's repo",
                                     resume: "440f7b4f-2a14-4330-b46e-77f90ca7b096", prompt: "/project X")
        XCTAssertEqual(IMacLauncher.remoteCommand(r),
                       "~/bin/pi-gate 'launch' 'claudehud-440f7b4f' '--dir' 'Ben'\\''s repo' "
                       + "'--resume' '440f7b4f-2a14-4330-b46e-77f90ca7b096' '--prompt'")
        XCTAssertEqual(IMacLauncher.sshArguments(r).prefix(5),
                       ["-o", "BatchMode=yes", "-o", "ConnectTimeout=10", "imac"])
        let plain = IMacLauncher.Request(name: "a", folder: ".")
        XCTAssertEqual(IMacLauncher.remoteCommand(plain), "~/bin/pi-gate 'launch' 'a' '--dir' '.'")
    }

    func testTheAnswerIsRead() {
        let started = Data("""
            {"ok": true, "started": true, "folder_made": false, "dir": "~/Projects/e2e-imac", "channel": true,
             "attach": "tmux -L pi-gate attach -t =rc-probe", "bypass": true, "resumed": null, "prompted": true,
             "session": "rc-probe", "since": "2026-11-03T18:38:13+0000", "alive": true}
            """.utf8)
        guard case .running(let answer) = IMacLauncher.outcome(status: 0, stdout: started) else {
            return XCTFail("not running")
        }
        XCTAssertTrue(answer.started)
        XCTAssertEqual(answer.session, "rc-probe")
        XCTAssertEqual(IMacLauncher.attachCommand(answer), "ssh -t imac 'tmux -L pi-gate attach -t =rc-probe'")

        let there = Data(#"{"ok": true, "started": false, "attach": "tmux -L pi-gate attach -t =rc-probe", "session": "rc-probe", "alive": true}"#.utf8)
        XCTAssertEqual(IMacLauncher.outcome(status: 0, stdout: there),
                       .running(.init(started: false, session: "rc-probe",
                                      attach: "tmux -L pi-gate attach -t =rc-probe", dir: nil)))

        for phrase in [IMacLauncher.folderMissing, IMacLauncher.transcriptMissing] {
            let refusal = Data(#"{"ok": false, "error": "\#(phrase)"}"#.utf8)
            XCTAssertEqual(IMacLauncher.outcome(status: 0, stdout: refusal), .notOnIMac(phrase))
        }
        let full = Data(#"{"ok": false, "error": "already 12 sessions, the most allowed"}"#.utf8)
        XCTAssertEqual(IMacLauncher.outcome(status: 0, stdout: full), .failed("already 12 sessions, the most allowed"))
        if case .failed = IMacLauncher.outcome(status: 255, stdout: Data()) {} else { XCTFail("ssh's own failure") }
        if case .failed = IMacLauncher.outcome(status: 1, stdout: Data("refused\n".utf8)) {} else { XCTFail("refused") }
    }

    func testResumeRoutesByTheHostTheSessionRanOn() {
        let home = "/Users/x"
        XCTAssertEqual(IMacLauncher.route(host: .mac, cwd: "/Users/x/Projects/a", home: home), .iMacThenMac(folder: "a"))
        XCTAssertEqual(IMacLauncher.route(host: .mac, cwd: "/Users/x/Desktop", home: home), .macOnly)
        XCTAssertEqual(IMacLauncher.route(host: .iMac, cwd: "/Users/x/Projects/a/b", home: home), .iMacOnly(folder: "a/b"))
        XCTAssertEqual(IMacLauncher.route(host: .iMac, cwd: "/Users/x/Projects", home: home), .iMacOnly(folder: "."))
        XCTAssertEqual(IMacLauncher.route(host: .iMac, cwd: "/home/bbdaniels", home: home),
                       .refused(IMacLauncher.outsideProjectsOnIMac), "an iMac session never falls back to this Mac")
    }
}

/// The scan that finds a Ghostty tab attached to an iMac session reads the
/// ssh client's command line as ps prints it (argv joined by spaces, the
/// remote command's quotes kept).
final class IMacAttachScanTests: XCTestCase {
    func testTheAttachCommandItBuildsIsTheOneItFinds() {
        let answer = IMacLauncher.Answer(started: false, session: "ClaudeHUD-2",
            attach: "tmux attach -t " + IMacLauncher.shellQuote("=ClaudeHUD-2"), dir: nil)
        // what ps shows for the argv ["ssh", "-t", "imac", "<attach>"]
        let ps = "ssh -t imac " + answer.attach
        XCTAssertEqual(IMacLauncher.attachTarget(command: ps), "ClaudeHUD-2")
        XCTAssertEqual(IMacLauncher.attachTarget(command: "/usr/bin/ssh -t imac tmux attach -t =x"), "x")
    }

    func testOtherCommandsAreNotAttaches() {
        XCTAssertNil(IMacLauncher.attachTarget(command: "ssh imac tmux ls"))
        XCTAssertNil(IMacLauncher.attachTarget(command: "ssh -t pi tmux attach -t =x"))
        XCTAssertNil(IMacLauncher.attachTarget(command: "tmux attach -t =x"))
        XCTAssertNil(IMacLauncher.attachTarget(command: "claude attach abc123"))
    }
}
