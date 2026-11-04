import XCTest

/// The Projects tab's parent → children tree (`ProjectTree`) and the roll-ups
/// a parent row shows. Rule 6 of the nested-subprojects design: an invalid
/// `parent:` leaves the project top-level, so nothing can disappear.
final class VaultProjectTreeTests: XCTestCase {

    func project(_ name: String, parent: String? = nil, status: String = "active") -> VaultProject {
        VaultProject(folder: URL(fileURLWithPath: "/vault/\(name)"), name: name, status: status,
                     updated: nil, cwds: [], manuscript: nil, parent: parent)
    }

    /// "Root" or "Root > Child, Child", one string per top-level row.
    func shape(_ nodes: [ProjectTree.Node]) -> [String] {
        nodes.map { n in
            n.children.isEmpty ? n.project.name
                : "\(n.project.name) > \(n.children.map(\.name).joined(separator: ", "))"
        }
    }

    func day(_ n: Int) -> Date { Date(timeIntervalSince1970: Double(n) * 86_400) }

    // MARK: Frontmatter

    func testParentIsReadFromTasksFrontmatter() {
        let folder = URL(fileURLWithPath: "/vault/Raspberry Pi")
        let child = VaultProject.parse(folder: folder, tasksContent: """
        ---
        project: Raspberry Pi
        status: active
        updated: 2026-10-07
        parent: Personal
        cwds:
          - /Users/u/Projects/raspberry-pi
        ---

        # Raspberry Pi Tasks
        """)
        XCTAssertEqual(child.parent, "Personal")
        XCTAssertEqual(child.cwds, ["/Users/u/Projects/raspberry-pi"])

        let plain = VaultProject.parse(folder: folder, tasksContent: "---\nstatus: active\n---\n")
        XCTAssertNil(plain.parent)
        let empty = VaultProject.parse(folder: folder, tasksContent: "---\nparent:\nstatus: active\n---\n")
        XCTAssertNil(empty.parent)
    }

    // MARK: Tree (rule 6)

    func testValidChildRendersUnderItsParentNotAsARoot() {
        let nodes = ProjectTree.build([project("Personal"), project("Investing", parent: "Personal"),
                                       project("Cayda")])
        XCTAssertEqual(shape(nodes), ["Personal > Investing", "Cayda"])
    }

    func testUnknownParentLeavesTheProjectTopLevel() {
        let nodes = ProjectTree.build([project("Personal"), project("Investing", parent: "Personel")])
        XCTAssertEqual(shape(nodes), ["Personal", "Investing"])
    }

    func testParentThatHasAParentIsInvalid() {
        // Momir names Heat TV, which is itself a child: one level only, so
        // Momir is an ordinary top-level project and Heat TV stays a leaf.
        let nodes = ProjectTree.build([project("Games"), project("Heat TV", parent: "Games"),
                                       project("Momir", parent: "Heat TV")])
        XCTAssertEqual(shape(nodes), ["Games > Heat TV", "Momir"])
    }

    func testCycleAndSelfParentLeaveEveryProjectTopLevel() {
        let nodes = ProjectTree.build([project("A", parent: "B"), project("B", parent: "A"),
                                       project("C", parent: "C")])
        XCTAssertEqual(shape(nodes), ["A", "B", "C"])
    }

    func testTwoChildrenUnderOneParent() {
        let nodes = ProjectTree.build([project("CV", parent: "Career"), project("Career"),
                                       project("Job Search", parent: "Career")])
        XCTAssertEqual(shape(nodes), ["Career > CV, Job Search"])
    }

    // MARK: Roll-ups

    func testParentBadgeSumsOwnAndChildrenSessions() {
        let node = ProjectTree.build([project("Personal"), project("Investing", parent: "Personal"),
                                      project("Raspberry Pi", parent: "Personal")])[0]
        let live = [
            "Personal": LiveSessionCounts(running: 1, attention: 0, dimmed: 2),
            "Investing": LiveSessionCounts(running: 0, attention: 1, dimmed: 0),
            "Raspberry Pi": LiveSessionCounts(running: 2, attention: 0, dimmed: 1),
            "Cayda": LiveSessionCounts(running: 9, attention: 9, dimmed: 9),
        ]
        XCTAssertEqual(node.liveCounts(in: live), LiveSessionCounts(running: 3, attention: 1, dimmed: 3))
        XCTAssertEqual(node.folderNames, ["Personal", "Investing", "Raspberry Pi"])
    }

