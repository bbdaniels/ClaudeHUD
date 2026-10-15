import Foundation

// The Projects tab's model: one `VaultProject` per vault folder with a
// `Tasks.md`, the one frontmatter reader, the cwd → project resolver, and the
// parent → children tree. Foundation-only
// and free of app state so the unit-test bundle compiles this file directly
// (see project.yml → ClaudeHUDTests).

// MARK: - Project

/// A vault project: a top-level vault folder with a `Tasks.md`, described by
/// that file's frontmatter. `VaultProjectService.Project` is this type.
struct VaultProject: Identifiable, Hashable {
    var id: URL { folder }
    let folder: URL
    let name: String                  // folder basename
    let status: String                // raw frontmatter value (active, wrapping-up, …)
    let updated: Date?                // parsed from frontmatter `updated:`
    let cwds: [String]                // frontmatter `cwds:`; first absolute non-glob is the launch dir
    let manuscript: String?           // frontmatter `manuscript:` — declared paper dir
    /// Frontmatter `parent:` exactly as declared (nil when absent or empty).
    /// Declared, not validated: only `ProjectTree.build` decides whether it
    /// makes this project a child. Nothing else may interpret it.
    let parent: String?
    /// Soonest-due open task in `## Active`, read during the scan.
    var nextDue: ActiveTasks.NextDue? = nil

    /// First absolute non-glob `cwds:` entry (for "New session here").
    var primaryCwd: String? {
        cwds.first { $0.hasPrefix("/") && !$0.contains("*") }
    }

    /// Declared `manuscript:` directory when absolute — what the
    /// Manuscriptor button hands over. Declared or absent; never guessed
    /// (Manuscriptor's root rule resolves upward only, so a project root
    /// would not reach a paper nested in a subdirectory).
    var manuscriptDir: String? {
        guard let manuscript, manuscript.hasPrefix("/") else { return nil }
        return manuscript
    }

    var isActive: Bool { status == "active" || status == "wrapping-up" }

    /// Its soonest open task is due before today.
    func isOverdue(now: Date = Date()) -> Bool {
        nextDue.map { ActiveTasks.isOverdue($0.date, now: now) } ?? false
    }
}

// MARK: - Scan + parse

extension VaultProject {

    /// The full filesystem scan: one `parse` per non-hidden folder, sorted.
    /// Pure — run it off the main actor.
    static func scan(vaultPath vault: URL) -> [VaultProject] {
        let folders = (try? FileManager.default.contentsOfDirectory(
            at: vault, includingPropertiesForKeys: [.isDirectoryKey]
        )) ?? []
        var out: [VaultProject] = []
        for folder in folders {
            guard let isDir = try? folder.resourceValues(forKeys: [.isDirectoryKey]).isDirectory, isDir,
                  !folder.lastPathComponent.hasPrefix(".") else { continue }
            if let p = parse(folder: folder) { out.append(p) }
        }
        return sorted(out)
    }

    /// Sort: active+wrapping-up first (by updated desc), then everything else (by updated desc).
    static func sorted(_ projects: [VaultProject]) -> [VaultProject] {
        projects.sorted { lhs, rhs in
            if lhs.isActive != rhs.isActive { return lhs.isActive }   // active first
            let l = lhs.updated ?? .distantPast
            let r = rhs.updated ?? .distantPast
            return l > r
        }
    }

    /// One project from its folder; nil when the folder has no readable `Tasks.md`.
    static func parse(folder: URL) -> VaultProject? {
        guard let content = readTasks(inFolder: folder.path) else { return nil }
        return parse(folder: folder, tasksContent: content)
    }

    static func parse(folder: URL, tasksContent content: String) -> VaultProject {
        let fm = Frontmatter(content)
        let updatedRaw = fm.scalar("updated") ?? ""
        return VaultProject(
            folder: folder,
            name: folder.lastPathComponent,
            status: fm.scalar("status") ?? "unknown",
            updated: ISO8601DateFormatter.dateOnly.date(from: updatedRaw)
                ?? DateFormatter.iso8601Date.date(from: updatedRaw),
            cwds: fm.list("cwds"),
            manuscript: fm.scalar("manuscript"),
            parent: fm.scalar("parent"),
            nextDue: ActiveTasks.nextDue(in: ActiveTasks.parse(from: content))
        )
    }

