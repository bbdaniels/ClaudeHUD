import XCTest

/// Fixture process tables modeled on the live machine of 2026-10-05: three
/// attached HUD sessions, one unattended background job (usopen-bot, pty-host
/// reparented to launchd after a daemon restart), the daemon's warm spare,
/// a foreground `claude --resume` in a terminal, and Claude.app.
final class ClaudeProcessClassifierTests: XCTestCase {
    let now = Date(timeIntervalSince1970: 1_791_230_000)
    let rv = "/tmp/cc-daemon-501/a31416c7/rv"
    let spare = "/tmp/cc-daemon-501/a31416c7/spare"

    func host(_ x: String) -> String {
        "claude bg-pty-host --bg-pty-host \(spare)/\(x).pty.sock 200 50 -- /Users/u/.local/share/claude/versions/2.1.289 --bg-spare \(spare)/\(x).claim.sock"
    }
    func worker(_ x: String) -> String { "claude bg-spare --bg-spare \(spare)/\(x).claim.sock" }

    /// pid ppid rssKB etime tty command
    var basePS: String {
        """
          2784     1 101936 02-22:01:45 ??       /Applications/ClaudeHUD.app/Contents/MacOS/ClaudeHUD
         13178     1  71904       14:05 ??       /Applications/Claude.app/Contents/MacOS/Claude
         13222 13178  96320       13:59 ??       /Applications/Claude.app/Contents/Frameworks/Claude Helper (Renderer).app/Contents/MacOS/Claude Helper (Renderer) --type=renderer
         15674     1  64976 01-18:26:35 ??       /Users/u/.local/bin/claude daemon run --json-path /Users/u/.claude/daemon.json
         12116     1   7024 08-01:58:21 ??       \(host("046f7425"))
         12124 12116 194896 08-01:58:21 ttys020  \(worker("046f7425"))
         12200 12124  40000 08-01:58:00 ttys020  node /Users/u/mcp/server.js
         93964     1   8112 04-01:42:02 ??       \(host("d2b6b617"))
         93979 93964 359664 04-01:42:02 ttys004  \(worker("d2b6b617"))
         99917     1  24224 04-01:26:29 ??       /Applications/Ghostty.app/Contents/MacOS/ghostty --quit-after-last-window-closed --title=dissertation --command=/tmp/claude-resume-A9B84090.sh
         99918 99917   2416 04-01:26:28 ttys004  /usr/bin/login -flp u /bin/bash --noprofile --norc -c exec -l /tmp/claude-resume-A9B84090.sh
         99919 99918    528 04-01:26:28 ttys004  /bin/zsh /tmp/claude-resume-A9B84090.sh
         99975 99919  37120 04-01:26:26 ttys004  claude attach 06b55469
         18569 15674  32896       03:19 ??       \(host("d95a5023"))
         18574 18569  28800       03:19 ttys030  \(worker("d95a5023"))
         73897 73896   1000 01-06:29:30 ttys012  -/bin/zsh
         73915 73897 257456 01-06:29:28 ttys012  claude --resume ff7e9168-ec7b-454a-bbcd-6b9766271ad8 --remote-control qutub
         73950 73915  30000 01-06:29:00 ttys012  claude mcp serve
        """
    }

    var baseLsof: String {
        """
        p12124
        fcwd
        n/Users/u/Projects/sportspredict
        f8
        n\(rv)/84dd1631.sock
        p93979
        fcwd
        n/Users/u/Projects/dissertation
        f9
        n\(rv)/06b55469.sock
        p18574
        fcwd
        n/private\(spare)
        f6
        n\(spare)/d95a5023.claim.sock
        p73915
        fcwd
        n/Users/u/Projects/qutub-india
        """
    }

    var roster: DaemonRoster {
        DaemonRoster(supervisorPid: 15674, workers: [
            "84dd1631": RosterWorker(short: "84dd1631", pid: 12116, replPid: 12124,
                                     cwd: "/Users/u/Projects/usopen-bot", sessionId: "84dd1631-e7a9"),
            "06b55469": RosterWorker(short: "06b55469", pid: 93964, replPid: 93979,
                                     cwd: "/Users/u/Projects/dissertation", sessionId: "06b55469-dd62"),
        ])
    }

    func job(_ short: String, cwd: String, state: String = "working", tempo: String? = "idle",
             transcriptAge: TimeInterval?, updatedAgo: TimeInterval = 60) -> JobRecord {
        JobRecord(short: short, name: "\(short) job", state: state, detail: "Checking the latest tick",
                  tempo: tempo, cwd: cwd, createdAt: now.addingTimeInterval(-8 * 86400),
                  updatedAt: now.addingTimeInterval(-updatedAgo),
                  transcriptPath: "/x/\(short).jsonl",
                  transcriptMtime: transcriptAge.map { now.addingTimeInterval(-$0) })
    }

