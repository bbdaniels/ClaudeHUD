import XCTest

/// The History scan over both hosts (`SessionScan`): the Mac's own
/// transcripts and the iMac's mirror, each row tagged with its host and an
/// iMac row's directory mapped onto this Mac.
final class SessionScanTests: XCTestCase {

    func tempHome() throws -> String {
        let d = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: d) }
        return d.path
    }

    /// A transcript whose head classifies as a person's session.
    func writeTranscript(_ path: String, prompt: String, modified: Date) throws {
        let j: [String: Any] = ["type": "user", "entrypoint": "cli",
                                "message": ["role": "user", "content": prompt]]
        let line = try JSONSerialization.data(withJSONObject: j, options: [.sortedKeys])
        let url = URL(fileURLWithPath: path)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try (line + Data("\n".utf8)).write(to: url)
        try FileManager.default.setAttributes([.modificationDate: modified], ofItemAtPath: path)
    }

    func scan(home: String) -> SessionScan.Result {
        SessionScan.scan(roots: SessionHost.allCases.map { (host: $0, dir: $0.projectsDir(home: home)) },
                         headCache: [:], sidecarTitles: [:], home: home)
    }

    func testAnIMacTranscriptIsListedAsTheIMacsUnderTheMacsCheckout() throws {
        let home = try tempHome()
        try FileManager.default.createDirectory(atPath: home + "/Projects/heat-tv", withIntermediateDirectories: true)
        let mirror = SessionHost.iMac.projectsDir(home: home)
        let macDir = SessionHost.mac.projectsDir(home: home) + "/" + SessionHost.encodeDirName(home + "/Projects/heat-tv")
        try writeTranscript(mirror + "/-home-bbdaniels-Projects-heat-tv/i1.jsonl",
                            prompt: "Fix the schedule page", modified: Date(timeIntervalSince1970: 2_000))
        try writeTranscript(mirror + "/-home-bbdaniels/i2.jsonl",
                            prompt: "Check the disk", modified: Date(timeIntervalSince1970: 1_000))
        try writeTranscript(macDir + "/m1.jsonl", prompt: "Draft the readme", modified: Date(timeIntervalSince1970: 3_000))

        let result = scan(home: home)
        XCTAssertEqual(result.sessions.map(\.id), ["m1", "i1", "i2"], "both hosts, one list, newest first")
        let byId = Dictionary(uniqueKeysWithValues: result.sessions.map { ($0.id, $0) })
        XCTAssertEqual(byId["m1"]?.host, .mac)
        XCTAssertEqual(byId["i1"]?.host, .iMac)
        XCTAssertEqual(byId["i1"]?.projectPath, home + "/Projects/heat-tv")
        XCTAssertEqual(byId["i1"]?.projectName, "heat-tv")
        XCTAssertEqual(byId["i1"]?.preview, "Fix the schedule page")
        XCTAssertEqual(byId["m1"]?.projectPath, home + "/Projects/heat-tv")
        XCTAssertEqual(byId["i2"]?.projectPath, "/home/bbdaniels", "outside ~/Projects the path stays the iMac's")
        XCTAssertEqual(Set(result.changedHeads.keys).count, 3, "mirror transcripts share the one head cache")
    }

    func testASessionOnBothHostsIsListedOnceFromTheLaterFile() throws {
        let home = try tempHome()
        try FileManager.default.createDirectory(atPath: home + "/Projects/a", withIntermediateDirectories: true)
        let mirror = SessionHost.iMac.projectsDir(home: home) + "/-home-bbdaniels-Projects-a"
        let macDir = SessionHost.mac.projectsDir(home: home) + "/" + SessionHost.encodeDirName(home + "/Projects/a")
        try writeTranscript(mirror + "/s.jsonl", prompt: "Later on the iMac", modified: Date(timeIntervalSince1970: 5_000))
        try writeTranscript(macDir + "/s.jsonl", prompt: "Earlier on the Mac", modified: Date(timeIntervalSince1970: 4_000))
        let sessions = scan(home: home).sessions
        XCTAssertEqual(sessions.count, 1)
        XCTAssertEqual(sessions.first?.host, .iMac)
        XCTAssertEqual(sessions.first?.preview, "Later on the iMac")
    }

    func testOnATieTheMacsCopyIsKept() {
        let t = Date(timeIntervalSince1970: 10)
        let i = SessionInfo(id: "s", projectPath: "/p", projectName: "p", preview: "i", timestamp: t, filePath: "/i", host: .iMac)
        let m = SessionInfo(id: "s", projectPath: "/p", projectName: "p", preview: "m", timestamp: t, filePath: "/m", host: .mac)
        XCTAssertEqual(SessionScan.merge([i, m]).map(\.host), [.mac])
        XCTAssertEqual(SessionScan.merge([m, i]).map(\.host), [.mac])
    }

    func testAnIMacDirectoryDecodesToTheMacsCheckout() throws {
        let home = try tempHome()
        try FileManager.default.createDirectory(atPath: home + "/Projects/heat-tv", withIntermediateDirectories: true)
        let decoded = SessionScan.decodeProjectDir("-home-bbdaniels-Projects-heat-tv", host: .iMac, home: home)
        XCTAssertEqual(decoded.path, home + "/Projects/heat-tv")
        XCTAssertEqual(SessionScan.decodeProjectDir("-home-bbdaniels", host: .iMac, home: home).path, "/home/bbdaniels")
    }

    func testAnIMacOnlyWorktreeTakesItsPathFromTheTranscript() throws {
        let home = try tempHome()
        try FileManager.default.createDirectory(atPath: home + "/Projects/nemesis-tv", withIntermediateDirectories: true)
        let dir = SessionHost.iMac.projectsDir(home: home) + "/-home-bbdaniels-Projects-nemesis-tv--claude-worktrees-visual-pass"
        try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        // As `--worktree` writes it: the main checkout first, the worktree
        // once it is made, past the 64 KB head.
        func line(_ cwd: String, _ text: String) throws -> Data {
            let j: [String: Any] = ["type": "user", "entrypoint": "cli", "message": ["role": "user", "content": text], "cwd": cwd]
            return try JSONSerialization.data(withJSONObject: j, options: [.sortedKeys]) + Data("\n".utf8)
        }
        var data = try line("/home/bbdaniels/Projects/nemesis-tv", "Polish the grid")
        let filler = try line("/home/bbdaniels/Projects/nemesis-tv", String(repeating: "x", count: 1000))
        for _ in 0..<400 { data += filler }
        data += try line("/home/bbdaniels/Projects/nemesis-tv/.claude/worktrees/visual-pass", "Now in the worktree")
        try data.write(to: URL(fileURLWithPath: dir + "/w.jsonl"))
        let s = try XCTUnwrap(scan(home: home).sessions.first)
        XCTAssertEqual(s.projectPath, home + "/Projects/nemesis-tv/.claude/worktrees/visual-pass")
        XCTAssertEqual(s.worktreeName, "visual-pass")
        XCTAssertEqual(IMacLauncher.route(host: .iMac, cwd: s.projectPath, home: home),
                       .iMacOnly(folder: "nemesis-tv/.claude/worktrees/visual-pass"))
    }

    func testARecordedDirectoryThatIsNotTheStartDirectoryIsNotTaken() throws {
        let home = try tempHome()
        try FileManager.default.createDirectory(atPath: home + "/Projects/a", withIntermediateDirectories: true)
        let dir = SessionHost.iMac.projectsDir(home: home) + "/-home-bbdaniels-Projects-a"
        try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        let j: [String: Any] = ["type": "user", "entrypoint": "cli", "message": ["role": "user", "content": "Something"],
                                "cwd": "/home/bbdaniels/Projects/b"]
        try JSONSerialization.data(withJSONObject: j, options: [.sortedKeys]).write(to: URL(fileURLWithPath: dir + "/x.jsonl"))
        XCTAssertEqual(SessionScan.iMacProjectDir("-home-bbdaniels-Projects-a", transcript: dir + "/x.jsonl", home: home).path,
                       home + "/Projects/a", "a directory the folder is not named after falls back to the decoder")
    }
}
