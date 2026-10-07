import Foundation

// The Projects tab's model: one `VaultProject` per vault folder with a
// `Tasks.md`, and the parent → children tree built from them. Foundation-only
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
    let cwds: [String]                // first non-glob is used by "New session here"
    let manuscript: String?           // frontmatter `manuscript:` — declared paper dir
    /// Frontmatter `parent:` exactly as declared (nil when absent or empty).
    /// Declared, not validated: only `ProjectTree.build` decides whether it
    /// makes this project a child. Nothing else may interpret it.
    let parent: String?

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
        let tasks = folder.appending(path: "Tasks.md")
        guard let content = try? String(contentsOf: tasks, encoding: .utf8) else { return nil }
        return parse(folder: folder, tasksContent: content)
    }

    static func parse(folder: URL, tasksContent content: String) -> VaultProject {
        let fm = parseFrontmatter(content)
        let updatedRaw = fm["updated"] ?? ""
        let updated = ISO8601DateFormatter.dateOnly.date(from: updatedRaw)
            ?? DateFormatter.iso8601Date.date(from: updatedRaw)
        let parent = fm["parent"].flatMap { $0.isEmpty ? nil : $0 }
        return VaultProject(
            folder: folder,
            name: folder.lastPathComponent,
            status: fm["status"] ?? "unknown",
            updated: updated,
            cwds: parseFrontmatterList(content, key: "cwds"),
            manuscript: fm["manuscript"],
            parent: parent
        )
    }

    // MARK: Frontmatter (top-level scalars)

    static func parseFrontmatter(_ content: String) -> [String: String] {
        guard content.hasPrefix("---\n") else { return [:] }
        let body = String(content.dropFirst(4))
        guard let end = body.range(of: "\n---\n") else { return [:] }
        let block = String(body[..<end.lowerBound])
        var out: [String: String] = [:]
        for line in block.components(separatedBy: "\n") {
            // Top-level scalar: starts non-whitespace, contains `:`, value after `:`.
            // Skip lines that begin with whitespace (list items) and lines without `:`.
            guard !line.isEmpty, !line.hasPrefix(" "), !line.hasPrefix("\t") else { continue }
            guard let colon = line.firstIndex(of: ":") else { continue }
            let key = String(line[..<colon]).trimmingCharacters(in: .whitespaces)
            var val = String(line[line.index(after: colon)...]).trimmingCharacters(in: .whitespaces)
            // Strip surrounding quotes — YAML commonly quotes dates
            // (`updated: '2026-06-08'`), and an unquoted-only parse leaves the
            // quotes in, so the date fails to parse (→ nil → mis-bucketed as
            // "Older") and `status: 'active'` would miss its equality checks.
            if val.count >= 2,
               (val.hasPrefix("'") && val.hasSuffix("'")) ||
               (val.hasPrefix("\"") && val.hasSuffix("\"")) {
                val = String(val.dropFirst().dropLast())
            }
            if !key.isEmpty { out[key] = val }
        }
        return out
    }

    /// Parse a YAML-list value under a given key, e.g.
    /// `cwds:`
    /// `  - /Users/bbdaniels/Projects/ClaudeHUD`
    /// Returns the bare strings (quotes stripped).
    static func parseFrontmatterList(_ content: String, key: String) -> [String] {
        guard content.hasPrefix("---\n") else { return [] }
        let body = String(content.dropFirst(4))
        guard let end = body.range(of: "\n---\n") else { return [] }
        let block = String(body[..<end.lowerBound])
        var collecting = false
        var out: [String] = []
        for line in block.components(separatedBy: "\n") {
            // Begin collecting when we see `<key>:` at top level.
            if !collecting, !line.hasPrefix(" "), !line.hasPrefix("\t"),
               line.hasPrefix("\(key):") || line == "\(key):" {
                collecting = true
                // Inline scalar form (`key: [a, b]` or `key: ~`) is not list-shaped.
                let after = String(line.dropFirst("\(key):".count)).trimmingCharacters(in: .whitespaces)
                if !after.isEmpty && after != "~" && after != "[]" {
                    // Non-list value on the same line; ignore for list parsing.
                    collecting = false
                }
                continue
            }
            if collecting {
                let trimmed = line.trimmingCharacters(in: .whitespaces)
                // A list item — collect it whether indented (`  - x`) or flush-left
                // (`- x`). YAML allows a block sequence at the key's own indent, and
                // some serializers (e.g. the YAML lib behind property editors) emit
                // the flush-left form; the old "non-indented line ends the list"
                // check ran first and wrongly dropped those, leaving cwds empty
                // (so the project showed no launch controls — primaryCwd was nil).
                if trimmed.hasPrefix("- ") {
                    let v = trimmed.dropFirst(2).trimmingCharacters(in: CharacterSet(charactersIn: "'\""))
                    out.append(String(v))
                    continue
                }
                // A non-list, non-indented line is a new top-level key → list ends.
                if !line.isEmpty, !line.hasPrefix(" "), !line.hasPrefix("\t") {
                    collecting = false
                }
            }
        }
        return out
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
/// Documents/Obsidian/ClaudeHUD/plans/2026-10-07 - Nested Subprojects.md.
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
    /// first, compared as a boolean so two waiting families keep their recency
    /// order relative to each other; then most recent family activity first.
    static func ordered(_ nodes: [Node], live: [String: LiveSessionCounts],
                        activity: (VaultProject) -> Date) -> [Node] {
        nodes.sorted { a, b in
            let wa = a.liveCounts(in: live).blocked > 0
            let wb = b.liveCounts(in: live).blocked > 0
            if wa != wb { return wa }
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
