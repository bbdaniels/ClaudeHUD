import XCTest

/// The one frontmatter reader (`Frontmatter`) and the cwd → project resolver
/// (`ProjectResolver`) built on it.
final class ProjectResolverTests: XCTestCase {

    func fm(_ body: String) -> Frontmatter { Frontmatter("---\n\(body)\n---\n\n# Tasks\n") }

    // MARK: Frontmatter: list forms

    func testBlockListIndented() {
        XCTAssertEqual(fm("cwds:\n  - /a/b\n  - /c/d\nstatus: active").list("cwds"), ["/a/b", "/c/d"])
    }

    func testBlockListFlushLeft() {
        XCTAssertEqual(fm("cwds:\n- /a/b\n- /c/d\nstatus: active").list("cwds"), ["/a/b", "/c/d"])
    }

    func testInlineSingleValue() {
        XCTAssertEqual(fm("cwds: /a/b").list("cwds"), ["/a/b"])
    }

    func testInlineBracketList() {
        XCTAssertEqual(fm("cwds: [/a/b, '/c/d', \"/e f\"]").list("cwds"), ["/a/b", "/c/d", "/e f"])
    }

    func testEmptyListForms() {
        XCTAssertEqual(fm("cwds: []").list("cwds"), [])
        XCTAssertEqual(fm("cwds: ~").list("cwds"), [])
        XCTAssertEqual(fm("cwds:").list("cwds"), [])
        XCTAssertEqual(fm("status: active").list("cwds"), [])
    }

    func testListItemsAreUnquoted() {
        XCTAssertEqual(fm("cwds:\n  - '/a b'\n  - \"/c\"").list("cwds"), ["/a b", "/c"])
    }

    func testBlockListEndsAtTheNextTopLevelKey() {
        let f = fm("cwds:\n  - /a\naka:\n  - alias\nmigrated-from:\n  - /old")
        XCTAssertEqual(f.list("cwds"), ["/a"])
        XCTAssertEqual(f.list("aka"), ["alias"])
        XCTAssertEqual(f.list("migrated-from"), ["/old"])
    }

    // MARK: Frontmatter: scalars, keys, fences

    func testScalarsAreUnquotedAndEmptyIsAbsent() {
        let f = fm("status: 'active'\nupdated: \"2026-10-07\"\nparent: Personal\nmanuscript:\nnote: ~")
        XCTAssertEqual(f.scalar("status"), "active")
        XCTAssertEqual(f.scalar("updated"), "2026-10-07")
        XCTAssertEqual(f.scalar("parent"), "Personal")
        XCTAssertNil(f.scalar("manuscript"))
        XCTAssertNil(f.scalar("note"))
        XCTAssertNil(f.scalar("absent"))
    }

    func testScalarKeepsColonsInTheValue() {
        XCTAssertEqual(fm("manuscript: /a/b: c").scalar("manuscript"), "/a/b: c")
    }

    func testIndentedKeyIsNotATopLevelKey() {
        let f = fm("meta:\n  cwds: /nested\n  parent: Nested\nstatus: active")
        XCTAssertEqual(f.list("cwds"), [])
        XCTAssertNil(f.scalar("parent"))
        XCTAssertEqual(f.scalar("status"), "active")
    }

    func testSpaceBeforeTheColonIsAccepted() {
        XCTAssertEqual(fm("cwds :\n  - /a").list("cwds"), ["/a"])
    }

    func testCRLFIsNormalized() {
        let f = Frontmatter("---\r\nstatus: active\r\ncwds:\r\n  - /a/b\r\nparent: Personal\r\n---\r\n\r\n# T\r\n")
        XCTAssertEqual(f.scalar("status"), "active")
        XCTAssertEqual(f.list("cwds"), ["/a/b"])
        XCTAssertEqual(f.scalar("parent"), "Personal")
    }

    func testNoFrontmatterOrUnclosedFenceReadsNothing() {
        XCTAssertNil(Frontmatter("# Tasks\nstatus: active\n").scalar("status"))
        XCTAssertNil(Frontmatter("---\nstatus: active\n\n# never closed\n").scalar("status"))
        // Only the leading block counts; a later `key:` in the body is prose.
        XCTAssertNil(Frontmatter("---\nstatus: active\n---\nparent: Body\n").scalar("parent"))
    }

    // MARK: Model reads through the one reader

