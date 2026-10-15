import XCTest

/// `VaultAccess.decide`: the saved path wins, and a bad bookmark never blocks
/// a vault whose folder exists (the 2026-10-15 vault move left a bookmark
/// pointing at ~/Documents/Obsidian and the Projects tab showed nothing).
final class VaultAccessTests: XCTestCase {
    let saved = "/Users/me/Projects/obsidian"

    func testMatchingFreshBookmarkUsesScope() {
        let d = VaultAccess.decide(savedPath: saved, pathExists: true,
                                   bookmark: .resolved(path: saved + "/", isStale: false))
        XCTAssertEqual(d, .init(path: saved, useBookmarkScope: true, refreshBookmark: false))
    }

    func testBookmarkElsewhereLosesToPath() {
        let d = VaultAccess.decide(savedPath: saved, pathExists: true,
                                   bookmark: .resolved(path: "/Users/me/Documents/Obsidian", isStale: false))
        XCTAssertEqual(d, .init(path: saved, useBookmarkScope: false, refreshBookmark: true))
    }

    func testStaleBookmarkFallsBackToPath() {
        let d = VaultAccess.decide(savedPath: saved, pathExists: true,
                                   bookmark: .resolved(path: saved, isStale: true))
        XCTAssertEqual(d, .init(path: saved, useBookmarkScope: false, refreshBookmark: true))
    }

    func testUnresolvableBookmarkFallsBackToPath() {
        let d = VaultAccess.decide(savedPath: saved, pathExists: true, bookmark: .failed)
        XCTAssertEqual(d, .init(path: saved, useBookmarkScope: false, refreshBookmark: true))
    }

    func testNoBookmarkUsesPathAndCreatesOne() {
        let d = VaultAccess.decide(savedPath: saved, pathExists: true, bookmark: .none)
        XCTAssertEqual(d, .init(path: saved, useBookmarkScope: false, refreshBookmark: true))
    }

    func testMissingPathFailsEvenWithGoodBookmark() {
        let d = VaultAccess.decide(savedPath: saved, pathExists: false,
                                   bookmark: .resolved(path: saved, isStale: false))
        XCTAssertEqual(d, .missing)
    }
}
