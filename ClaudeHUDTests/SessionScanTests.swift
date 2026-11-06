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

    // MARK: Titles from recent history

    private func turn(_ role: String, _ text: String, at ts: String) -> [String: Any] {
        // Assistant text as Claude Code writes it: a list of content blocks.
        let content: Any = role == "assistant" ? [["type": "text", "text": text]] : text
        var j: [String: Any] = ["type": role, "timestamp": ts,
                                "message": ["role": role, "content": content]]
        if role == "user" { j["promptSource"] = "typed" }
        return j
    }

    private func writeRecords(_ recs: [[String: Any]]) throws -> String {
        let dir = NSTemporaryDirectory() + "title-\(UUID().uuidString)"
        try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(atPath: dir) }
        let data = try recs.map { try JSONSerialization.data(withJSONObject: $0, options: [.sortedKeys]) }
            .reduce(Data()) { $0 + $1 + Data("\n".utf8) }
        let path = dir + "/t.jsonl"
        try data.write(to: URL(fileURLWithPath: path))
        return path
    }

    /// The thesis workshop session of 2026-10-27, in miniature: opened with
    /// `/project`, then a status report, then short prompts.
    func testTheTitleContextReadsTheWholeSessionAndItsProject() throws {
        var recs = [turn("user", "<command-message>project</command-message>\n<command-name>/project</command-name>\n<command-args>PPOL 5013 Thesis Workshop :: /Users/bbdaniels/Projects/obsidian/PPOL 5013 Thesis Workshop</command-args>", at: "2026-10-27T18:33:12Z"),
                    turn("assistant", "Status: thesis workshop, submissions due", at: "2026-10-27T18:33:40Z")]
        for k in 1...7 {
            recs.append(turn("user", "prompt \(k)", at: "2026-10-27T19:0\(k):00Z"))
            recs.append(turn("assistant", "reply \(k)", at: "2026-10-27T19:0\(k):30Z"))
        }
        recs.append(turn("user", "[Request interrupted by user]", at: "2026-10-27T19:09:00Z"))
        let c = SessionScan.titleContext(in: try writeRecords(recs))
        XCTAssertEqual(c.launchedProject, "PPOL 5013 Thesis Workshop")
        XCTAssertEqual(c.prompts, (1...7).map { "prompt \($0)" })
        XCTAssertEqual(c.opening, "Status: thesis workshop, submissions due")
        XCTAssertEqual(c.reply, "reply 7")
    }

    /// The whole transcript is read, the middle included, and a compaction
    /// summary is not a prompt (2026-11-06: a 49 MB session read from its
    /// head and tail only was named after its first request).
    func testALongTranscriptIsReadWholeAndSkipsCompactionSummaries() throws {
        var recs = [turn("user", "first prompt", at: "2026-11-03T10:00:00Z"),
                    turn("assistant", "opening status", at: "2026-11-03T10:00:10Z")]
        let filler = String(repeating: "x", count: 1000)
        for k in 0..<3000 { recs.append(turn("assistant", "\(filler) \(k)", at: "2026-11-03T10:01:00Z")) }
        recs.append(turn("user", "middle prompt", at: "2026-11-03T10:30:00Z"))
        recs.append(turn("user", "This session is being continued from a previous conversation that ran out of context.", at: "2026-11-03T10:31:00Z"))
        for k in 0..<3000 { recs.append(turn("assistant", "\(filler) \(k)", at: "2026-11-03T10:32:00Z")) }
        recs.append(turn("user", "last prompt", at: "2026-11-03T11:00:00Z"))
        recs.append(turn("assistant", "latest reply", at: "2026-11-03T11:00:10Z"))
        let c = SessionScan.titleContext(in: try writeRecords(recs))
        XCTAssertEqual(c.prompts, ["first prompt", "middle prompt", "last prompt"])
        XCTAssertEqual(c.opening, "opening status")
        XCTAssertEqual(c.reply, "latest reply")
    }

    func testPromptsAreSampledAcrossTheWholeSession() {
        let few = (1...12).map { "p\($0)" }
        XCTAssertEqual(SessionTitlePrompt.sample(few), few)
        let many = (1...40).map { "p\($0)" }
        let picked = SessionTitlePrompt.sample(many)
        XCTAssertEqual(picked.count, 12)
        XCTAssertEqual(Array(picked.prefix(2)), ["p1", "p2"])
        XCTAssertEqual(Array(picked.suffix(7)), (34...40).map { "p\($0)" })
        XCTAssertTrue(picked[2...4].allSatisfy { many.firstIndex(of: $0)! >= 2 && many.firstIndex(of: $0)! < 33 })
    }

    func testTheTitleMessageNamesTheSessionsProjectAndFolder() {
        var c = SessionTitleContext(project: "PPOL 5013 Thesis Workshop",
                                    folder: "/Users/bbdaniels/Documents/Teaching/PPOL-5013-Thesis-Workshop",
                                    launchedProject: "Something Else",
                                    prompts: ["are they good", "check ai"],
                                    opening: "Status report", reply: "Filled in")
        let m = SessionTitlePrompt.message(c)
        XCTAssertTrue(m.hasPrefix("Project: PPOL 5013 Thesis Workshop\nFolder: /Users/bbdaniels/Documents/Teaching/PPOL-5013-Thesis-Workshop\n"))
        XCTAssertFalse(m.contains("Something Else"))
        XCTAssertTrue(m.contains("1. are they good\n2. check ai"))
        XCTAssertTrue(m.contains("first message:\nStatus report"))
        XCTAssertTrue(m.contains("latest message:\nFilled in"))
        // Unfiled: the project its `/project` named.
        c.project = nil
        XCTAssertTrue(SessionTitlePrompt.message(c).hasPrefix("Project: Something Else\n"))
    }

    /// The call loads no settings (so no hook's project list) and replaces
    /// Claude Code's system prompt with its own.
    func testTheTitleCallIsIsolated() {
        let args = SessionTitlePrompt.arguments(for: SessionTitleContext(prompts: ["x"]))
        let i = args.firstIndex(of: "--setting-sources")!
        XCTAssertEqual(args[i + 1], "")
        let j = args.firstIndex(of: "--system-prompt")!
        XCTAssertEqual(args[j + 1], SessionTitlePrompt.system)
        XCTAssertTrue(args.contains("--strict-mcp-config"))
        XCTAssertEqual(args[args.firstIndex(of: "--tools")! + 1], "")
        XCTAssertFalse(args.contains("--bare"))  // it would drop the subscription login
        XCTAssertEqual(args.last, SessionTitlePrompt.message(SessionTitleContext(prompts: ["x"])))
    }

    func testATitleIsRewrittenAfterAnyNewActivityAtMostOnceAMinute() {
        let now = Date(timeIntervalSince1970: 1_000_000)
        let due = SessionTitleSchedule.due
        // Untitled: at once, as soon as there is anything to name it from.
        XCTAssertTrue(due(nil, true, now, now))
        XCTAssertFalse(due(nil, false, now.addingTimeInterval(-3600), now))
        // Titled two minutes ago: due when the transcript grew since, a
        // prompt or the session's own work alike.
        let titled = now.addingTimeInterval(-120)
        XCTAssertTrue(due(titled, true, now.addingTimeInterval(-10), now))
        XCTAssertFalse(due(titled, true, titled.addingTimeInterval(-1), now))
        // Titled thirty seconds ago: not yet, whatever happened.
        let recent = now.addingTimeInterval(-30)
        XCTAssertFalse(due(recent, true, now, now))
    }

    /// A session opened with `/project` has something to name before its
    /// first typed prompt: "ClaudeHUD vault read" (Ben, 2026-11-06).
    func testASessionHasContentFromAProjectOpenAPromptOrAReply() {
        XCTAssertFalse(SessionTitleContext().hasContent)
        XCTAssertTrue(SessionTitleContext(launchedProject: "ClaudeHUD").hasContent)
        XCTAssertTrue(SessionTitleContext(prompts: ["x"]).hasContent)
        XCTAssertTrue(SessionTitleContext(opening: "Reading the vault").hasContent)
        let m = SessionTitlePrompt.message(SessionTitleContext(launchedProject: "ClaudeHUD"))
        XCTAssertTrue(m.contains("Project: ClaudeHUD"))
        XCTAssertTrue(m.contains("no message yet"))
    }

    func testAFailedSessionIsRetriedAfterTheBackoffNotOnlyAtTheNextLaunch() {
        let now = Date(timeIntervalSince1970: 1_000_000)
        let retry = SessionTitleSchedule.retryDue
        XCTAssertTrue(retry(nil, now))
        XCTAssertFalse(retry(now.addingTimeInterval(-60), now))
        XCTAssertFalse(retry(now.addingTimeInterval(-SessionTitleSchedule.retryAfter + 1), now))
        XCTAssertTrue(retry(now.addingTimeInterval(-SessionTitleSchedule.retryAfter), now))
    }

    func testAFailedCallIsDescribedByItsExitAndBothOutputsOnOneLine() {
        let d = SessionTitleFailure.describe(status: 1, stdout: "Claude AI usage limit reached\n",
                                             stderr: "Error: something\nsecond line\n")
        XCTAssertEqual(d, "exit 1; stdout: Claude AI usage limit reached; stderr: Error: something second line")
        XCTAssertEqual(SessionTitleFailure.describe(status: 0, stdout: "", stderr: ""),
                       "exit 0; stdout: (empty); stderr: (empty)")
        let long = String(repeating: "x", count: 1000)
        XCTAssertLessThanOrEqual(SessionTitleFailure.describe(status: 2, stdout: long, stderr: long).count, 2 * 300 + 40)
        XCTAssertEqual(SessionTitleFailure.describe(status: nil, stdout: "", stderr: "", launchError: "no such file"),
                       "did not start: no such file")
    }
}
