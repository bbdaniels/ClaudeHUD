import Foundation
import Combine
import os

private let logger = Logger(subsystem: "com.claudehud", category: "VaultProjectService")

/// Lists projects in the Obsidian vault and surfaces their canonical
/// per-project metadata (the `Tasks.md` frontmatter: status, updated, cwds,
/// manuscript, parent) for the Projects tab, plus the cwd → project join the
/// live-session badges use. It also holds the `## Active` task parser the
/// Today tab reads.
///
/// Architecture: see Documents/Obsidian/ClaudeHUD/Technical Notes.md
/// §Vault/Projects tab redistribution. The HUD is a window over the
/// archive; this service does no synthesis — every value rendered in
/// the Projects tab is a verbatim slice of a vault file.
@MainActor
final class VaultProjectService: ObservableObject {

    // MARK: - Public types

    /// The project model lives in `VaultProjectTree.swift` (Foundation-only, so
    /// the unit tests compile it directly) together with the scan and the
    /// parent → children tree.
    typealias Project = VaultProject

    // MARK: - Published state

    @Published private(set) var projects: [Project] = []
    @Published private(set) var lastRefresh: Date = .distantPast

    // MARK: - Configuration

    private(set) var vaultPath: URL?

    /// Bumped at the start of every `refresh()`; a scan publishes only if it
    /// is still the newest, so a slow (iCloud-cold) scan that finishes after
    /// a later one can never overwrite fresher results.
    private var scanGeneration = 0

    // MARK: - Lifecycle

    func start(vaultPath: URL?) {
        self.vaultPath = vaultPath
        refresh()
    }

    /// Re-scan the vault. Call from view `onAppear` or explicitly after
    /// the vault changes. NOT cheap: it reads every project's `Tasks.md` in
    /// full, and the vault is iCloud-evicted, so a
    /// cold scan blocks 0.5–2 s per file (a 39 s main-thread hang when this
    /// ran synchronously). The scan therefore runs detached; only the
    /// publish touches the main actor. Fire-and-forget; `await` it when
    /// the caller needs the fresh list.
    @discardableResult
    func refresh() -> Task<Void, Never> {
        scanGeneration &+= 1
        let generation = scanGeneration
        guard let vault = vaultPath else {
            projects = []
            return Task {}
        }
        return Task { [weak self] in
            let out = await Task.detached(priority: .userInitiated) {
                VaultProject.scan(vaultPath: vault)
            }.value
            guard let self, generation == self.scanGeneration else { return }
            self.projects = out
            self.lastRefresh = Date()
            logger.info("vault projects refreshed: \(out.count) total, \(out.filter { $0.isActive }.count) active")
        }
    }

    /// Insert (or replace) one project parsed from `folder`, re-sorted into
    /// place, without waiting for a full scan — used right after "New
    /// Project" so the row appears at once. Parses via the same
    /// `VaultProject.parse` as the scan; one small folder, so a main-actor read
    /// of a just-written (never evicted) file is fine. Returns the project.
    @discardableResult
    func insertProject(folder: URL) -> Project? {
        guard let p = VaultProject.parse(folder: folder) else { return nil }
        var out = projects.filter { $0.name != p.name }
        out.append(p)
        projects = VaultProject.sorted(out)
        return p
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

    // MARK: - Task parsers (nonisolated so the file read + parse can run off
    // the main actor)

    /// Join consecutive non-empty lines with a single space; preserve
    /// blank lines as paragraph breaks (`\n\n`). Markdown convention:
    /// a single newline inside a paragraph is a soft break (= space).
    private nonisolated static func reflowProse(_ lines: [String]) -> String {
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

    /// Split a `**Title**: body` (or `**Title** — body`) string into
    /// (title, body) without assuming the closing `**` sits on one line —
    /// it scans the whole string. Falls back to (wholeString, "") when
    /// there is no leading bold. Single source of truth for bullet-title
    /// extraction, shared by the parser and the Today tab's task mapping
    /// (`VaultManager.extractActiveTasks`).
    nonisolated static func splitBullet(_ s: String) -> (title: String, body: String) {
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
    nonisolated static func parseActiveTasks(from content: String) -> [ActiveTask] {
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
                // A heading is normally never "done" — but a `### ✅ …` or a
                // fully-struck heading IS a finished milestone (the user's
                // "✅ DNS done … 0/8" lingering in Active). Mark it so the view
                // can strike it and drop the misleading 0/N count.
                tasks.append(ActiveTask(
                    title: h, body: reflowProse(openBodyLines),
                    subBullets: openChildren, isDone: titleIsDone(h), isHeading: true
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

    // MARK: - Canonical cwd → vault-folder resolution (the session → project join key)

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

    // MARK: - Live sessions per project

    /// folder name → the live INTERACTIVE sessions among `agents`. THE
    /// session-to-project join for anything that acts on a project's open
    /// windows: the Projects badges, the badge's click-to-focus, and the
    /// launcher's window-or-tab decision all read it, so they cannot disagree
    /// about which sessions belong to a project. Unsorted: ordering is only
    /// needed on click, and the Projects list calls this on every body pass.
    func liveSessionsByFolder(in agents: [AgentSession]) -> [String: [AgentSession]] {
        var map: [String: [AgentSession]] = [:]
        for a in agents {
            guard a.isAlive, a.isOpen, !a.cwd.isEmpty,
                  let folder = folderName(forCwd: a.cwd) else { continue }
            // Only the three badged buckets: an alive+open session in an
            // unrecognized daemon state (`.other`) must not be click-cyclable
            // when the badge never advertised it.
            switch a.bucket {
            case .working, .needsInput, .idle: break
            default: continue
            }
            map[folder, default: []].append(a)
        }
        return map
    }

    /// The live sessions of `folders`, merged, most recently active first: one
    /// folder for a project's own sessions (a child row's badge, and every
    /// launch), a parent's folder plus its children's for the parent row's
    /// badge.
    ///
    /// `updatedAt` alone is not the recency: the daemon flushes `state.json`
    /// event-driven and can lag minutes behind an actively working session,
    /// while the transcript ticks on every turn — so the later of the two is
    /// the honest ordering.
    func liveSessions(forFolders folders: [String], in agents: [AgentSession]) -> [AgentSession] {
        func recency(_ a: AgentSession) -> Date {
            max(a.updatedAt ?? .distantPast, a.transcriptMtime ?? .distantPast)
        }
        let byFolder = liveSessionsByFolder(in: agents)
        return folders.flatMap { byFolder[$0] ?? [] }.sorted { recency($0) > recency($1) }
    }
}
