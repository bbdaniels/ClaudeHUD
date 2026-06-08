import Foundation
import Combine
import os

private let logger = Logger(subsystem: "com.claudehud", category: "VaultProjectService")

/// Lists projects in the Obsidian vault and surfaces their canonical
/// per-project metadata (frontmatter + existence flags + file paths)
/// for the Vault tab. **Eager** on metadata (status, updated, cwds);
/// **lazy** on body content (Tasks.md, Dashboard.md, Technical Notes.md
/// are read on demand when a row expands), so refreshing the whole
/// list doesn't open 30 markdown files unnecessarily.
///
/// Architecture: see Documents/Obsidian/ClaudeHUD/Technical Notes.md
/// §Vault/Projects tab redistribution. The HUD is a window over the
/// archive; this service does no synthesis — every value rendered in
/// the Vault tab is a verbatim slice of a vault file.
@MainActor
final class VaultProjectService: ObservableObject {

    // MARK: - Public types

    struct Project: Identifiable, Hashable {
        var id: URL { folder }
        let folder: URL
        let name: String                  // folder basename
        let status: String                // raw frontmatter value (active, wrapping-up, …)
        let updated: Date?                // parsed from frontmatter `updated:`
        let updatedRaw: String            // raw frontmatter value, for display fallback
        let cwds: [String]                // first non-glob is used by "New session here"
        let hasDashboard: Bool
        let hasTechnicalNotes: Bool
        let hasSessions: Bool
        let hasSessionLog: Bool
        let otherMarkdownFiles: [URL]     // .md files in folder other than the canonical ones

        var tasksPath: URL { folder.appending(path: "Tasks.md") }
        var dashboardPath: URL { folder.appending(path: "Dashboard.md") }
        var technicalNotesPath: URL { folder.appending(path: "Technical Notes.md") }
        var sessionsPath: URL { folder.appending(path: "Sessions.md") }
        var sessionLogPath: URL { folder.appending(path: "Session Log.md") }

        /// First absolute non-glob `cwds:` entry (for "New session here").
        var primaryCwd: String? {
            cwds.first { $0.hasPrefix("/") && !$0.contains("*") }
        }

        /// `updated:` more than 30 days ago + status ∈ {active, wrapping-up}.
        var isStale: Bool {
            guard let updated, status == "active" || status == "wrapping-up" else { return false }
            return Date().timeIntervalSince(updated) > 30 * 24 * 3600
        }

        var isActive: Bool { status == "active" || status == "wrapping-up" }
        var isInactive: Bool { status == "done" || status == "archived" }
    }

    // MARK: - Published state

    @Published private(set) var projects: [Project] = []
    @Published private(set) var lastRefresh: Date = .distantPast

    // MARK: - Configuration

    private(set) var vaultPath: URL?

    /// Filenames the Notes section's "other files" listing excludes
    /// (they have their own dedicated subsections).
    private let canonicalFiles: Set<String> = [
        "Tasks.md", "Dashboard.md", "Technical Notes.md", "Sessions.md", "Session Log.md"
    ]

    // MARK: - Lifecycle

    func start(vaultPath: URL?) {
        self.vaultPath = vaultPath
        refresh()
    }

    /// Re-scan the vault. Call from view `onAppear` or explicitly after
    /// the vault changes. Cheap (just reads frontmatter), so safe.
    func refresh() {
        guard let vault = vaultPath else {
            projects = []
            return
        }
        let folders = (try? FileManager.default.contentsOfDirectory(
            at: vault, includingPropertiesForKeys: [.isDirectoryKey]
        )) ?? []
        var out: [Project] = []
        for folder in folders {
            guard let isDir = try? folder.resourceValues(forKeys: [.isDirectoryKey]).isDirectory, isDir,
                  !folder.lastPathComponent.hasPrefix(".") else { continue }
            if let p = parseProject(folder: folder) { out.append(p) }
        }
        // Sort: active+wrapping-up first (by updated desc), then everything else (by updated desc).
        out.sort { lhs, rhs in
            if lhs.isActive != rhs.isActive { return lhs.isActive }   // active first
            let l = lhs.updated ?? .distantPast
            let r = rhs.updated ?? .distantPast
            return l > r
        }
        projects = out
        lastRefresh = Date()
        logger.info("vault projects refreshed: \(out.count) total, \(out.filter { $0.isActive }.count) active")
    }