    /// THE read of a project's `Tasks.md`, shared by the scan and the
    /// resolver. Invalid UTF-8 is replaced, not fatal, so one bad byte cannot
    /// hide a project.
    static func readTasks(inFolder folderPath: String) -> String? {
        guard let data = FileManager.default.contents(atPath: "\(folderPath)/Tasks.md") else { return nil }
        return String(decoding: data, as: UTF8.self)
    }
}

// MARK: - Frontmatter

/// THE reader of a vault note's leading YAML frontmatter. Everything the app
/// takes from `Tasks.md` frontmatter (`status`, `updated`, `manuscript`,
/// `parent`, `cwds`, `repo`) goes through it, so the Projects tab and
/// the cwd resolver cannot disagree about what a file says.
///
/// Deliberately not a YAML parser. It accepts exactly:
/// - a block opened by `---` on the first line and closed by a `---` line
///   (CRLF line endings are normalized first);
/// - top-level keys only: `key:` starting in column 0 (an indented `key:` is
///   nested YAML and is ignored), optional spaces before the colon; a repeated
///   key's later line wins;
/// - a scalar: `key: value`, surrounding quotes stripped; empty and `~` are
///   absent;
/// - a list, in any of three forms: a block list of `- item` lines (indented
///   or flush-left) under `key:`; an inline bracket list `key: [a, b]`; or a
///   single inline value `key: a`. Items have surrounding quotes stripped;
///   `[]` and `~` are empty. A block list ends at the next top-level line.
struct Frontmatter {
    private var inline: [String: String] = [:]
    private var items: [String: [String]] = [:]

    init(_ content: String) {
        let text = content.replacingOccurrences(of: "\r\n", with: "\n")
        guard text.hasPrefix("---\n") else { return }
        let open = text.index(text.startIndex, offsetBy: 4)
        guard let close = text.range(of: "\n---\n", range: open..<text.endIndex) else { return }

        var active: String?
        for line in text[open..<close.lowerBound].components(separatedBy: "\n") {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            // A list item belongs to the key above it, indented or not.
            if let key = active, trimmed.hasPrefix("- ") {
                let item = Self.unquote(String(trimmed.dropFirst(2)))
                if !item.isEmpty { items[key, default: []].append(item) }
                continue
            }
            // Indented and blank lines never start or end anything.
            guard let first = line.first, !first.isWhitespace else { continue }
            active = nil
            guard first != "-", first != "#", let colon = line.firstIndex(of: ":") else { continue }
            let key = String(line[..<colon]).trimmingCharacters(in: .whitespaces)
            guard !key.isEmpty else { continue }
            active = key
            inline[key] = String(line[line.index(after: colon)...]).trimmingCharacters(in: .whitespaces)
            items[key] = nil
        }
    }

    /// `key: value` with surrounding quotes stripped; nil when the key is
    /// absent, empty, `~`, or holds a list.
    func scalar(_ key: String) -> String? {
        guard let raw = inline[key], !raw.isEmpty, raw != "~", !raw.hasPrefix("[") else { return nil }
        let value = Self.unquote(raw)
        return value.isEmpty ? nil : value
    }

    /// The key's list in whichever form it was written (see the type's doc);
    /// empty when the key is absent.
    func list(_ key: String) -> [String] {
        var out: [String] = []
        if let raw = inline[key], !raw.isEmpty, raw != "~" {
            if raw.hasPrefix("["), raw.hasSuffix("]") {
                out = raw.dropFirst().dropLast().components(separatedBy: ",")
                    .map(Self.unquote).filter { !$0.isEmpty }
            } else {
                out = [Self.unquote(raw)]
            }
        }
        return out + (items[key] ?? [])
    }