    func testProjectFieldsAcceptEveryListForm() {
        let folder = URL(fileURLWithPath: "/vault/P")
        let inline = VaultProject.parse(folder: folder, tasksContent: "---\ncwds: /Users/u/p\n---\n")
        XCTAssertEqual(inline.primaryCwd, "/Users/u/p")
        let bracket = VaultProject.parse(folder: folder,
                                         tasksContent: "---\ncwds: [/Users/u/glob/*, /Users/u/q]\n---\n")
        XCTAssertEqual(bracket.cwds, ["/Users/u/glob/*", "/Users/u/q"])
        XCTAssertEqual(bracket.primaryCwd, "/Users/u/q")
    }

    // MARK: Resolver

    func testClaimsCountMigratedFromAndDropRelativePaths() {
        let claims = ProjectResolver.claims(tasksContent:
            "---\ncwds:\n  - /new/home\n  - relative/path\nmigrated-from: /old/home\nreads:\n  - /shared\n---\n")
        XCTAssertEqual(claims, ["/new/home", "/old/home"])
    }

    func testLongestMatchWins() {
        let claims = ["Personal": ["/u/Projects/personal"],
                      "Investing": ["/u/Projects/personal/investing"],
                      "Aardvark": ["/u/Projects"]]
        XCTAssertEqual(ProjectResolver.resolve(cwd: "/u/Projects/personal/investing/x", claims: claims), "Investing")
        XCTAssertEqual(ProjectResolver.resolve(cwd: "/u/Projects/personal/runner", claims: claims), "Personal")
        XCTAssertEqual(ProjectResolver.resolve(cwd: "/u/Projects/other", claims: claims), "Aardvark")
    }

    func testEqualLengthTieGoesToTheAlphabeticallyFirstFolder() {
        let claims = ["Zeta": ["/u/shared"], "Alpha": ["/u/shared"], "Mid": ["/u/shared"]]
        XCTAssertEqual(ProjectResolver.resolve(cwd: "/u/shared/x", claims: claims), "Alpha")
    }

    func testUnclaimedDirectoryResolvesToNothing() {
        let claims = ["Personal": ["/u/Projects/personal"]]
        XCTAssertNil(ProjectResolver.resolve(cwd: "/u/nowhere", claims: claims))
        // A sibling that merely shares the prefix string is not under the claim.
        XCTAssertNil(ProjectResolver.resolve(cwd: "/u/Projects/personal-2", claims: claims))
    }

    func testMatchForms() {
        XCTAssertTrue(ProjectResolver.matches(cwd: "/u/a", pattern: "/u/a"))          // exact
        XCTAssertTrue(ProjectResolver.matches(cwd: "/u/a/b/c", pattern: "/u/a"))      // under
        XCTAssertTrue(ProjectResolver.matches(cwd: "/u/a", pattern: "/u/a/"))         // trailing slash
        XCTAssertTrue(ProjectResolver.matches(cwd: "/u/a", pattern: "/u/a/*"))        // glob's own root
        XCTAssertTrue(ProjectResolver.matches(cwd: "/u/a/b", pattern: "/u/a/*"))      // glob
        XCTAssertTrue(ProjectResolver.matches(cwd: "/u/work-2022", pattern: "/u/work-*"))
        XCTAssertFalse(ProjectResolver.matches(cwd: "/u/ab", pattern: "/u/a"))
        XCTAssertFalse(ProjectResolver.matches(cwd: "/u", pattern: "/u/a"))
    }

    func testResolveFolderReadsTasksFrontmatterFromDisk() throws {
        let vault = FileManager.default.temporaryDirectory
            .appending(path: "claudehud-resolver-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: vault) }
        func write(_ folder: String, _ frontmatter: String) throws {
            let dir = vault.appending(path: folder)
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            try "---\n\(frontmatter)\n---\n".write(to: dir.appending(path: "Tasks.md"),
                                                   atomically: true, encoding: .utf8)
        }
        try write("Block", "cwds:\n  - /u/block")
        try write("Inline", "cwds: /u/inline")
        try write("Bracket", "cwds: [/u/bracket-a, /u/bracket-b]")
        try write("Moved", "cwds: []\nmigrated-from:\n  - /u/old-home")
        try write(".hidden", "cwds: /u/hidden")
        try FileManager.default.createDirectory(at: vault.appending(path: "NoTasks"),
                                                withIntermediateDirectories: true)
        func resolve(_ cwd: String) -> String? {
            ProjectResolver.resolveFolder(cwd: cwd, vaultPath: vault.path)
        }
        XCTAssertEqual(resolve("/u/block/sub"), "Block")
        XCTAssertEqual(resolve("/u/inline"), "Inline")
        XCTAssertEqual(resolve("/u/bracket-b/x"), "Bracket")
        XCTAssertEqual(resolve("/u/old-home"), "Moved")
        XCTAssertNil(resolve("/u/hidden"))
        XCTAssertNil(resolve("/u/nowhere"))
    }
}