    // MARK: - Per-project parse

    private func parseProject(folder: URL) -> Project? {
        let tasks = folder.appending(path: "Tasks.md")
        guard let content = try? String(contentsOf: tasks, encoding: .utf8) else { return nil }
        let fm = parseFrontmatter(content)

        let status = fm["status"] ?? "unknown"
        let updatedRaw = fm["updated"] ?? ""
        let updated = ISO8601DateFormatter.dateOnly.date(from: updatedRaw)
            ?? DateFormatter.iso8601Date.date(from: updatedRaw)
        let cwds = parseFrontmatterList(content, key: "cwds")

        let dirContents = (try? FileManager.default.contentsOfDirectory(
            at: folder, includingPropertiesForKeys: nil
        )) ?? []
        let mdFiles = dirContents.filter { $0.pathExtension == "md" }
        let canonical = canonicalFiles
        let others = mdFiles.filter { !canonical.contains($0.lastPathComponent) }

        return Project(
            folder: folder,
            name: folder.lastPathComponent,
            status: status,
            updated: updated,
            updatedRaw: updatedRaw,
            cwds: cwds,
            hasDashboard: mdFiles.contains { $0.lastPathComponent == "Dashboard.md" },
            hasTechnicalNotes: mdFiles.contains { $0.lastPathComponent == "Technical Notes.md" },
            hasSessions: mdFiles.contains { $0.lastPathComponent == "Sessions.md" },
            hasSessionLog: mdFiles.contains { $0.lastPathComponent == "Session Log.md" },
            otherMarkdownFiles: others.sorted { $0.lastPathComponent < $1.lastPathComponent }
        )
    }

    // MARK: - Frontmatter (top-level scalars)