    private static func unquote(_ s: String) -> String {
        let t = s.trimmingCharacters(in: .whitespaces)
        if t.count >= 2,
           (t.hasPrefix("'") && t.hasSuffix("'")) || (t.hasPrefix("\"") && t.hasSuffix("\"")) {
            return String(t.dropFirst().dropLast())
        }
        return t
    }
}

// MARK: - Resolver (cwd → project)

/// The canonical session → vault project resolver: the Swift side of the wiki
/// contract (`schema.md` §"The one resolver"). Never fuzzy-matched, never
/// guessed. The rule, with the cases BOTH implementations run (this one and
/// the daily review's `vault.daily_review.roster` in the personal repo), is in
/// `personal/lib/fixtures/resolver_cases.json`:
///
/// 1. A `cwds:` claim (absolute path or glob) matching the cwd wins, longest
///    claim first.
/// 2. Only when NO `cwds:` claim matches, `repo:` is consulted: the session's
///    key is its checkout's normalized `origin` remote plus its path inside
///    the checkout, and the longest `repo:` claim equal to the key or a
///    `/`-bounded prefix of it wins.
/// 3. A tie between two projects at the winning length is unclaimed, and a
///    `cwds:` tie never falls through to `repo:`. `migrated-from:`, `reads:`,
///    `aka:` and names never attribute.
enum ProjectResolver {

    /// One project's attribution claims, read from its `Tasks.md`.
    struct Claims: Equatable {
        var cwds: [String] = []     // absolute paths and globs
        var repos: [String] = []    // normalized `repo:` values
    }

    /// Resolve a session in `cwd` against the live vault. Returns the winning
    /// folder NAME, or nil for an unclaimed directory. Reads the disk and, when
    /// some project has a `repo:` claim and no `cwds:` claim matches, runs git
    /// in `cwd` (cached by `RepoLocator`): call it off the main thread.
    static func resolveFolder(cwd: String, vaultPath: String,
                              repoKey: (String) -> String? = { RepoLocator.shared.key(forCwd: $0) }) -> String? {
        let fm = FileManager.default
        guard let folders = try? fm.contentsOfDirectory(atPath: vaultPath) else { return nil }
        var claims: [String: Claims] = [:]
        for folder in folders where !folder.hasPrefix(".") {
            let folderPath = "\(vaultPath)/\(folder)"
            var isDir: ObjCBool = false
            guard fm.fileExists(atPath: folderPath, isDirectory: &isDir), isDir.boolValue,
                  let content = VaultProject.readTasks(inFolder: folderPath) else { continue }
            claims[folder] = Self.claims(tasksContent: content)
        }
        return resolve(cwd: cwd, claims: claims, repoKey: repoKey)
    }

    /// A project's claims: its absolute `cwds:` entries and its normalized
    /// `repo:` values. Nothing else in the frontmatter attributes.
    static func claims(tasksContent: String) -> Claims {
        let fm = Frontmatter(tasksContent)
        return Claims(cwds: fm.list("cwds").filter { $0.hasPrefix("/") },
                      repos: fm.list("repo").compactMap(normalizeRemote))
    }

    /// The whole rule over folder → claims. `repoKey` is asked for the
    /// session's key only when it is needed (no `cwds:` match and at least one
    /// `repo:` claim in the vault).
    static func resolve(cwd: String, claims: [String: Claims],
                        repoKey: (String) -> String?) -> String? {
        switch winner(claims.flatMap { folder, c in
            c.cwds.filter { matches(cwd: cwd, pattern: $0) }.map { (folder, $0) } }) {
        case .owner(let folder): return folder
        case .tie: return nil
        case .none: break
        }
        guard claims.values.contains(where: { !$0.repos.isEmpty }),
              let key = repoKey(cwd) else { return nil }
        return resolve(repoKey: key, claims: claims)
    }

    /// `cwds:` alone, over folder → claimed paths: the longest matching claim
    /// wins; no match or a tie → nil.
    static func resolve(cwd: String, claims: [String: [String]]) -> String? {
        resolve(cwd: cwd, claims: claims.mapValues { Claims(cwds: $0) }, repoKey: { _ in nil })
    }

