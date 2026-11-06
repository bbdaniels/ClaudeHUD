import XCTest

/// The gates' `procs` answer read by `HostProcs`, and the orange dot it
/// lights (Ben, 2026-11-06: "we know when there's a process out").
final class HostProcsTests: XCTestCase {
    let answer = """
    {"ok": true,
     "procs": [
       {"pid": 12, "start": 345, "state": "lost", "command": "opencode serve", "cwd": "/home/bbdaniels/Projects/nemesis-tv",
        "sessionId": "gone", "login": null, "seconds": 90000, "processes": 3},
       {"pid": 13, "start": 346, "state": "out", "command": "npm run dev", "cwd": "/home/bbdaniels/Projects/ai-med",
        "sessionId": "live", "login": null, "seconds": 600, "processes": 5, "kind": "job"},
       {"pid": 14, "start": 347, "state": "lost", "command": "tail -F build.log", "cwd": "/Users/b",
        "sessionId": "ended", "login": null, "seconds": 9000, "processes": 3, "kind": "watch"},
       {"pid": 15, "start": 348, "state": "lost", "command": "opencode serve --service", "cwd": "/Users/b",
        "sessionId": "live", "login": null, "seconds": 9000, "processes": 1, "kind": "service"},
       {"pid": "bad"}],
     "tasks": [{"sessionId": "agents", "open": 2}]}
    """

    func testReadsTreesAndTasksAndMapsAnIMacCwdOntoThisMac() throws {
        let s = try XCTUnwrap(HostProcs.snapshot(from: Data(answer.utf8), host: .iMac))
        XCTAssertEqual(s.trees.map(\.pid), [12, 13, 14, 15], "a malformed row is skipped")
        XCTAssertEqual(s.trees.map(\.isWatch), [false, false, true, false], "no kind reads as a job")
        XCTAssertEqual(s.idleServices.map(\.pid), [15])
        XCTAssertEqual(s.trees[0].cwd, NSHomeDirectory() + "/Projects/nemesis-tv")
        XCTAssertEqual(s.trees[0].start, 345)
        XCTAssertEqual(s.lost(live: []).map(\.pid), [12, 14], "an idle service is never listed")
        XCTAssertEqual(s.lost(live: ["gone"]).map(\.pid), [14], "a tree whose session runs on the other machine is owned")
        XCTAssertEqual(s.openTasks, ["agents": 2])
        XCTAssertNil(HostProcs.snapshot(from: Data(#"{"ok": false, "error": "x"}"#.utf8), host: .mac))
        let mac = try XCTUnwrap(HostProcs.snapshot(from: Data(answer.utf8), host: .mac))
        XCTAssertEqual(mac.trees[0].cwd, "/home/bbdaniels/Projects/nemesis-tv", "a Mac cwd is kept as is")
    }

    func testWorkOutIsAnOpenTaskOrAnyTreeTheSessionStarted() throws {
        let s = try XCTUnwrap(HostProcs.snapshot(from: Data(answer.utf8), host: .mac))
        XCTAssertTrue(s.hasWorkOut(sessionId: "agents"))
        XCTAssertTrue(s.hasWorkOut(sessionId: "live"))
        let serviceOnly = HostProcsSnapshot(trees: s.trees.filter(\.isService))
        XCTAssertFalse(serviceOnly.hasWorkOut(sessionId: "live"), "an idle service it started is not its work out")
        XCTAssertTrue(s.hasWorkOut(sessionId: "gone"), "live on the other machine, so its tree is its work out")
        XCTAssertFalse(s.hasWorkOut(sessionId: "other"))
        XCTAssertFalse(s.hasWorkOut(sessionId: nil))
    }

    func testAStoppedTurnWithWorkOutIsOrangeAndARunningOneGreen() {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        func light(running: Bool, workOut: Bool, quiet: TimeInterval = 60) -> SessionLight {
            SessionLight.of(running: running, workOut: workOut, hasWindow: false,
                            lastMoved: now.addingTimeInterval(-quiet), now: now)
        }
        XCTAssertEqual(light(running: false, workOut: true), .holding)
        XCTAssertEqual(light(running: false, workOut: true, quiet: 7200), .holding, "work out is never a leftover")
        XCTAssertEqual(light(running: true, workOut: true), .running)
        XCTAssertEqual(light(running: false, workOut: false), .attention)
    }
}
