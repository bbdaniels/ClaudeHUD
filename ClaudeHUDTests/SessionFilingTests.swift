import XCTest

/// The one filing rule (`SessionFiling`: claim, then the dominant record
/// directory, then the start directory) and the reader of the CLI's live
/// session records (`ClaudeSessionRecords`), which is how ClaudeHUD sees a
/// session started from the Claude app through Remote Control.
final class SessionFilingTests: XCTestCase {

    /// A stand-in for `ProjectResolver`: anything under /p/<name> is project <name>.
    func resolve(_ cwd: String) -> String? {
        let parts = cwd.split(separator: "/")
        guard parts.count >= 2, parts[0] == "p" else { return nil }
        return String(parts[1])
    }

    func claim(_ folder: String) -> SessionFiling.Claim {
        SessionFiling.Claim(sessionId: "s1", folder: folder, vaultPath: nil, cwd: nil, source: "hook")
    }

    func tempDir() throws -> URL {
        let d = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: d) }
        return d
    }

    // MARK: Resolution order

    func testClaimWinsOverRecordsAndStartDirectory() {
        let folder = SessionFiling.resolveFolder(claim: claim("Claimed"), cwdCounts: ["/p/A": 50],
                                                 fallbackCwd: "/p/B", resolve: resolve)
        XCTAssertEqual(folder, "Claimed")
    }

    func testDominantRecordDirectoryWinsOverStartDirectory() {
        let folder = SessionFiling.resolveFolder(claim: nil, cwdCounts: ["/p/A": 10, "/p/A/plans": 5, "/p/B": 12],
                                                 fallbackCwd: "/Users/x/Projects", resolve: resolve)
        XCTAssertEqual(folder, "A", "counts are summed per project, not per directory")
    }

    func testDirectoriesThatResolveToNothingAreIgnored() {
        let folder = SessionFiling.resolveFolder(claim: nil, cwdCounts: ["/private/tmp/scratch": 900, "/p/A": 3],
                                                 fallbackCwd: "/p/B", resolve: resolve)
        XCTAssertEqual(folder, "A")
    }

    func testFallsBackToTheStartDirectory() {
        XCTAssertEqual(SessionFiling.resolveFolder(claim: nil, cwdCounts: ["/tmp/x": 4], fallbackCwd: "/p/B",
                                                   resolve: resolve), "B")
        XCTAssertEqual(SessionFiling.resolveFolder(claim: nil, cwdCounts: [:], fallbackCwd: "/p/B/.claude/worktrees/w1",
                                                   resolve: resolve), "B", "a worktree files under its repo")
        XCTAssertNil(SessionFiling.resolveFolder(claim: nil, cwdCounts: [:], fallbackCwd: "", resolve: resolve))
    }

    func testATieFilesByTheStartDirectory() {
        let folder = SessionFiling.resolveFolder(claim: nil, cwdCounts: ["/p/A": 5, "/p/B": 5],
                                                 fallbackCwd: "/p/C", resolve: resolve)
        XCTAssertEqual(folder, "C")
    }

    // MARK: Claim records

    func testParseClaim() {
        let data = Data(#"{"sessionId":"s1","folder":"SportsPredict Bot","vaultPath":"/v/SportsPredict Bot","cwd":"/Users/x/Projects","claimedAt":"2026-11-03T10:00:00Z","source":"project-command"}"#.utf8)
        XCTAssertEqual(SessionFiling.parseClaim(data),
                       SessionFiling.Claim(sessionId: "s1", folder: "SportsPredict Bot", vaultPath: "/v/SportsPredict Bot",
                                           cwd: "/Users/x/Projects", source: "project-command"))
        XCTAssertNil(SessionFiling.parseClaim(Data(#"{"sessionId":"s1","folder":"  "}"#.utf8)))
        XCTAssertNil(SessionFiling.parseClaim(Data("not json".utf8)))
    }

    func testReadClaimFromDisk() throws {
        let dir = try tempDir()
        try Data(#"{"sessionId":"s1","folder":"A"}"#.utf8).write(to: dir.appendingPathComponent("s1.json"))
        try Data(#"{"sessionId":"other","folder":"B"}"#.utf8).write(to: dir.appendingPathComponent("s2.json"))
        XCTAssertEqual(SessionFiling.readClaim(sessionId: "s1", in: dir)?.folder, "A")
        XCTAssertNil(SessionFiling.readClaim(sessionId: "s2", in: dir), "a record naming another session is not this one's")
        XCTAssertNil(SessionFiling.readClaim(sessionId: "s3", in: dir))
        XCTAssertNil(SessionFiling.readClaim(sessionId: "../s1", in: dir))
    }

    // MARK: Live session records

    let phone = #"{"pid":4242,"sessionId":"eb01fb79-0000","cwd":"/Users/x/Projects","startedAt":1762146528000,"procStart":"Tue Nov  3 00:08:48 2026","kind":"interactive","entrypoint":"sdk-cli","name":"Badge fix","nameSource":"ai","bridgeSessionId":"session_01ABC","status":"waiting","waitingFor":"permission prompt","updatedAt":1762146600000}"#
    let bgJob = #"{"pid":4343,"sessionId":"80ef1160-0000","cwd":"/Users/x/Projects/cayda","kind":"bg","entrypoint":"cli","jobId":"a1b2c3","bridgeSessionId":"session_01DEF","status":"busy"}"#
    let terminal = #"{"pid":4444,"sessionId":"1630d40c-0000","cwd":"/Users/x/Projects/sportspredict","kind":"interactive","entrypoint":"cli","bridgeSessionId":"session_01GHI","status":"idle"}"#

    func testParsePhoneRecord() throws {
        let r = try XCTUnwrap(ClaudeSessionRecords.parse(Data(phone.utf8)))
        XCTAssertEqual(r.pid, 4242)
        XCTAssertEqual(r.sessionId, "eb01fb79-0000")
        XCTAssertEqual(r.name, "Badge fix")
        XCTAssertEqual(r.cwd, "/Users/x/Projects")
        XCTAssertEqual(r.waitingFor, "permission prompt")
        XCTAssertEqual(r.updatedAt, Date(timeIntervalSince1970: 1762146600))
        XCTAssertTrue(r.isRemoteControlChild)
        XCTAssertEqual(r.remoteControlURL, URL(string: "https://claude.ai/code/session_01ABC"))
        XCTAssertEqual(r.displayState, "waiting")
    }

    func testBackgroundJobAndTerminalSessionAreNotRemoteControlChildren() throws {
        XCTAssertFalse(try XCTUnwrap(ClaudeSessionRecords.parse(Data(bgJob.utf8))).isRemoteControlChild)
        XCTAssertFalse(try XCTUnwrap(ClaudeSessionRecords.parse(Data(terminal.utf8))).isRemoteControlChild)
    }

    func testStatusMapping() {
        func state(_ status: String?) -> String {
            let field = status.map { #","status":"\#($0)""# } ?? ""
            return ClaudeSessionRecords.parse(Data(#"{"pid":1,"sessionId":"s"\#(field)}"#.utf8))!.displayState
        }
        XCTAssertEqual(state("idle"), "idle")
        XCTAssertEqual(state("waiting"), "waiting")
        XCTAssertEqual(state("busy"), "busy")
        XCTAssertEqual(state("shell"), "busy")
        XCTAssertEqual(state(nil), "busy")
    }

    func testMalformedRecordsAreRejected() {
        XCTAssertNil(ClaudeSessionRecords.parse(Data(#"{"sessionId":"s"}"#.utf8)))
        XCTAssertNil(ClaudeSessionRecords.parse(Data(#"{"pid":0,"sessionId":"s"}"#.utf8)))
        XCTAssertNil(ClaudeSessionRecords.parse(Data(#"{"pid":5,"sessionId":""}"#.utf8)))
    }

    func testReadLiveKeepsOnlyRunningRecordsAndFindsTheHolder() throws {
        let dir = try tempDir()
        try Data(phone.utf8).write(to: dir.appendingPathComponent("4242.json"))
        try Data(bgJob.utf8).write(to: dir.appendingPathComponent("4343.json"))
        try Data("garbage".utf8).write(to: dir.appendingPathComponent("1.json"))
        let live = ClaudeSessionRecords.readLive(in: dir, isRunning: { $0.pid == 4242 })
        XCTAssertEqual(live.map(\.pid), [4242])
        XCTAssertEqual(ClaudeSessionRecords.liveHolder(of: "eb01fb79-0000", in: live)?.pid, 4242)
        XCTAssertNil(ClaudeSessionRecords.liveHolder(of: "80ef1160-0000", in: live))
    }

    func testProcessLiveness() {
        let me = Int(ProcessInfo.processInfo.processIdentifier)
        XCTAssertTrue(ClaudeSessionRecords.pidExists(me))
        let start = ClaudeSessionRecords.processStartTime(pid: me)
        XCTAssertNotNil(start)
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "EEE MMM d HH:mm:ss yyyy"
        let recorded = f.string(from: start!)
        let mine = ClaudeSessionRecord(pid: me, sessionId: "s", cwd: "", kind: nil, entrypoint: nil, name: nil,
                                       bridgeSessionId: nil, jobId: nil, status: nil, waitingFor: nil,
                                       startedAt: nil, updatedAt: nil, procStart: recorded)
        XCTAssertTrue(ClaudeSessionRecords.isRunning(mine))
        let reused = ClaudeSessionRecord(pid: me, sessionId: "s", cwd: "", kind: nil, entrypoint: nil, name: nil,
                                         bridgeSessionId: nil, jobId: nil, status: nil, waitingFor: nil,
                                         startedAt: nil, updatedAt: nil, procStart: "Mon Jan  5 09:00:00 2026")
        XCTAssertFalse(ClaudeSessionRecords.isRunning(reused), "a pid whose start time differs is a reused pid")
    }

    func testParseProcStartWithPaddedDay() {
        let d = ClaudeSessionRecords.parseProcStart("Tue Nov  3 00:08:48 2026")
        XCTAssertNotNil(d)
        let c = Calendar.current.dateComponents([.year, .month, .day, .hour, .minute, .second], from: d!)
        XCTAssertEqual([c.year, c.month, c.day, c.hour, c.minute, c.second], [2026, 11, 3, 0, 8, 48])
    }

    func testTranscriptPathEncodesTheStartDirectory() throws {
        let projects = try tempDir()
        let enc = projects.appendingPathComponent("-Users-x-Projects-obsidian-SportsPredict-Bot")
        try FileManager.default.createDirectory(at: enc, withIntermediateDirectories: true)
        try Data().write(to: enc.appendingPathComponent("s1.jsonl"))
        XCTAssertEqual(ClaudeSessionRecords.transcriptPath(sessionId: "s1", cwd: "/Users/x/Projects/obsidian/SportsPredict Bot",
                                                           projectsDir: projects),
                       enc.appendingPathComponent("s1.jsonl").path)
        XCTAssertNil(ClaudeSessionRecords.transcriptPath(sessionId: "s2", cwd: "/Users/x/Projects", projectsDir: projects))
    }
}