    /// `repo:` alone: the longest claim equal to `key` or a `/`-bounded prefix
    /// of it; no match or a tie → nil.
    static func resolve(repoKey key: String, claims: [String: Claims]) -> String? {
        guard !key.isEmpty else { return nil }
        if case .owner(let folder) = winner(claims.flatMap { folder, c in
            c.repos.filter { key == $0 || key.hasPrefix($0 + "/") }.map { (folder, $0) } }) {
            return folder
        }
        return nil
    }

    private enum Outcome { case none, tie, owner(String) }

    /// The folder holding the longest matching claim; `.tie` when two folders
    /// hold claims of that length. Length in code points, as Python's `len`.
    private static func winner(_ matching: [(String, String)]) -> Outcome {
        guard let best = matching.map({ $0.1.unicodeScalars.count }).max() else { return .none }
        let owners = Set(matching.filter { $0.1.unicodeScalars.count == best }.map(\.0))
        return owners.count == 1 ? .owner(owners.first!) : .tie
    }

    /// The four-way match predicate, equivalent to the hook's:
    ///   cwd == pat
    ///   || fnmatch(cwd, pat)
    ///   || cwd == pat.rstrip("/*")
    ///   || cwd.startswith(pat.rstrip("*").rstrip("/") + "/")
    static func matches(cwd: String, pattern pat: String) -> Bool {
        if cwd.isEmpty { return false }
        if cwd == pat { return true }
        // POSIX fnmatch(3) with the semantics of Python's `fnmatch.fnmatch`:
        // `*`/`?`/`[…]`, `*` spans `/` (no FNM_PATHNAME), backslash literal.
        if fnmatch(pat, cwd, FNM_NOESCAPE) == 0 { return true }
        if cwd == rstrip(pat, of: "/*") { return true }
        if cwd.hasPrefix(rstrip(rstrip(pat, of: "*"), of: "/") + "/") { return true }
        return false
    }

    /// A git remote URL, or a `repo:` value, in its one normal form:
    /// `host/owner/name[/subpath]`, lower case, without scheme, user, port,
    /// `.git` or trailing slash; nil when it is not a remote. Specified by the
    /// "normalize" cases of the golden file; the Python twin is
    /// `roster.normalize_remote`.
    static func normalizeRemote(_ url: String) -> String? {
        var s = url.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !s.isEmpty, !s.hasPrefix("#"),
              s.rangeOfCharacter(from: .whitespacesAndNewlines) == nil else { return nil }
        var hadScheme = false
        if let r = s.range(of: "^[a-z][a-z0-9+.-]*://", options: .regularExpression) {
            s.removeSubrange(r)
            hadScheme = true
        }
        if let r = s.range(of: "^[^@/]*@", options: .regularExpression) { s.removeSubrange(r) }
        let slash = s.firstIndex(of: "/") ?? s.endIndex
        var host = String(s[..<slash])
        let rest = String(s[slash...])                  // "" or "/…"
        if let colon = host.firstIndex(of: ":") {
            let after = String(host[host.index(after: colon)...])
            host = String(host[..<colon])
            s = hadScheme ? host + rest : host + "/" + after + rest
        }
        s = rstrip(s, of: "/")
        if s.hasSuffix(".git") { s = rstrip(String(s.dropLast(4)), of: "/") }
        while s.contains("//") { s = s.replacingOccurrences(of: "//", with: "/") }
        return s.contains("/") && !s.hasPrefix("/") ? s : nil
    }

    /// A session's key for `repo:` matching: its checkout's normalized origin
    /// plus its path inside the checkout (`git rev-parse --show-prefix`).
    static func repoKey(remote: String?, subpath: String = "") -> String? {
        guard let remote, let base = normalizeRemote(remote) else { return nil }
        let sub = subpath.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmed = rstrip(String(sub.drop(while: { $0 == "/" })), of: "/").lowercased()
        return trimmed.isEmpty ? base : base + "/" + trimmed
    }

