import XCTest

final class PanelToggleTests: XCTestCase {
    func testAPanelInFrontIsHidden() {
        XCTAssertEqual(PanelToggle.action(isVisible: true, isOnActiveSpace: true, appIsActive: true, isKeyWindow: true), .hide)
    }

    func testAPanelBuriedUnderAnotherAppIsBroughtForward() {
        // 2026-11-06: closing a Ghostty window brought Arc forward over the panel;
        // the panel was still visible on this desktop, so the old rule hid it.
        XCTAssertEqual(PanelToggle.action(isVisible: true, isOnActiveSpace: true, appIsActive: false, isKeyWindow: false), .show)
        XCTAssertEqual(PanelToggle.action(isVisible: true, isOnActiveSpace: true, appIsActive: true, isKeyWindow: false), .show)
    }

    func testAPanelOnAnotherDesktopOrClosedIsShown() {
        XCTAssertEqual(PanelToggle.action(isVisible: true, isOnActiveSpace: false, appIsActive: true, isKeyWindow: true), .show)
        XCTAssertEqual(PanelToggle.action(isVisible: false, isOnActiveSpace: false, appIsActive: false, isKeyWindow: false), .show)
    }
}
