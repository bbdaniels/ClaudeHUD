import XCTest

final class AttachFocusTests: XCTestCase {
    func testAConfirmedAttachIsFocusedOnItsTerminal() {
        let fresh: [String: (ghosttyPid: Int32?, tty: String?)] = ["imac-tmux:rc-projects-1106-0057": (89833, "ttys021")]
        XCTAssertEqual(AttachFocus.target(key: "imac-tmux:rc-projects-1106-0057", fresh: fresh),
                       .terminal(pid: 89833, tty: "ttys021"))
    }

    func testAWindowClosedSinceTheLastScanOpensANewAttach() {
        // 2026-11-06: the last scan still had pid 62864, closed seconds before
        // the click; the fresh scan has no attach, so nothing old is raised.
        XCTAssertEqual(AttachFocus.target(key: "imac-tmux:rc-projects-1106-0057", fresh: [:]), .openNew)
    }

    func testAnAttachOutsideGhosttyOrASessionWithoutAKeyOpensANewAttach() {
        let fresh: [String: (ghosttyPid: Int32?, tty: String?)] = ["abc123": (nil, "ttys004")]
        XCTAssertEqual(AttachFocus.target(key: "abc123", fresh: fresh), .openNew)
        XCTAssertEqual(AttachFocus.target(key: nil, fresh: fresh), .openNew)
    }
}
