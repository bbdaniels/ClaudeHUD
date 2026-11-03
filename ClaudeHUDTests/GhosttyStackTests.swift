import XCTest

final class GhosttyStackTests: XCTestCase {
    private let screen = CGRect(x: 0, y: 25, width: 1280, height: 807)

    func testAFullScreenWindowBuriedUnderTheFrontOneIsHidden() {
        let covered = GhosttyStack.coveredPids(front: [screen], others: [7: [screen], 9: [screen.insetBy(dx: 40, dy: 40)]])
        XCTAssertEqual(covered, [7, 9])
    }

    func testAWindowBesideOrPartlyOutsideTheFrontOneStaysVisible() {
        let left = CGRect(x: 0, y: 25, width: 640, height: 807)
        let right = CGRect(x: 640, y: 25, width: 640, height: 807)
        let straddling = CGRect(x: 500, y: 100, width: 400, height: 400)
        XCTAssertEqual(GhosttyStack.coveredPids(front: [left], others: [7: [right], 9: [straddling]]), [])
    }

    func testEveryWindowOfAnInstanceMustBeCovered() {
        let small = CGRect(x: 100, y: 100, width: 300, height: 300)
        let outside = CGRect(x: 1300, y: 100, width: 300, height: 300) // on a second display
        XCTAssertEqual(GhosttyStack.coveredPids(front: [screen], others: [7: [small, outside]]), [])
    }

    func testAFramesNudgedWithinTheToleranceStillCount() {
        let nudged = screen.offsetBy(dx: GhosttyStack.tolerance - 1, dy: 0)
        XCTAssertEqual(GhosttyStack.coveredPids(front: [screen], others: [7: [nudged]]), [7])
        let moved = screen.offsetBy(dx: GhosttyStack.tolerance + 20, dy: 0)
        XCTAssertEqual(GhosttyStack.coveredPids(front: [screen], others: [7: [moved]]), [])
    }

    func testNothingIsHiddenWithoutAFrontWindowOrForAnInstanceWithNoWindows() {
        XCTAssertEqual(GhosttyStack.coveredPids(front: [], others: [7: [screen]]), [])
        XCTAssertEqual(GhosttyStack.coveredPids(front: [screen], others: [7: []]), [])
    }
}