    var baseJobs: [String: JobRecord] {
        [
            "84dd1631": job("84dd1631", cwd: "/Users/u/Projects/usopen-bot", transcriptAge: 26 * 60),
            "06b55469": job("06b55469", cwd: "/Users/u/Projects/dissertation", tempo: "active", transcriptAge: 30),
        ]
    }

    func classify(ps: String? = nil, lsof: String? = nil, roster r: DaemonRoster? = nil,
                  jobs: [String: JobRecord]? = nil, daemonPid: Int? = 15674) -> ClaudeProcessReport {
        ClaudeProcessClassifier.classify(
            table: ProcessTable.parse(psOutput: ps ?? basePS),
            files: OpenFileFacts.parse(lsofOutput: lsof ?? baseLsof),
            roster: r ?? roster, jobs: jobs ?? baseJobs, daemonPid: daemonPid, now: now)
    }

    func unit(_ r: ClaudeProcessReport, root: Int) -> ClassifiedWorker? { r.workers.first { $0.rootPid == root } }

    // MARK: - The live layout

    func testLiveLayout() {
        let r = classify()
        XCTAssertEqual(unit(r, root: 93964)?.cls, .attached)
        XCTAssertEqual(unit(r, root: 93964)?.short, "06b55469")

        let bg = unit(r, root: 12116)
        XCTAssertEqual(bg?.cls, .backgroundJob, "an unattended job with a fresh transcript is a job, not an orphan, even with its host reparented to launchd")
        XCTAssertEqual(bg?.short, "84dd1631")
        XCTAssertEqual(bg?.project, "usopen-bot", "the job's own cwd names the project, not the worker's current directory")
        XCTAssertEqual(bg?.workerPid, 12124)
        XCTAssertEqual(bg?.rssKB, 7024 + 194896 + 40000, "memory covers the whole subtree, MCP servers included")
        XCTAssertEqual(bg?.killList.map(\.pid), [12116, 12124, 12200])
        let eightDays: TimeInterval = 8 * 86400 + 7101   // 08-01:58:21
        XCTAssertEqual(bg?.age ?? 0, eightDays, accuracy: 0.5)

        XCTAssertEqual(unit(r, root: 18569)?.cls, .warmSpare, "the daemon's own spare is never flagged")
        XCTAssertEqual(unit(r, root: 73915)?.cls, .foreground)
        XCTAssertNil(unit(r, root: 73950), "a claude child of a claude (MCP server) is not a session")
        XCTAssertTrue(r.orphans.isEmpty)
        XCTAssertEqual(r.backgroundJobs.map(\.short), ["84dd1631"])
        XCTAssertNil(r.workers.first { $0.rootPid == 13178 }, "Claude.app is not the CLI")
    }

    func testTotalCountsClaudeCLIAndDescendantsOnly() {
        let r = classify()
        // daemon, 3 hosts, 3 workers, MCP node child, attach client,
        // foreground claude and its claude mcp child.
        XCTAssertEqual(r.processCount, 11)
        let parts: [Int] = [64976, 7024, 194896, 40000, 8112, 359664, 37120, 32896, 28800, 257456, 30000]
        XCTAssertEqual(r.totalRSSKB, parts.reduce(0, +))
    }

    // MARK: - Orphans

    func testBackgroundJobWithStaleTranscriptIsOrphan() {
        var jobs = baseJobs
        jobs["84dd1631"] = job("84dd1631", cwd: "/Users/u/Projects/usopen-bot", transcriptAge: 30 * 3600)
        let w = unit(classify(jobs: jobs), root: 12116)
        guard case .orphan(let reason)? = w?.cls else { return XCTFail("expected orphan, got \(String(describing: w?.cls))") }
        XCTAssertTrue(reason.contains("1d 6h"), reason)
    }

    func testAttachedSessionWithOldTranscriptStaysAttached() {
        var jobs = baseJobs
        jobs["06b55469"] = job("06b55469", cwd: "/Users/u/Projects/dissertation", transcriptAge: 5 * 86400)
        XCTAssertEqual(unit(classify(jobs: jobs), root: 93964)?.cls, .attached)
    }

    func testDaemonWorkerWithoutJobRecordIsOrphan() {
        var jobs = baseJobs
        jobs["84dd1631"] = nil
        XCTAssertEqual(unit(classify(jobs: jobs), root: 12116)?.cls, .orphan("daemon worker with no job record"))
    }

    func testSpareLeftByDeadDaemonIsOrphan() {
        let ps = basePS + "\n 50000     1   9000 2-00:00:00 ??       \(host("aaaa0000"))\n 50001 50000  90000 2-00:00:00 ttys040  \(worker("aaaa0000"))"
        let r = classify(ps: ps)
        XCTAssertEqual(unit(r, root: 50000)?.cls, .orphan("spare left by a previous daemon"))
        XCTAssertEqual(unit(r, root: 18569)?.cls, .warmSpare)
        XCTAssertEqual(r.orphans.count, 1)
    }

