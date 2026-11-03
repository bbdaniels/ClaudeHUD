import XCTest

/// Which transcripts history lists (`TranscriptHead.classify`) and the record
/// readers it shares with the index (`TranscriptRecord`). The fixtures are
/// shaped like the records Claude Code 2.1 writes: a phone session's user
/// records read `entrypoint: "sdk-cli"` and `promptSource: "sdk"` like a
/// programmatic one-shot, and only `turnOrigin` / `clientPlatform` set them apart.
final class TranscriptHeadTests: XCTestCase {

    func record(_ fields: [String: Any], text: String) -> String {
        var j = fields
        j["type"] = "user"
        j["message"] = ["role": "user", "content": text]
        let data = try! JSONSerialization.data(withJSONObject: j, options: [.sortedKeys])
        return String(data: data, encoding: .utf8)!
    }

    func head(_ lines: String...) -> TranscriptHead.Verdict {
        TranscriptHead.classify(text: lines.joined(separator: "\n") + "\n")
    }

    // MARK: Classification

    func testHumanSdkCliSessionIsKeptAndTitledFromTheFirstHumanPrompt() {
        let v = head(
            record(["entrypoint": "sdk-cli", "promptSource": "sdk", "isMeta": true],
                   text: "Base directory for this skill: /Users/x/.claude/skills/project"),
            record(["entrypoint": "sdk-cli", "promptSource": "sdk", "turnOrigin": "human", "clientPlatform": "ios"],
                   text: "Why is the SportsPredict badge stale?"))
        XCTAssertEqual(v, .normal("Why is the SportsPredict badge stale?"))
    }

    func testClientPlatformAloneMarksAHumanTurn() {
        let v = head(record(["entrypoint": "sdk-cli", "promptSource": "sdk", "clientPlatform": "ios"],
                            text: "Check the runner"))
        XCTAssertEqual(v, .normal("Check the runner"))
    }

    func testDesktopAppSessionIsKept() {
        let v = head(record(["entrypoint": "claude-desktop", "promptSource": "sdk", "turnOrigin": "human"],
                            text: "Draft the memo"))
        XCTAssertEqual(v, .normal("Draft the memo"))
    }

    func testOneShotSdkCliSessionIsDropped() {
        let v = head(record(["entrypoint": "sdk-cli", "promptSource": "sdk"],
                            text: "Summarize this transcript in one line."))
        XCTAssertEqual(v, .machine)
    }

    func testHumanSessionWithAMachineLookingPromptIsStillDroppedByPrefix() {
        // The prefix list still applies to a human turn: a probe someone
        // typed into the phone is a probe.
        let v = head(record(["entrypoint": "sdk-cli", "turnOrigin": "human"], text: "Reply with exactly the word: PONG"))
        XCTAssertEqual(v, .machine)
    }

    func testPeerOnlySessionIsDropped() {
        let v = head(
            record(["entrypoint": "cli", "promptSource": "system", "turnOrigin": "peer", "isMeta": true],
                   text: "Another Claude session sent a message: rebase done"),
            record(["entrypoint": "cli", "promptSource": "system", "turnOrigin": "peer", "isMeta": true],
                   text: "Another Claude session sent a message: tests pass"))
        XCTAssertEqual(v, .machine)
    }

    func testPeerTurnBeforeATypedPromptDoesNotDropTheSession() {
        let v = head(
            record(["entrypoint": "cli", "promptSource": "system", "turnOrigin": "peer", "isMeta": true],
                   text: "Another Claude session sent a message"),
            record(["entrypoint": "cli", "promptSource": "typed"], text: "Thanks, now merge it"))
        XCTAssertEqual(v, .normal("Thanks, now merge it"))
    }

    func testTerminalTypedSessionIsUnchanged() {
        XCTAssertEqual(head(record(["entrypoint": "cli", "promptSource": "typed"], text: "hello")), .normal("hello"))
    }

    func testMagicLaunchIsStillRecognised() {
        let v = head(record(["entrypoint": "cli"],
                            text: "<command-message>project</command-message>\n<command-name>/project</command-name>\n<command-args>SportsPredict Bot</command-args>"))
        XCTAssertEqual(v, .magicLaunch("SportsPredict Bot"))
    }

    func testEmptyHeadIsUnknown() {
        XCTAssertEqual(head(""), .unknown)
    }

    // MARK: Record working directory

    func testCwdIsTheLastOccurrenceInTheLine() {
        let line = #"{"attachment":{"git_state":{"cwd":"/tmp/nested"}},"cwd":"/Users/x/Projects/obsidian/SportsPredict Bot","type":"user"}"#
        XCTAssertEqual(TranscriptRecord.cwd(inLine: Data(line.utf8)), "/Users/x/Projects/obsidian/SportsPredict Bot")
    }

    func testCwdWithAnEscapeIsDecoded() {
        let line = #"{"cwd":"/Users/x/a \"quoted\" dir","type":"user"}"#
        XCTAssertEqual(TranscriptRecord.cwd(inLine: Data(line.utf8)), #"/Users/x/a "quoted" dir"#)
    }

    func testLineWithoutCwd() {
        XCTAssertNil(TranscriptRecord.cwd(inLine: Data(#"{"type":"summary"}"#.utf8)))
    }

    func testTallyCountsRecordsPerDirectory() {
        let chunk = """
        {"cwd":"/p/a","type":"user"}
        {"cwd":"/p/a","type":"assistant"}
        {"cwd":"/p/b","type":"user"}
        {"type":"summary"}

        """
        var counts: [String: Int] = ["/p/b": 1]
        TranscriptRecord.tallyCwds(in: Data(chunk.utf8), into: &counts)
        XCTAssertEqual(counts, ["/p/a": 2, "/p/b": 2])
    }

    func testHumanTurnMarkersMatchThePhoneRecord() {
        let line = Data(record(["entrypoint": "sdk-cli", "promptSource": "sdk", "turnOrigin": "human"], text: "x").utf8)
        XCTAssertTrue(TranscriptRecord.humanTurnMarkers.contains { line.range(of: $0) != nil })
        let oneShot = Data(record(["entrypoint": "sdk-cli", "promptSource": "sdk"], text: "x").utf8)
        XCTAssertFalse(TranscriptRecord.humanTurnMarkers.contains { oneShot.range(of: $0) != nil })
    }
}
