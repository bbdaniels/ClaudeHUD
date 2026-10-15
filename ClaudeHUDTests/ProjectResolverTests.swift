import XCTest

/// The one frontmatter reader (`Frontmatter`) and the cwd → project resolver
/// (`ProjectResolver`) built on it. The rule's shared cases, which the
/// personal repo's roster.py runs too, are the golden-file tests at the end.
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

    func testClaimsAreCwdsAndRepoOnly() {
        // schema.md §"The one resolver": only `cwds:` (and, as the fallback,
        // `repo:`) attribute; `migrated-from:` and `reads:` never do.
        let claims = ProjectResolver.claims(tasksContent:
            "---\ncwds:\n  - /new/home\n  - relative/path\nmigrated-from: /old/home\nreads:\n  - /shared\n"
            + "repo: [git@github.com:O/N.git]\n---\n")
        XCTAssertEqual(claims, ProjectResolver.Claims(cwds: ["/new/home"], repos: ["github.com/o/n"]))
    }

    func testLongestMatchWins() {
        let claims = ["Personal": ["/u/Projects/personal"],
                      "Investing": ["/u/Projects/personal/investing"],
                      "Aardvark": ["/u/Projects"]]
        XCTAssertEqual(ProjectResolver.resolve(cwd: "/u/Projects/personal/investing/x", claims: claims), "Investing")
        XCTAssertEqual(ProjectResolver.resolve(cwd: "/u/Projects/personal/runner", claims: claims), "Personal")
        XCTAssertEqual(ProjectResolver.resolve(cwd: "/u/Projects/other", claims: claims), "Aardvark")
    }

    func testEqualLengthTieIsUnclaimed() {
        // schema.md §"The one resolver": an ambiguous tie goes to the inbox.
        let claims = ["Zeta": ["/u/shared"], "Alpha": ["/u/shared"], "Mid": ["/u/shared"]]
        XCTAssertNil(ProjectResolver.resolve(cwd: "/u/shared/x", claims: claims))
    }

    func testRepoKeyIsAskedForOnlyWhenNoCwdsClaimMatches() {
        let claims = ["P": ProjectResolver.Claims(cwds: ["/u/p"], repos: ["github.com/o/p"])]
        var asked: [String] = []
        let key: (String) -> String? = { asked.append($0); return "github.com/o/p" }
        XCTAssertEqual(ProjectResolver.resolve(cwd: "/u/p/x", claims: claims, repoKey: key), "P")
        XCTAssertEqual(asked, [])
        XCTAssertEqual(ProjectResolver.resolve(cwd: "/pi/clone", claims: claims, repoKey: key), "P")
        XCTAssertEqual(asked, ["/pi/clone"])
        // No project has a repo: claim: git is never run.
        asked = []
        XCTAssertNil(ProjectResolver.resolve(cwd: "/pi/clone",
                                             claims: ["Q": ProjectResolver.Claims(cwds: ["/u/q"])], repoKey: key))
        XCTAssertEqual(asked, [])
    }

    func testRepoLocatorReadsALiveCheckoutAndCaches() throws {
        let root = FileManager.default.temporaryDirectory
            .appending(path: "claudehud-repo-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let sub = root.appending(path: "investing/lib")
        try FileManager.default.createDirectory(at: sub, withIntermediateDirectories: true)
        XCTAssertNotNil(RepoLocator.runGit(root.path, ["init", "-q"]))
        XCTAssertNotNil(RepoLocator.runGit(root.path, ["remote", "add", "origin",
                                                       "git@GitHub.com:BBDaniels/Personal.git"]))
        var calls = 0
        let locator = RepoLocator(git: { cwd, args in calls += 1; return RepoLocator.runGit(cwd, args) })
        XCTAssertEqual(locator.key(forCwd: sub.path), "github.com/bbdaniels/personal/investing/lib")
        let first = calls
        XCTAssertEqual(locator.key(forCwd: sub.path), "github.com/bbdaniels/personal/investing/lib")
        XCTAssertEqual(calls, first, "a second lookup is served from the cache")
        XCTAssertNil(locator.key(forCwd: root.appending(path: "missing").path))
        XCTAssertNil(locator.key(forCwd: FileManager.default.temporaryDirectory.path))
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
        XCTAssertNil(resolve("/u/old-home"))   // migrated-from: is not a claim
        XCTAssertNil(resolve("/u/hidden"))
        XCTAssertNil(resolve("/u/nowhere"))
    }

    // MARK: The golden file shared with the personal repo

    /// `personal/lib/fixtures/resolver_cases.json`, read from the personal
    /// checkout beside this one (or `$RESOLVER_CASES`). Missing is a failure,
    /// never a skip: a copied snapshot could drift from the Python side.
    static var casesURL: URL {
        if let override = ProcessInfo.processInfo.environment["RESOLVER_CASES"], !override.isEmpty {
            return URL(fileURLWithPath: override)
        }
        return URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()      // ClaudeHUDTests
            .deletingLastPathComponent()      // ClaudeHUD checkout
            .deletingLastPathComponent()      // Projects
            .appending(path: "personal/lib/fixtures/resolver_cases.json")
    }

    struct Golden: Decodable {
        struct Normalize: Decodable { let remote: String; let expected: String? }
        struct Case: Decodable {
            let name: String, vault: String, cwd: String
            let remote: String?, subpath: String, expected: String?
        }
        let normalize: [Normalize]
        let vaults: [String: [String: String]]
        let cases: [Case]
    }

    func golden() throws -> Golden {
        let url = Self.casesURL
        guard FileManager.default.fileExists(atPath: url.path) else {
            XCTFail("golden resolver cases missing at \(url.path): check out bbdaniels/personal beside ClaudeHUD")
            throw CocoaError(.fileNoSuchFile)
        }
        return try JSONDecoder().decode(Golden.self, from: Data(contentsOf: url))
    }

    func testGoldenNormalizeCases() throws {
        let g = try golden()
        XCTAssertFalse(g.normalize.isEmpty)
        for c in g.normalize {
            XCTAssertEqual(ProjectResolver.normalizeRemote(c.remote), c.expected, "normalize \(c.remote.debugDescription)")
        }
    }

    func testGoldenResolverCases() throws {
        let g = try golden()
        XCTAssertFalse(g.cases.isEmpty)
        let claims = g.vaults.mapValues { vault in
            vault.mapValues { ProjectResolver.claims(tasksContent: "---\n\($0)\n---\n\n# Tasks\n") }
        }
        for c in g.cases {
            guard let vault = claims[c.vault] else { XCTFail("\(c.name): no vault \(c.vault)"); continue }
            let key = ProjectResolver.repoKey(remote: c.remote, subpath: c.subpath)
            XCTAssertEqual(ProjectResolver.resolve(cwd: c.cwd, claims: vault, repoKey: { _ in key }),
                           c.expected, c.name)
        }
    }

    /// The same cases through `resolveFolder`, the disk reader the app uses.
    func testGoldenResolverCasesFromDisk() throws {
        let g = try golden()
        let root = FileManager.default.temporaryDirectory
            .appending(path: "claudehud-golden-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        for (name, vault) in g.vaults {
            for (folder, body) in vault {
                let dir = root.appending(path: "\(name)/\(folder)")
                try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
                try "---\n\(body)\n---\n\n# Tasks\n".write(to: dir.appending(path: "Tasks.md"),
                                                          atomically: true, encoding: .utf8)
            }
        }
        for c in g.cases {
            let key = ProjectResolver.repoKey(remote: c.remote, subpath: c.subpath)
            XCTAssertEqual(ProjectResolver.resolveFolder(cwd: c.cwd, vaultPath: root.appending(path: c.vault).path,
                                                         repoKey: { _ in key }),
                           c.expected, c.name)
        }
    }
}