    private func parseFrontmatter(_ content: String) -> [String: String] {
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
    private func parseFrontmatterList(_ content: String, key: String) -> [String] {
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
                // A new top-level key ends the list.
                if !line.isEmpty, !line.hasPrefix(" "), !line.hasPrefix("\t") {
                    collecting = false
                    continue
                }
                let trimmed = line.trimmingCharacters(in: .whitespaces)
                if trimmed.hasPrefix("- ") {
                    let v = trimmed.dropFirst(2).trimmingCharacters(in: CharacterSet(charactersIn: "'\""))
                    out.append(String(v))
                }
            }
        }
        return out
    }

    // MARK: - ActiveTask model

    /// A top-level entry in a `## Active` block. Two shapes:
    ///
    /// - **Heading group** (`isHeading == true`) — from a `### ` heading.
    ///   `body` is the narrative prose under the heading (reflowed);
    ///   `subBullets` are the bullets (checkbox or otherwise) beneath it.
    ///   A heading is a section, not a togglable item, so `isDone` is
    ///   always false and the view draws no checkbox for it.
    /// - **Bullet task** (`isHeading == false`) — a top-level `- ` bullet
    ///   that is NOT under any heading (the flat `- **Title**:` style).
    ///   `body` is the inline + continuation text; `subBullets` are the
    ///   nested `  - …` items.
    ///
    /// `isDone` is authoritative and decided once at parse time: a `- [x]`
    /// marker, a fully struck-through title, or a `✅` in the title — NOT
    /// an incidental "✅ DONE" mention in the body (that marks one clause
    /// done, not the whole item, and was the source of the false
    /// strike-through on multi-clause calendar entries).
    struct ActiveTask: Identifiable, Hashable {
        let id = UUID()
        let title: String
        let body: String
        let subBullets: [SubBullet]
        let isDone: Bool
        let isHeading: Bool
        /// Absolute source-file line of the opening bullet (for a flat
        /// task); nil for heading groups (a section is not a single line).
        /// Lets a second consumer (the Today tab) toggle the task in place.
        var line: Int? = nil

        func hash(into hasher: inout Hasher) { hasher.combine(id) }
        static func == (lhs: ActiveTask, rhs: ActiveTask) -> Bool { lhs.id == rhs.id }
    }

    /// A child item under a heading group or a bullet task. `text` keeps
    /// the user's own `**Title**: body` one-liner (any `[ ]`/`[x]` marker
    /// stripped); `isDone` is set at parse time from the checkbox marker
    /// or a struck/✅ title, so the view never re-derives it from prose.
    /// `line` is the absolute source-file line of the child's bullet.
    struct SubBullet: Hashable {
        let text: String
        let isDone: Bool
        var line: Int = -1
    }

    // MARK: - Lazy parsers (called by views when expanded)

    /// Drop a leading YAML frontmatter block, if any.
    static func stripFrontmatter(_ content: String) -> String {
        guard content.hasPrefix("---\n") else { return content }
        let body = String(content.dropFirst(4))
        guard let end = body.range(of: "\n---\n") else { return content }
        return String(body[end.upperBound...]).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Prose between `# <H1>` and the next `## ` heading. The H1 is what
    /// `Tasks.md` always opens with (`# <Project> Tasks`); the preamble
    /// after it is the user-authored project description. Returns nil
    /// if no preamble is present. Source-markdown soft line breaks (≤80
    /// char wrapping) are reflowed to spaces; blank lines preserved as
    /// paragraph separators, so the rendered text wraps to the panel
    /// width instead of the markdown source width.
    static func extractPreamble(from content: String) -> String? {
        let stripped = stripFrontmatter(content)
        var inPreamble = false
        var collected: [String] = []
        for line in stripped.components(separatedBy: "\n") {
            if !inPreamble {
                if line.hasPrefix("# ") { inPreamble = true }
                continue
            }
            if line.hasPrefix("## ") { break }
            collected.append(line)
        }
        let result = reflowProse(collected)
        return result.isEmpty ? nil : result
    }

    /// First non-empty paragraph of a markdown string. Skips frontmatter
    /// and any leading headings; "paragraph" = first run of consecutive
    /// non-empty lines, reflowed to a single line.
    static func extractFirstParagraph(from content: String) -> String? {
        let stripped = stripFrontmatter(content)
        var collected: [String] = []
        for line in stripped.components(separatedBy: "\n") {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if collected.isEmpty {
                if trimmed.isEmpty || trimmed.hasPrefix("#") { continue }
                collected.append(line)
            } else {
                if trimmed.isEmpty { break }
                collected.append(line)
            }
        }
        let result = reflowProse(collected)
        return result.isEmpty ? nil : result
    }

    /// Join consecutive non-empty lines with a single space; preserve
    /// blank lines as paragraph breaks (`\n\n`). Markdown convention:
    /// a single newline inside a paragraph is a soft break (= space).
    private static func reflowProse(_ lines: [String]) -> String {
        var paragraphs: [[String]] = [[]]
        for line in lines {
            if line.trimmingCharacters(in: .whitespaces).isEmpty {
                if !paragraphs[paragraphs.count - 1].isEmpty {
                    paragraphs.append([])
                }
            } else {
                paragraphs[paragraphs.count - 1]
                    .append(line.trimmingCharacters(in: .whitespaces))
            }
        }
        return paragraphs
            .filter { !$0.isEmpty }
            .map { $0.joined(separator: " ") }
            .joined(separator: "\n\n")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Pull out the body between a `## <heading>` line and the next `## ` line.
    /// Returns nil if the section isn't present.
    static func extractSection(named heading: String, from content: String) -> String? {
        let prefix = "## \(heading)"
        var inSection = false
        var collected: [String] = []
        for line in content.components(separatedBy: "\n") {
            if !inSection {
                if line.trimmingCharacters(in: .whitespaces) == prefix
                    || line.hasPrefix(prefix + " ") {
                    inSection = true
                }
                continue
            }
            if line.hasPrefix("## ") { break }
            collected.append(line)
        }
        guard inSection else { return nil }
        return collected.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Split a `**Title**: body` (or `**Title** — body`) string into
    /// (title, body) without assuming the closing `**` sits on one line —
    /// it scans the whole string. Falls back to (wholeString, "") when
    /// there is no leading bold. Single source of truth for bullet-title
    /// extraction, shared by the parser, the Vault tab's `SubBulletRow`,
    /// and the Today tab's task mapping (`VaultManager.extractActiveTasks`).
    static func splitBullet(_ s: String) -> (title: String, body: String) {
        let t = s.trimmingCharacters(in: .whitespaces)
        if t.hasPrefix("**") {
            let afterOpen = t.index(t.startIndex, offsetBy: 2)
            if let close = t.range(of: "**", range: afterOpen..<t.endIndex) {
                let title = String(t[afterOpen..<close.lowerBound]).trimmingCharacters(in: .whitespaces)
                var body = String(t[close.upperBound...]).trimmingCharacters(in: .whitespaces)
                if body.hasPrefix(":") { body = String(body.dropFirst()).trimmingCharacters(in: .whitespaces) }
                return (title, body)
            }
        }
        return (t, "")
    }

    /// Parse `## Active` into structured tasks. Handles the two authoring
    /// styles found across the vault:
    ///
    /// 1. **`### ` headings + `- [ ]` checkboxes** (the common style —
    ///    Dissertation, Mumbai, Job Search, …). Each `### ` heading becomes
    ///    a collapsible **heading group**; every bullet under it (checkbox,
    ///    `- **bold**`, or plain) becomes a child; prose under the heading
    ///    becomes the group body; nested `  - ` items fold into the
    ///    current child's detail.
    /// 2. **Flat `- **Title**:`** (no headings — ClaudeHUD, GAAF, …). Each
    ///    top-level bullet is a task; nested `  - ` items are its children.
    ///
    /// Done-state never comes from an incidental "✅ DONE" in the prose —
    /// only a `[x]` marker, a fully struck-through title, or a `✅` in the
    /// title counts (see `ActiveTask`).
    static func parseActiveTasks(from content: String) -> [ActiveTask] {
        var tasks: [ActiveTask] = []

        // The open container — a `### ` heading group or a flat bullet task.
        // For a heading, `openHeading` holds the title and `openBodyLines`
        // is its narrative. For a flat task, `openFlat` is true and
        // `openBodyLines` accumulates the bullet's own text + continuations;
        // its title/body are split at flush time (so a `**bold**` title that
        // wraps across source lines is joined before it is parsed).
        var openHeading: String? = nil
        var openFlat = false
        var openCheckbox: Bool? = nil      // flat task's `[ ]`/`[x]` state, if any
        var openLine: Int? = nil           // flat task's opening-bullet file line
        var openBodyLines: [String] = []
        var openChildren: [SubBullet] = []

        // The child currently being assembled, so nested/continuation
        // lines attach to it rather than the container body. `childLine`
        // is the file line of the child's own bullet (for in-place toggle).
        var childText: String? = nil
        var childCont: [String] = []
        var childDone = false
        var childLine = -1

        func resetOpen() {
            openHeading = nil; openFlat = false; openCheckbox = nil; openLine = nil
            openBodyLines = []; openChildren = []
        }

        func flushChild() {
            guard let t = childText else { return }
            let cont = childCont.joined(separator: " ").trimmingCharacters(in: .whitespaces)
            let text = cont.isEmpty ? t : "\(t) \(cont)"
            openChildren.append(SubBullet(text: text, isDone: childDone, line: childLine))
            childText = nil
            childCont = []
            childDone = false
            childLine = -1
        }

        // Bullets are matched on `-` only (the vault's sole list marker).
        // Allowing `*`/`+` would misread soft-wrapped prose that happens to
        // begin a line with "+ " or "* " (e.g. a wrapped "Rationale + …")
        // as a list item.
        let headingPattern  = try? NSRegularExpression(pattern: #"^#{3,6}\s+(.*)$"#)
        let topBulletPattern = try? NSRegularExpression(pattern: #"^-\s+(.*)$"#)
        let nestedBulletPattern = try? NSRegularExpression(pattern: #"^\s{2,}-\s+(.*)$"#)
        let contPattern = try? NSRegularExpression(pattern: #"^\s{2,}(\S.*)$"#)
        let checkboxPattern = try? NSRegularExpression(pattern: #"^\[([ xX])\]\s*(.*)$"#)

        func match(_ re: NSRegularExpression?, _ s: String) -> NSTextCheckingResult? {
            guard let re else { return nil }
            let ns = s as NSString
            return re.firstMatch(in: s, range: NSRange(location: 0, length: ns.length))
        }
        func cap(_ m: NSTextCheckingResult, _ i: Int, _ s: String) -> String {
            let ns = s as NSString
            let r = m.range(at: i)
            return r.location == NSNotFound ? "" : ns.substring(with: r)
        }

        /// Strip a leading `[ ]`/`[x]` marker. Returns the remaining text
        /// and the checked state (nil when there was no checkbox).
        func stripCheckbox(_ inner: String) -> (text: String, done: Bool?) {
            if let m = match(checkboxPattern, inner) {
                let mark = cap(m, 1, inner)
                return (cap(m, 2, inner).trimmingCharacters(in: .whitespaces), mark == "x" || mark == "X")
            }
            return (inner, nil)
        }

        // Title/body split shared with the views (single source of truth).
        func splitTitleBody(_ s: String) -> (title: String, body: String) {
            VaultProjectService.splitBullet(s)
        }

        /// Done-state for a non-checkbox item is read from the TITLE only —
        /// a fully struck title or a `✅` in it — never from body prose, so
        /// an incidental "✅ DONE" clause inside an open item never marks the
        /// whole item done.
        func titleIsDone(_ title: String) -> Bool {
            let t = title.trimmingCharacters(in: .whitespaces)
            let fullyStruck = t.hasPrefix("~~") && t.hasSuffix("~~") && t.count > 4
            return fullyStruck || title.contains("✅")
        }

        /// A child item under a heading: strip any checkbox, then keep the
        /// raw `**Title**: body` text for the view to render.
        func childFrom(_ inner: String) -> (text: String, done: Bool) {
            let (text, box) = stripCheckbox(inner)
            if let box { return (text, box) }
            let (title, _) = splitTitleBody(text)
            return (text, titleIsDone(title))
        }

        func flushOpen() {
            flushChild()
            if let h = openHeading {
                tasks.append(ActiveTask(
                    title: h, body: reflowProse(openBodyLines),
                    subBullets: openChildren, isDone: false, isHeading: true
                ))
            } else if openFlat {
                let (title, body) = splitTitleBody(reflowProse(openBodyLines))
                if !title.isEmpty {
                    let done = openCheckbox ?? titleIsDone(title)
                    tasks.append(ActiveTask(
                        title: title, body: body,
                        subBullets: openChildren, isDone: done, isHeading: false,
                        line: openLine
                    ))
                }
            }
            resetOpen()
        }

        // Iterate the whole file (not a trimmed `## Active` slice) so each
        // bullet carries its absolute line number — the Today tab toggles
        // tasks by (file, line). Gate to the `## Active` section: enter on
        // the `## Active` heading, leave at the next `## ` H2 (a `### `
        // subsection does NOT match `"## "` so it stays inside Active).
        var inActive = false
        for (idx, rawLine) in content.components(separatedBy: "\n").enumerated() {
            if !inActive {
                let t = rawLine.trimmingCharacters(in: .whitespaces)
                if t == "## Active" || rawLine.hasPrefix("## Active ") { inActive = true }
                continue
            }
            if rawLine.hasPrefix("## ") { break }

            // 1. `### ` heading → start a new heading group.
            if let m = match(headingPattern, rawLine) {
                flushOpen()
                openHeading = cap(m, 1, rawLine).trimmingCharacters(in: .whitespaces)
                continue
            }
            // 2. Nested bullet (indent ≥ 2) → detail of the current child
            //    (under a heading) or a sub-bullet of the open flat task.
            if let m = match(nestedBulletPattern, rawLine) {
                let inner = cap(m, 1, rawLine)
                if openHeading != nil {
                    if childText != nil {
                        childCont.append(inner.trimmingCharacters(in: .whitespaces))
                    } else {
                        let (text, done) = childFrom(inner)
                        childText = text; childDone = done; childLine = idx
                    }
                } else if openFlat {
                    flushChild()
                    let (text, done) = childFrom(inner)
                    childText = text; childDone = done; childLine = idx
                }
                continue
            }
            // 3. Top-level bullet → a child of the open heading, else a new
            //    flat top-level task (title parsed at flush, see above).
            if let m = match(topBulletPattern, rawLine) {
                let inner = cap(m, 1, rawLine)
                if openHeading != nil {
                    flushChild()
                    let (text, done) = childFrom(inner)
                    childText = text; childDone = done; childLine = idx
                } else {
                    flushOpen()
                    let (text, box) = stripCheckbox(inner)
                    openFlat = true
                    openCheckbox = box
                    openLine = idx
                    openBodyLines = [text]
                }
                continue
            }
            // 4. Continuation (indented, no bullet) → current child, else the
            //    open container's body.
            if let m = match(contPattern, rawLine) {
                let text = cap(m, 1, rawLine).trimmingCharacters(in: .whitespaces)
                if childText != nil {
                    childCont.append(text)
                } else if openHeading != nil || openFlat {
                    openBodyLines.append(text)
                }
                continue
            }
            // 5. Blank line → end the current child; keep the container open
            //    (record the paragraph break in the body for reflow).
            if rawLine.trimmingCharacters(in: .whitespaces).isEmpty {
                flushChild()
                if openHeading != nil || openFlat { openBodyLines.append("") }
                continue
            }
            // 6. Loose prose (non-indented, non-bullet) → narrative for an
            //    open heading. For an open flat task it is a new paragraph
            //    that is not part of the bullet, so close the task. Outside
            //    any container it is intro text and is ignored.
            if openHeading != nil {
                flushChild()
                openBodyLines.append(rawLine.trimmingCharacters(in: .whitespaces))
            } else if openFlat {
                flushOpen()
            }
        }
        flushOpen()
        return tasks
    }

    // MARK: - Canonical cwd → vault-folder resolution (the WORK-section join key)

    /// Cache of repo working-directory → resolved vault folder NAME. The value
    /// is itself optional: `.some(nil)` records a cwd that resolves to NO
    /// project (so it is not re-scanned); an absent key means "not yet
    /// resolved." Keyed by absolute cwd. Primed off the main actor by
    /// `primeResolution`; read synchronously via `folderName(forCwd:)`.
    private var cwdFolderCache: [String: String?] = [:]

    /// Resolve every cwd in `cwds` to its vault folder using the ONE canonical
    /// rule — `ProjectService.resolveProjectFolder`, the same longest-`cwds:`-
    /// glob resolver the ingest hook (`vault-ingest.sh`) and the launcher use —
    /// caching the results. The disk scan runs off the main actor; only the
    /// small cache merge touches the actor. Call this before reading
    /// `folderName(forCwd:)` in a render path so lookups are warm. Cheap on
    /// repeat: only cache misses are scanned.
    func primeResolution(forCwds cwds: Set<String>) async {
        guard let vaultRoot = vaultPath?.path else { return }
        let misses = cwds.filter { cwdFolderCache[$0] == nil }
        guard !misses.isEmpty else { return }
        let resolved: [String: String?] = await Task.detached(priority: .userInitiated) {
            var out: [String: String?] = [:]
            for cwd in misses {
                out[cwd] = ProjectService.resolveProjectFolder(cwd: cwd, vaultPath: vaultRoot)
            }
            return out
        }.value
        for (k, v) in resolved { cwdFolderCache[k] = v }
    }

    /// Cached resolved vault folder NAME for a repo cwd (nil = unclaimed, or
    /// not yet primed). Pure cache read — call `primeResolution(forCwds:)`
    /// first. Matches `Project.name` (the folder basename) for filtering.
    func folderName(forCwd cwd: String) -> String? {
        cwdFolderCache[cwd] ?? nil
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