    /// Python `str.rstrip(chars)`: drop the trailing run of any char in `set`.
    fileprivate static func rstrip(_ s: String, of set: String) -> String {
        let drop = Set(set)
        var end = s.endIndex
        while end > s.startIndex {
            let prev = s.index(before: end)
            if drop.contains(s[prev]) { end = prev } else { break }
        }
        return String(s[s.startIndex..<end])
    }
}

/// A working directory's `repo:` key, derived from git
/// (`git remote get-url origin` and `git rev-parse --show-prefix`) and cached
/// per directory for the life of the process, misses included. Blocking: call
/// it off the main thread (the resolver's only caller,
/// `VaultProjectService.primeResolution`, runs in a detached task).
final class RepoLocator: @unchecked Sendable {
    static let shared = RepoLocator()

    private let lock = NSLock()
    private var cache: [String: String?] = [:]
    private let git: (_ cwd: String, _ args: [String]) -> String?

    init(git: @escaping (_ cwd: String, _ args: [String]) -> String? = RepoLocator.runGit) {
        self.git = git
    }

    func key(forCwd cwd: String) -> String? {
        lock.lock()
        if let hit = cache[cwd] { lock.unlock(); return hit }
        lock.unlock()
        let key = derive(cwd)
        lock.lock()
        cache[cwd] = .some(key)
        lock.unlock()
        return key
    }

    private func derive(_ cwd: String) -> String? {
        var isDir: ObjCBool = false
        guard cwd.hasPrefix("/"), FileManager.default.fileExists(atPath: cwd, isDirectory: &isDir),
              isDir.boolValue,
              let remote = git(cwd, ["remote", "get-url", "origin"]), !remote.isEmpty else { return nil }
        return ProjectResolver.repoKey(remote: remote, subpath: git(cwd, ["rev-parse", "--show-prefix"]) ?? "")
    }