    func testUnknownDaemonPidDoesNotFlagSpareUnderAParent() {
        let r = classify(roster: DaemonRoster(supervisorPid: nil, workers: roster.workers), daemonPid: nil)
        XCTAssertEqual(unit(r, root: 18569)?.cls, .warmSpare)
    }

    func testShortResolvedFromRosterWhenLsofIsEmpty() {
        let r = classify(lsof: "")
        XCTAssertEqual(unit(r, root: 12116)?.short, "84dd1631")
        XCTAssertEqual(unit(r, root: 12116)?.cls, .backgroundJob)
        XCTAssertEqual(unit(r, root: 93964)?.cls, .attached)
    }

    func testForegroundWhoseTerminalIsGoneIsOrphan() {
        let ps = basePS + "\n 60000     1 120000 3-00:00:00 ??       claude --resume abc"
        XCTAssertEqual(unit(classify(ps: ps), root: 60000)?.cls, .orphan("terminal gone"))
    }

    func testPrintModeAndToolingAreNotSessions() {
        let ps = basePS + "\n 61000  2784  50000       00:05 ??       claude -p --model haiku summarize\n 61001 61000 1000 00:01 ?? claude agents"
        let r = classify(ps: ps)
        XCTAssertNil(unit(r, root: 61000))
        XCTAssertNil(unit(r, root: 61001))
    }

    // MARK: - Ended jobs are never orphans

    func testCrashedJobWithNoWorkerIsEndedNotOrphan() {
        // The usopen-bot worker is gone (terminated), its record says failed.
        let ps = basePS.split(separator: "\n").filter { !$0.contains("12116") && !$0.contains("12124") && !$0.contains(" 12200 ") }
            .joined(separator: "\n")
        var jobs = baseJobs
        jobs["84dd1631"] = job("84dd1631", cwd: "/Users/u/Projects/usopen-bot", state: "failed", transcriptAge: 600, updatedAgo: 600)
        jobs["aaaa1111"] = job("aaaa1111", cwd: "/Users/u/Projects/x", state: "stopped", transcriptAge: 600, updatedAgo: 600)
        jobs["bbbb2222"] = job("bbbb2222", cwd: "/Users/u/Projects/y", state: "crashed", transcriptAge: 3 * 86400, updatedAgo: 3 * 86400)
        let r = classify(ps: ps, jobs: jobs)
        XCTAssertTrue(r.orphans.isEmpty)
        XCTAssertTrue(r.backgroundJobs.isEmpty)
        XCTAssertEqual(r.recentlyEnded.map(\.short), ["84dd1631"], "failed recently: shown ended; stopped on purpose: hidden; crashed days ago: hidden")
    }

    // MARK: - Parsers

    func testEtime() {
        XCTAssertEqual(ProcessTable.parseEtime("03:19"), 199)
        XCTAssertEqual(ProcessTable.parseEtime("01:06:21"), 3981)
        XCTAssertEqual(ProcessTable.parseEtime("08-01:58:21"), 8 * 86400 + 7101)
        XCTAssertNil(ProcessTable.parseEtime("x"))
    }

    func testCommandKinds() {
        XCTAssertEqual(ClaudeProcKind.of(command: "claude attach 8cdd9a8d"), .attachClient("8cdd9a8d"))
        XCTAssertEqual(ClaudeProcKind.of(command: "/Users/u/.local/bin/claude attach 8CDD9A8D"), .attachClient("8cdd9a8d"))
        XCTAssertEqual(ClaudeProcKind.of(command: "/bin/zsh -c claude attach 8cdd9a8d"), .notClaude)
        XCTAssertEqual(ClaudeProcKind.of(command: "/Applications/Claude.app/Contents/MacOS/Claude"), .notClaude)
        XCTAssertEqual(ClaudeProcKind.of(command: worker("x")), .worker)
        XCTAssertEqual(ClaudeProcKind.of(command: host("x")), .ptyHost)
    }

    func testRosterParse() {
        let json = #"{"proto":1,"supervisorPid":15674,"workers":{"84dd1631":{"pid":12116,"replPid":12124,"cwd":"/p/usopen-bot","sessionId":"84dd"}}}"#
        let r = DaemonRoster.parse(Data(json.utf8))
        XCTAssertEqual(r.supervisorPid, 15674)
        XCTAssertEqual(r.workers["84dd1631"], RosterWorker(short: "84dd1631", pid: 12116, replPid: 12124, cwd: "/p/usopen-bot", sessionId: "84dd"))
    }

    // MARK: - Menu text

    func testMenuTextDump() {
        let text = ProcessMenuText.dump(classify(), now: now)
        XCTAssertTrue(text.hasPrefix("Background Jobs\n  usopen-bot  ·  8d 1h\n      idle · Checking the latest tick  ·  last write 26m ago"), text)
        XCTAssertFalse(text.contains("Orphans"))
        XCTAssertTrue(text.contains("Claude Code: 1.0 GB in 11 processes · 1 attached, 1 background, 1 warm spare"), text)
    }
}
