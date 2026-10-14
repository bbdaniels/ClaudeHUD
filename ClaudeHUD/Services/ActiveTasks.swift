import Foundation

// The one parser of a project's `Tasks.md` `## Active` section, read by the
// Projects tab scan (`VaultProject.parse`) and the daily note's task mapping
// (`VaultManager.extractActiveTasks`). Foundation-only and free of app state
// so the unit-test bundle compiles this file directly (see project.yml →
// ClaudeHUDTests).

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
    var line: Int? = nil
    /// Earliest `📅 YYYY-MM-DD` on the task's own text or on its open
    /// nested detail (see `ActiveTasks.dueDate(in:)`); nil for a heading
    /// group, whose children carry their own dates.
    var dueDate: Date? = nil

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
    /// Earliest `📅 YYYY-MM-DD` on the child's text, nested detail included.
    var dueDate: Date? = nil
}

// MARK: - Parser

enum ActiveTasks {

    /// A project's soonest-due open task: what the Projects-tab row shows.
    struct NextDue: Hashable {
        let date: Date
        /// The task's display title, `📅` token stripped.
        let title: String
    }

    /// One open (not-done) task as the rest of the app counts it: a flat
    /// task, or a child of a heading group. THE enumeration shared by the
    /// daily note's task mapping and the Projects-tab due chip, so they can
    /// never disagree about which items are tasks.
    struct OpenItem {
        /// The task's own text (a child's raw `**Title**: body` one-liner).
        let rawTitle: String
        /// The bold title alone, for compact display.
        let display: String
        let line: Int?
        /// The enclosing `### ` heading; nil for a flat task.
        let section: String?
        let dueDate: Date?
    }

    /// The open items of a parsed `## Active`: the not-done children of each
    /// heading group, and each not-done flat task (its nested detail already
    /// folded in by the parser, so it counts once).
    static func openItems(in tasks: [ActiveTask]) -> [OpenItem] {
        var out: [OpenItem] = []
        for task in tasks {
            if task.isHeading {
                for child in task.subBullets where !child.isDone {
                    out.append(OpenItem(rawTitle: child.text, display: splitBullet(child.text).title,
                                        line: child.line >= 0 ? child.line : nil,
                                        section: task.title, dueDate: child.dueDate))
                }
            } else if !task.isDone {
                out.append(OpenItem(rawTitle: task.title, display: task.title,
                                    line: task.line, section: nil, dueDate: task.dueDate))
            }
        }
        return out
    }

    /// The earliest due date among open items; a tie keeps the first in file
    /// order.
    static func nextDue(in tasks: [ActiveTask]) -> NextDue? {
        var best: NextDue?
        for item in openItems(in: tasks) {
            guard let d = item.dueDate else { continue }
            if best == nil || d < best!.date {
                best = NextDue(date: d, title: strippingDue(item.display))
            }
        }
        return best
    }

    /// Overdue = due before today, date-only: a task due today is not late.
    static func isOverdue(_ due: Date, now: Date = Date()) -> Bool {
        due < Calendar.current.startOfDay(for: now)
    }

    private static let duePattern = try? NSRegularExpression(
        pattern: #"📅\s*(\d{4})-(\d{2})-(\d{2})"#)
    private static let dueTokenPattern = try? NSRegularExpression(
        pattern: #"\s*📅\s*\d{4}-\d{2}-\d{2}"#)

    /// Earliest valid `📅 YYYY-MM-DD` (Obsidian Tasks plugin format) in
    /// `text`, as midnight in the local calendar. An impossible date
    /// (`2026-02-30`) is skipped rather than rolled over; nil when none.
    static func dueDate(in text: String) -> Date? {
        guard let re = duePattern else { return nil }
        let ns = text as NSString
        let cal = Calendar.current
        var best: Date?
        for m in re.matches(in: text, range: NSRange(location: 0, length: ns.length)) {
            var dc = DateComponents()
            dc.calendar = cal
            dc.year = Int(ns.substring(with: m.range(at: 1)))
            dc.month = Int(ns.substring(with: m.range(at: 2)))
            dc.day = Int(ns.substring(with: m.range(at: 3)))
            guard dc.isValidDate, let d = cal.date(from: dc) else { continue }
            if best == nil || d < best! { best = d }
        }
        return best
    }

    /// `text` with every `📅 YYYY-MM-DD` token (and the space before it)
    /// removed, for display.
    static func strippingDue(_ text: String) -> String {
        guard let re = dueTokenPattern else { return text }
        let ns = text as NSString
        return re.stringByReplacingMatches(in: text, range: NSRange(location: 0, length: ns.length),
                                           withTemplate: "")
            .trimmingCharacters(in: .whitespaces)
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

    /// Split a `**Title**: body` (or `**Title** — body`) string into
    /// (title, body) without assuming the closing `**` sits on one line —
    /// it scans the whole string. Falls back to (wholeString, "") when
    /// there is no leading bold. Single source of truth for bullet-title
    /// extraction, shared by the parser and the daily note's task mapping
    /// (`VaultManager.extractActiveTasks`).
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
    static func parse(from content: String) -> [ActiveTask] {
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
        // is the file line of the child's own bullet.
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
            openChildren.append(SubBullet(text: text, isDone: childDone, line: childLine,
                                          dueDate: dueDate(in: text)))
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
            splitBullet(s)
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
                let text = reflowProse(openBodyLines)
                let (title, body) = splitTitleBody(text)
                if !title.isEmpty {
                    let done = openCheckbox ?? titleIsDone(title)
                    // The task's own text, then its open nested detail.
                    let due = ([dueDate(in: text)] + openChildren.filter { !$0.isDone }.map(\.dueDate))
                        .compactMap { $0 }.min()
                    tasks.append(ActiveTask(
                        title: title, body: body,
                        subBullets: openChildren, isDone: done, isHeading: false,
                        line: openLine, dueDate: due
                    ))
                }
            }
            resetOpen()
        }

        // Iterate the whole file (not a trimmed `## Active` slice) so each
        // bullet carries its absolute line number. Gate to the `## Active` section: enter on
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
}