    func testParentRecencyIsMaxOverItselfAndChildren() {
        let node = ProjectTree.build([project("Personal"), project("Investing", parent: "Personal"),
                                      project("Raspberry Pi", parent: "Personal")])[0]
        let activity = ["Personal": day(3), "Investing": day(9), "Raspberry Pi": day(5)]
        let at: (VaultProject) -> Date = { activity[$0.name]! }
        XCTAssertEqual(node.recency(at), day(9))
        // Children are ordered among themselves by their own recency.
        XCTAssertEqual(node.childrenByRecency(at).map(\.name), ["Investing", "Raspberry Pi"])
        let reversed = ["Personal": day(3), "Investing": day(1), "Raspberry Pi": day(5)]
        XCTAssertEqual(node.childrenByRecency { reversed[$0.name]! }.map(\.name),
                       ["Raspberry Pi", "Investing"])
        XCTAssertEqual(node.recency { reversed[$0.name]! }, day(5))
    }

    func testOrderingUsesFamilyRecencyAndFloatsAWaitingChild() {
        let nodes = ProjectTree.build([project("Cayda"), project("Personal"),
                                       project("Investing", parent: "Personal"), project("Mumbai")])
        let activity = ["Cayda": day(8), "Personal": day(1), "Investing": day(9), "Mumbai": day(5)]
        let at: (VaultProject) -> Date = { activity[$0.name]! }
        // Personal's own activity is the oldest; its child makes it the newest.
        XCTAssertEqual(ProjectTree.ordered(nodes, live: [:], activity: at).map(\.project.name),
                       ["Personal", "Cayda", "Mumbai"])
        // A session waiting on the user in a CHILD floats the whole family.
        let stale = ["Cayda": day(8), "Personal": day(1), "Investing": day(2), "Mumbai": day(5)]
        let live = ["Investing": LiveSessionCounts(running: 0, attention: 1, dimmed: 0)]
        XCTAssertEqual(ProjectTree.ordered(nodes, live: live) { stale[$0.name]! }.map(\.project.name),
                       ["Personal", "Cayda", "Mumbai"])
        XCTAssertEqual(ProjectTree.ordered(nodes, live: [:]) { stale[$0.name]! }.map(\.project.name),
                       ["Cayda", "Mumbai", "Personal"])
    }

    func testOrderingFloatsAnOverdueFamilyBelowAWaitingOne() {
        func due(_ name: String, _ d: Date, parent: String? = nil) -> VaultProject {
            VaultProject(folder: URL(fileURLWithPath: "/vault/\(name)"), name: name, status: "active",
                         updated: nil, cwds: [], manuscript: nil, parent: parent,
                         nextDue: ActiveTasks.NextDue(date: d, title: "t"))
        }
        let now = day(10) + 3600
        let nodes = ProjectTree.build([project("Cayda"), project("Personal"),
                                       due("Investing", day(9), parent: "Personal"),
                                       due("Mumbai", day(10)), project("Waiting")])
        let activity = ["Cayda": day(8), "Personal": day(1), "Investing": day(2),
                        "Mumbai": day(5), "Waiting": day(0)]
        let live = ["Waiting": LiveSessionCounts(running: 0, attention: 1, dimmed: 0)]
        // Waiting first; then Personal, whose child is a day late; Mumbai is
        // due today, so not late, and keeps its recency place.
        XCTAssertEqual(ProjectTree.ordered(nodes, live: live, activity: { activity[$0.name]! }, now: now)
                        .map(\.project.name),
                       ["Waiting", "Personal", "Cayda", "Mumbai"])
    }

    // MARK: Search

    func testSearchOnAChildShowsItUnderItsParent() {
        let nodes = ProjectTree.build([project("Personal"), project("Investing", parent: "Personal"),
                                       project("Raspberry Pi", parent: "Personal"), project("Cayda")])
        // The parent does not match "invest": it is kept as context, with only
        // the matching child beneath it.
        XCTAssertEqual(shape(ProjectTree.filter(nodes, query: "invest")), ["Personal > Investing"])
        // A parent that matches keeps all its children.
        XCTAssertEqual(shape(ProjectTree.filter(nodes, query: "personal")),
                       ["Personal > Investing, Raspberry Pi"])
        XCTAssertEqual(shape(ProjectTree.filter(nodes, query: "  ")),
                       ["Personal > Investing, Raspberry Pi", "Cayda"])
        XCTAssertEqual(shape(ProjectTree.filter(nodes, query: "zzz")), [])
    }

