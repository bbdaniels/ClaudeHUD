import XCTest

/// Due dates on `## Active` tasks: the Obsidian Tasks plugin's `📅 YYYY-MM-DD`
/// anywhere on a task's line or its nested detail, parsed once by
/// `ActiveTasks.parse` and rolled up to the project's soonest open task.
final class ActiveTasksDueDateTests: XCTestCase {

    /// Local-calendar midnight, as the parser produces.
    func date(_ y: Int, _ m: Int, _ d: Int) -> Date {
        Calendar.current.date(from: DateComponents(year: y, month: m, day: d))!
    }

    func tasks(_ active: String) -> [ActiveTask] {
        ActiveTasks.parse(from: "# Tasks\n\n## Active\n\n\(active)\n\n## Completed\n")
    }

    func testDueOnTitleLine() {
        let t = tasks("- **Send draft** 📅 2026-10-20: to coauthors")
        XCTAssertEqual(t.first?.dueDate, date(2026, 10, 20))
        let next = ActiveTasks.nextDue(in: t)
        XCTAssertEqual(next?.date, date(2026, 10, 20))
        XCTAssertEqual(next?.title, "Send draft")
    }

    func testDueOnNestedDetailLine() {
        let t = tasks("""
        ### Paper
        - [ ] **Referee reply**: draft the letter
          - deadline from the editor 📅 2026-11-02
        """)
        XCTAssertEqual(t.first?.subBullets.first?.dueDate, date(2026, 11, 2))
        XCTAssertEqual(ActiveTasks.nextDue(in: t)?.title, "Referee reply")
    }

    func testDueOnFlatTaskNestedBulletCountsForTheTask() {
        let t = tasks("""
        - **Grant report**: annual
          - finance annex 📅 2026-12-01
        """)
        XCTAssertEqual(t.first?.dueDate, date(2026, 12, 1))
    }

    func testCheckedTaskIgnored() {
        let t = tasks("""
        ### Admin
        - [x] **Renew passport** 📅 2026-10-01
        - [ ] **Book flights** 📅 2026-10-30
        """)
        XCTAssertEqual(ActiveTasks.nextDue(in: t)?.title, "Book flights")
        XCTAssertNil(ActiveTasks.nextDue(in: tasks("- [x] **Done thing** 📅 2026-10-01")))
    }

    func testEarliestWins() {
        let t = tasks("""
        - **Later** 📅 2026-12-15
        - **Sooner** 📅 2026-10-18
        ### Group
        - [ ] **Middle** 📅 2026-11-01
        """)
        let next = ActiveTasks.nextDue(in: t)
        XCTAssertEqual(next?.date, date(2026, 10, 18))
        XCTAssertEqual(next?.title, "Sooner")
    }

    func testInvalidDateIgnored() {
        XCTAssertNil(ActiveTasks.dueDate(in: "**X** 📅 2026-13-45"))
        XCTAssertNil(ActiveTasks.dueDate(in: "**X** 📅 2026-02-30"))
        XCTAssertNil(ActiveTasks.dueDate(in: "**X** 📅 soon"))
        // A bad token does not hide a good one.
        XCTAssertEqual(ActiveTasks.dueDate(in: "📅 2026-02-30 then 📅 2026-03-02"), date(2026, 3, 2))
        XCTAssertNil(ActiveTasks.nextDue(in: tasks("- **X** 📅 2026-13-45")))
    }

    func testStrippingDue() {
        XCTAssertEqual(ActiveTasks.strippingDue("Send draft 📅 2026-10-20 to Jo"), "Send draft to Jo")
    }

    func testProjectScanCarriesNextDue() {
        let p = VaultProject.parse(folder: URL(fileURLWithPath: "/vault/P"), tasksContent: """
        ---
        status: active
        ---
        ## Active
        - **Ship it** 📅 2026-10-21
        """)
        XCTAssertEqual(p.nextDue, ActiveTasks.NextDue(date: date(2026, 10, 21), title: "Ship it"))
    }
}