    /// `git -C cwd args…`, trimmed stdout, or nil on failure.
    static func runGit(_ cwd: String, _ args: [String]) -> String? {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        p.arguments = ["-C", cwd] + args
        let out = Pipe()
        p.standardOutput = out
        p.standardError = FileHandle.nullDevice
        p.standardInput = FileHandle.nullDevice
        do { try p.run() } catch { return nil }
        let data = out.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        guard p.terminationStatus == 0 else { return nil }
        return String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

// MARK: - Live session counts

/// One project's live INTERACTIVE session counts, by state. See
/// `VaultTabView.folderLiveSessions` for how each field is derived.
struct LiveSessionCounts: Equatable {
    var working = 0
    /// Awaiting the user — the "needs me" signal. Roster-alive only.
    var blocked = 0
    var idle = 0
    var isEmpty: Bool { working == 0 && blocked == 0 && idle == 0 }

    static func + (a: LiveSessionCounts, b: LiveSessionCounts) -> LiveSessionCounts {
        LiveSessionCounts(working: a.working + b.working,
                          blocked: a.blocked + b.blocked,
                          idle: a.idle + b.idle)
    }
}

// MARK: - Tree

/// The Projects tab's parent → children tree, one level deep, read off the
/// children's `parent:` frontmatter (the parent declares nothing). Design:
/// Projects/obsidian/ClaudeHUD/plans/2026-10-07 - Nested Subprojects.md.
enum ProjectTree {

    /// A top-level row and the children shown beneath it (empty for an
    /// ordinary project). `children` keep the order they were given in.
    struct Node: Identifiable, Hashable {
        let project: VaultProject
        let children: [VaultProject]
        var id: URL { project.id }

        /// The parent's own folder name followed by its children's — every
        /// folder a parent row's badge sums over.
        var folderNames: [String] { [project.name] + children.map(\.name) }

        /// Own plus children's live sessions, summed: the parent row's badge.
        /// A child row reads `live[child.name]` directly.
        func liveCounts(in live: [String: LiveSessionCounts]) -> LiveSessionCounts {
            folderNames.reduce(LiveSessionCounts()) { $0 + (live[$1] ?? LiveSessionCounts()) }
        }

        /// Most recent activity among the parent and its children: what the
        /// parent row sorts and buckets by, so a busy child carries the whole
        /// family up with it.
        func recency(_ activity: (VaultProject) -> Date) -> Date {
            children.reduce(activity(project)) { max($0, activity($1)) }
        }

        /// The parent or any child has an overdue task.
        func hasOverdue(now: Date) -> Bool {
            project.isOverdue(now: now) || children.contains { $0.isOverdue(now: now) }
        }

        /// Children ordered among themselves by their OWN recency, newest first.
        func childrenByRecency(_ activity: (VaultProject) -> Date) -> [VaultProject] {
            children.sorted { activity($0) > activity($1) }
        }
    }

    /// Build the tree. THE only place that interprets `parent:`.
    ///
    /// A project is a child when its `parent:` is the exact folder name of
    /// another scanned project that declares no `parent:` of its own. Any
    /// other value (a name no project has, itself, or a project that names a
    /// parent, valid or not) is invalid and the project is an ordinary
    /// top-level row, so a typo can never make a project disappear. One level
    /// only; a cycle leaves both projects top-level. Roots and children keep
    /// the input order.
    static func build(_ projects: [VaultProject]) -> [Node] {
        let byName = Dictionary(projects.map { ($0.name, $0) }, uniquingKeysWith: { a, _ in a })
        func validParent(of p: VaultProject) -> String? {
            guard let name = p.parent,
                  let target = byName[name], target.parent == nil else { return nil }
            return name
        }
        var childrenOf: [String: [VaultProject]] = [:]
        var roots: [VaultProject] = []
        for p in projects {
            if let parent = validParent(of: p) {
                childrenOf[parent, default: []].append(p)
            } else {
                roots.append(p)
            }
        }
        return roots.map { Node(project: $0, children: childrenOf[$0.name] ?? []) }
    }

    /// Order top-level rows within one recency section: a family with a
    /// session waiting on the user (the parent's own or any child's) floats
    /// first, then a family with an overdue task, each compared as a boolean
    /// so two such families keep their recency order relative to each other;
    /// then most recent family activity first.
    static func ordered(_ nodes: [Node], live: [String: LiveSessionCounts],
                        activity: (VaultProject) -> Date, now: Date = Date()) -> [Node] {
        nodes.sorted { a, b in
            let wa = a.liveCounts(in: live).blocked > 0
            let wb = b.liveCounts(in: live).blocked > 0
            if wa != wb { return wa }
            let oa = a.hasOverdue(now: now)
            let ob = b.hasOverdue(now: now)
            if oa != ob { return oa }
            return a.recency(activity) > b.recency(activity)
        }
    }

    /// Search over a built tree (name or status text; an empty query returns
    /// everything). A parent that matches keeps all its children, since
    /// children are always shown. A parent that does not match is kept as
    /// context for the children that do, with only those children beneath it.
    static func filter(_ nodes: [Node], query: String) -> [Node] {
        let q = query.trimmingCharacters(in: .whitespaces).lowercased()
        guard !q.isEmpty else { return nodes }
        func matches(_ p: VaultProject) -> Bool {
            p.name.lowercased().contains(q) || p.status.lowercased().contains(q)
        }
        return nodes.compactMap { node in
            if matches(node.project) { return node }
            let hits = node.children.filter(matches)
            return hits.isEmpty ? nil : Node(project: node.project, children: hits)
        }
    }

    /// Projects the new-project sheet may offer as a parent: those declaring
    /// no `parent:` themselves (a child cannot also be a parent), by name.
    static func parentCandidates(_ projects: [VaultProject]) -> [String] {
        projects.filter { $0.parent == nil }.map(\.name)
            .sorted { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending }
    }
}

// MARK: - Date helpers

private extension ISO8601DateFormatter {
    static let dateOnly: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withFullDate]
        return f
    }()
}

private extension DateFormatter {
    static let iso8601Date: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd"
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone(secondsFromGMT: 0)
        return f
    }()
}