    // MARK: New-project parent picker

    func testParentCandidatesExcludeProjectsThatDeclareAParent() {
        let all = [project("Personal"), project("Investing", parent: "Personal"),
                   project("Orphan", parent: "Nowhere"), project("Cayda")]
        XCTAssertEqual(ProjectTree.parentCandidates(all), ["Cayda", "Personal"])
    }

    // MARK: Live vault (read-only)

    /// Scans the real vault with the app's own scan + tree and prints the
    /// families. Read-only. Runs only when `CLAUDEHUD_VAULT` is set, so the
    /// suite has no dependency on one machine's vault.
    func testPrintLiveVaultTree() throws {
        guard let path = ProcessInfo.processInfo.environment["CLAUDEHUD_VAULT"] else {
            throw XCTSkip("set CLAUDEHUD_VAULT to print the live vault's project tree")
        }
        let projects = VaultProject.scan(vaultPath: URL(fileURLWithPath: path))
        let nodes = ProjectTree.build(projects)
        print("LIVE-TREE projects=\(projects.count) roots=\(nodes.count)")
        for n in nodes where !n.children.isEmpty {
            print("LIVE-TREE \(n.project.name) > \(n.children.map(\.name).sorted().joined(separator: ", "))")
        }
        let declared = projects.filter { $0.parent != nil }
        let placed = Set(nodes.flatMap { $0.children.map(\.name) })
        for p in declared where !placed.contains(p.name) {
            print("LIVE-TREE INVALID parent: \(p.name) -> \(p.parent ?? "")")
        }
        XCTAssertEqual(nodes.reduce(0) { $0 + 1 + $1.children.count }, projects.count,
                       "every scanned project appears exactly once")
    }
}

/// The session lines' one dot and the leftover rule (`SessionLight`, Ben,
/// 2026-11-03): green running, red anything else, and a red session with no
/// terminal here that has not moved for an hour is dimmed, sorted last, and
/// does not light its header.
final class SessionLightTests: XCTestCase {
    let now = Date(timeIntervalSince1970: 1_800_000_000)

    func light(running: Bool = false, quietFor: TimeInterval, window: Bool = false) -> SessionLight {
        SessionLight.of(running: running, hasWindow: window, lastMoved: now.addingTimeInterval(-quietFor), now: now)
    }

    func testRunningIsGreenAndAnythingElseRed() {
        XCTAssertEqual(light(running: true, quietFor: 7200), .running)
        XCTAssertEqual(light(quietFor: 60), .attention)
    }

    func testARedSessionIsDimmedAfterAnHourOnlyWithNoTerminal() {
        XCTAssertEqual(light(quietFor: 3601), .dimmed)
        XCTAssertEqual(light(quietFor: 3599), .attention)
        XCTAssertEqual(light(quietFor: 7200, window: true), .attention)
    }

    func testTheHeaderIsRedOverGreenAndLeftoversLightNothing() {
        XCTAssertEqual(LiveSessionCounts(running: 1, attention: 1, dimmed: 0).light, .attention)
        XCTAssertEqual(LiveSessionCounts(running: 1, attention: 0, dimmed: 3).light, .running)
        XCTAssertNil(LiveSessionCounts(running: 0, attention: 0, dimmed: 2).light)
    }

    func testLeftoversSortLastAndKeepTheirOrder() {
        let items: [(String, SessionLight)] = [("old", .dimmed), ("run", .running), ("older", .dimmed), ("red", .attention)]
        XCTAssertEqual(SessionLight.leftoversLast(items, light: { $0.1 }).map { $0.0 }, ["run", "red", "old", "older"])
    }

    func testTheGatesEndAnswerReadsAsStoppedOrItsReason() {
        XCTAssertNil(IMacLauncher.endFailure(status: 0, stdout: Data(#"{"ok": true, "ended": "x", "copies": 1}"#.utf8)))
        XCTAssertEqual(IMacLauncher.endFailure(status: 0, stdout: Data(#"{"ok": false, "error": "no running session with that id"}"#.utf8)),
                       "no running session with that id")
        XCTAssertEqual(IMacLauncher.endFailure(status: 255, stdout: Data()), "the iMac did not answer")
    }
}
