import XCTest

/// How an iMac session's paths read on this Mac (`SessionHost`) and the
/// mirror's rsync call (`IMacMirror`).
final class SessionHostTests: XCTestCase {

    func testIMacProjectsPathsMapOntoTheMacsProjects() {
        let home = "/Users/x"
        XCTAssertEqual(SessionHost.iMac.macPath("/home/bbdaniels/Projects/heat-tv/src", home: home),
                       "/Users/x/Projects/heat-tv/src")
        XCTAssertEqual(SessionHost.iMac.macPath("/home/bbdaniels/Projects", home: home), "/Users/x/Projects")
        XCTAssertEqual(SessionHost.iMac.macPath("/home/bbdaniels", home: home), "/home/bbdaniels",
                       "outside ~/Projects the Mac has no copy, so the path stays the iMac's")
        XCTAssertEqual(SessionHost.iMac.macPath("/home/bbdaniels/ProjectsOld/a", home: home),
                       "/home/bbdaniels/ProjectsOld/a")
        XCTAssertEqual(SessionHost.mac.macPath("/home/bbdaniels/Projects/a", home: home),
                       "/home/bbdaniels/Projects/a", "the Mac's own paths are never mapped")
    }

    func testIMacDirectoryNamesMapToTheMacsEncoding() {
        let home = "/Users/x"
        XCTAssertEqual(SessionHost.iMac.macDirName("-home-bbdaniels-Projects-heat-tv", home: home),
                       "-Users-x-Projects-heat-tv")
        XCTAssertEqual(SessionHost.iMac.macDirName("-home-bbdaniels-Projects", home: home), "-Users-x-Projects")
        XCTAssertNil(SessionHost.iMac.macDirName("-home-bbdaniels", home: home))
        XCTAssertNil(SessionHost.iMac.macDirName("-home-bbdaniels-ProjectsOld", home: home))
        XCTAssertNil(SessionHost.mac.macDirName("-home-bbdaniels-Projects-a", home: home))
        XCTAssertEqual(SessionHost.encodeDirName("/Users/a_b/.claude"), "-Users-a-b--claude")
    }

    func testEachHostHasItsOwnDirectories() {
        let home = "/Users/x"
        XCTAssertEqual(SessionHost.mac.projectsDir(home: home), "/Users/x/.claude/projects")
        XCTAssertEqual(SessionHost.iMac.projectsDir(home: home), "/Users/x/Library/Caches/ClaudeHUD/hosts/imac/projects")
        XCTAssertEqual(SessionHost.mac.claimsDir(home: home).path, "/Users/x/.claude/session-projects")
        XCTAssertEqual(SessionHost.iMac.claimsDir(home: home).path,
                       "/Users/x/Library/Caches/ClaudeHUD/hosts/imac/session-projects")
    }

    func testTheMirrorCopiesOnlyTopLevelTranscriptsAndClaimsReadOnly() {
        let args = IMacMirror.rsyncArguments(root: "/m")
        XCTAssertEqual(Array(args.suffix(2)), ["imac:.claude/", "/m/"], "from the iMac, into the mirror; never the other way")
        XCTAssertTrue(args.contains("--delete"))
        XCTAssertTrue(args.contains("--include=/projects/*/*.jsonl"))
        XCTAssertTrue(args.contains("--include=/session-projects/*.json"))
        XCTAssertEqual(args.filter { $0.hasPrefix("--include") || $0.hasPrefix("--exclude") }.last, "--exclude=*",
                       "everything not included is excluded, including subagent folders")
        XCTAssertFalse(args.contains { $0.hasPrefix("-") && !$0.hasPrefix("--") && $0.contains("z") },
                       "no compression: openrsync's -z stalls against the iMac's rsync")
        XCTAssertTrue(args.contains("ssh -o BatchMode=yes -o ConnectTimeout=10"))
    }

    func testAMissingIMacGivesAFailureNotAHang() throws {
        // A root the run cannot even create fails at once and leaves nothing behind.
        if case .failed = IMacMirror.run(root: "/dev/null/mirror") {} else { XCTFail("expected a failure") }
    }

    /// The gate's `live` answer reads into records; tmux and the bridge survive.
    func testIMacLiveReadsTheGatesAnswer() {
        let json = """
        {"ok": true, "live": [
          {"pid": 4242, "sessionId": "59dc567e-0000-0000-0000-000000000000", "cwd": "/home/bbdaniels/Projects/personal",
           "kind": "interactive", "entrypoint": "cli", "status": "waiting", "waitingFor": "approve Bash",
           "bridgeSessionId": "session_01ABC", "tmux": "handoff:@4.%4", "procStart": "9765587"}
        ]}
        """
        let records = IMacLive.records(from: Data(json.utf8))
        XCTAssertEqual(records?.count, 1)
        XCTAssertEqual(records?.first?.tmux, "handoff:@4.%4")
        XCTAssertEqual(records?.first?.waitingFor, "approve Bash")
        XCTAssertEqual(records?.first?.remoteControlURL?.absoluteString, "https://claude.ai/code/session_01ABC")
        XCTAssertEqual(SessionHost.iMac.macPath(records!.first!.cwd, home: "/Users/x"), "/Users/x/Projects/personal")
    }

    /// A refusal or a non-gate answer is nil, never an empty "nothing runs".
    func testIMacLiveRejectsAFailedAnswer() {
        XCTAssertNil(IMacLive.records(from: Data(#"{"ok": false, "error": "no"}"#.utf8)))
        XCTAssertNil(IMacLive.records(from: Data("not json".utf8)))
    }
}
