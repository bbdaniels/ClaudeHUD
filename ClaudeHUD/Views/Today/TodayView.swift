import SwiftUI
import AppKit

// The Today pane is deliberately thin: the tasks actually due today
// (Apple Reminders due today/overdue + any checkboxes in today's daily
// note) sit at the top, and the daily note itself is the main body. The
// LLM day-summary, the calendar event list, and the sprawling
// all-projects `## Active` scan were removed — the full project task
// lists live on the Projects tab; calendar lives in Calendar.app.

struct TodayView: View {
    @EnvironmentObject var vaultManager: VaultManager
    @EnvironmentObject var remindersService: RemindersService
    @Environment(\.fontScale) private var scale
    @State private var dayOffset = 0

    private var selectedDate: Date {
        Calendar.current.date(byAdding: .day, value: dayOffset, to: Calendar.current.startOfDay(for: Date()))!
    }

    private var isToday: Bool { dayOffset == 0 }

    private func headerString(for date: Date) -> String {
        let fmt = DateFormatter()
        fmt.dateFormat = "EEEE, MMMM d"
        return fmt.string(from: date)
    }

    var body: some View {
        VStack(spacing: 0) {
            dateNav

            Divider().opacity(0.3)

            ScrollView {
                // Top: what's actually due today — reminders due today or
                // overdue, plus any checkboxes in today's daily note.
                WhatsNextView(date: selectedDate, isToday: isToday)

                // The daily note is the main body of the pane.
                DailyNoteSection(date: selectedDate)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .task(id: dayOffset) {
            let date = selectedDate
            remindersService.loadReminders(for: date)
            vaultManager.ensureDailyNote(for: date)
        }
    }

    /// Slim date navigator — prev/next day + a reset-to-today button. The
    /// calendar event list and its filter menu were removed; the nav stays
    /// so yesterday's/tomorrow's daily note and tasks remain reachable.
    private var dateNav: some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Button(action: { dayOffset -= 1 }) {
                Image(systemName: "chevron.left")
                    .font(.system(size: 9 * scale, weight: .semibold))
                    .foregroundColor(.secondary.opacity(0.5))
            }
            .buttonStyle(.borderless)

            Text(headerString(for: selectedDate))
                .font(.smallFont(scale))
                .foregroundColor(.primary)

            Button(action: { dayOffset += 1 }) {
                Image(systemName: "chevron.right")
                    .font(.system(size: 9 * scale, weight: .semibold))
                    .foregroundColor(.secondary.opacity(0.5))
            }
            .buttonStyle(.borderless)

            if !isToday {
                Button(action: { dayOffset = 0 }) {
                    HStack(spacing: 3) {
                        Image(systemName: "arrow.uturn.backward")
                            .font(.system(size: 9 * scale))
                        Text("today")
                            .font(.captionFont(scale).weight(.medium))
                    }
                    .foregroundColor(.blue)
                }
                .buttonStyle(.borderless)
            }

            Spacer()
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 6)
        .background(Color(.textBackgroundColor).opacity(0.3))
    }
}

// MARK: - Daily Note section
//
// Renders `Daily Notes/<yyyy-MM-dd>.md` for the selected date with
// a quick-capture text field (today only) that appends timestamped
// bullets to the end of the file. Replaces the access pattern the old
// standalone Notes tab carried: see today's note, drop a quick note
// without context-switching to Obsidian, open the floating window for
// full editing. Yesterday/tomorrow are read-only — capture only writes
// to today.

private struct DailyNoteSection: View {
    let date: Date
    @EnvironmentObject var vaultManager: VaultManager
    @Environment(\.fontScale) private var scale
    @AppStorage("today.dailyNoteCollapsed") private var collapsed = false
    @State private var content: String? = nil
    @State private var capture: String = ""
    /// Headings currently expanded. Empty = all collapsed (the chosen
    /// default): the note opens as a compact list of its `###` headings and
    /// you tap one to reveal its content. Not persisted — resets to
    /// collapsed on each date change / reload (a fresh glance each time).
    @State private var expandedHeadings: Set<String> = []

    private var dailyNotePath: String? {
        guard let vault = vaultManager.currentVault else { return nil }
        let fmt = DateFormatter()
        fmt.dateFormat = "yyyy-MM-dd"
        return (vault.path as NSString)
            .appendingPathComponent("Daily Notes/\(fmt.string(from: date)).md")
    }

    private var isToday: Bool { Calendar.current.isDateInToday(date) }

    private var summary: String {
        guard let content else { return "—" }
        let lines = content.split(separator: "\n").count
        return "\(lines) lines"
    }

    /// Structured preview of the daily note (most-recent tail): YAML
    /// frontmatter dropped, headings and bullets kept on their own lines,
    /// and only *runs of prose* reflowed (a single source `\n` inside a
    /// paragraph becomes a space, so the note's 80-char source wrapping
    /// doesn't leak as mid-sentence breaks). This is a light scan — full
    /// markdown (tables, images, math, nested lists) is still the floating
    /// window's job. The redundant H1 date heading is dropped (the section
    /// header + date nav already show the date). The cap is generous so
    /// the note reads as the pane's main content; only very long notes are
    /// tailed.
    private static let previewLineCap = 150
    private var previewRows: [DailyNotePreviewRow] {
        guard let content else { return [] }
        var lines = content.components(separatedBy: "\n")
        // Drop a leading `---` … `---` frontmatter block.
        if lines.first?.trimmingCharacters(in: .whitespaces) == "---",
           let close = lines.dropFirst().firstIndex(where: {
               $0.trimmingCharacters(in: .whitespaces) == "---"
           }) {
            lines = Array(lines[(close + 1)...])
        }
        if lines.count > Self.previewLineCap { lines = Array(lines.suffix(Self.previewLineCap)) }

        var rows: [DailyNotePreviewRow] = []
        var prose: [String] = []
        func flushProse() {
            let joined = prose.joined(separator: " ").trimmingCharacters(in: .whitespaces)
            if !joined.isEmpty { rows.append(.prose(joined)) }
            prose = []
        }
        for line in lines {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.isEmpty { flushProse(); continue }
            // Heading (`#`…`######` + space).
            if trimmed.hasPrefix("#") {
                let hashes = trimmed.prefix(while: { $0 == "#" }).count
                let rest = trimmed.drop(while: { $0 == "#" })
                if rest.first == " " {
                    flushProse()
                    if hashes > 1 {   // skip the H1 date heading
                        rows.append(.heading(text: rest.trimmingCharacters(in: .whitespaces), level: hashes))
                    }
                    continue
                }
            }
            // Bullet / checkbox — reuse the shared list parser.
            if ObsidianMarkdownView.isListLine(line) {
                flushProse()
                let item = ObsidianMarkdownView.parseListItem(line, lineNumber: 0)
                rows.append(.bullet(text: item.text, checked: item.checkState, indent: item.level))
                continue
            }
            prose.append(trimmed)
        }
        flushProse()
        return rows
    }

    /// Group the flat preview rows into collapsible sections: each heading
    /// owns the rows beneath it up to the next heading (flat, not nested).
    /// Rows before the first heading are the always-visible preamble
    /// (`heading == nil`), since they belong to no heading.
    private var noteSections: [NoteSection] {
        var sections: [NoteSection] = []
        var current = NoteSection(id: "preamble", heading: nil, rows: [])
        var idx = 0
        for row in previewRows {
            if case let .heading(text, level) = row {
                if current.heading != nil || !current.rows.isEmpty {
                    sections.append(current)
                }
                idx += 1
                current = NoteSection(id: "sec-\(idx)", heading: (text, level), rows: [])
            } else {
                current.rows.append(row)
            }
        }
        if current.heading != nil || !current.rows.isEmpty {
            sections.append(current)
        }
        return sections
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            if !collapsed {
                if isToday { captureField }
                let sections = noteSections
                if sections.isEmpty {
                    Text("No daily note yet for this date.")
                        .font(.captionFont(scale))
                        .foregroundColor(.secondary.opacity(0.7))
                        .padding(.horizontal, 14)
                        .padding(.top, 6)
                } else {
                    VStack(alignment: .leading, spacing: 3) {
                        ForEach(sections) { section in
                            if let heading = section.heading {
                                DailyNoteHeadingRow(
                                    text: heading.text,
                                    level: heading.level,
                                    isExpanded: expandedHeadings.contains(section.id),
                                    hasChildren: !section.rows.isEmpty,
                                    onToggle: { toggleHeading(section.id) }
                                )
                                if expandedHeadings.contains(section.id) {
                                    VStack(alignment: .leading, spacing: 3) {
                                        ForEach(Array(section.rows.enumerated()), id: \.offset) { _, row in
                                            DailyNotePreviewRowView(row: row)
                                        }
                                    }
                                    .padding(.leading, 12)
                                }
                            } else {
                                // Preamble — content before the first heading,
                                // always shown (it belongs to no heading).
                                ForEach(Array(section.rows.enumerated()), id: \.offset) { _, row in
                                    DailyNotePreviewRowView(row: row)
                                }
                            }
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .textSelection(.enabled)
                    .padding(.horizontal, 14)
                    .padding(.top, 8)
                }
                openButton
                    .padding(.top, 6)
                    .padding(.bottom, 10)
            }
        }
        .task(id: date) { loadContent() }
    }

    private var header: some View {
        Button(action: {
            withAnimation(.easeInOut(duration: 0.15)) { collapsed.toggle() }
        }) {
            HStack(spacing: 6) {
                Image(systemName: collapsed ? "chevron.right" : "chevron.down")
                    .font(.system(size: 9 * scale, weight: .semibold))
                    .foregroundColor(.secondary.opacity(0.6))
                Text("Daily Note")
                    .font(.captionFont(scale).weight(.semibold))
                    .foregroundColor(.secondary.opacity(0.75))
                    .textCase(.uppercase)
                    .tracking(0.5)
                Spacer()
                Text(summary)
                    .font(.custom("Fira Code", size: 10 * scale))
                    .foregroundColor(.secondary.opacity(0.55))
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 6)
            .background(Color(.textBackgroundColor).opacity(0.18))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private var captureField: some View {
        HStack(spacing: 6) {
            Image(systemName: "plus.circle")
                .font(.system(size: 11 * scale))
                .foregroundColor(.secondary.opacity(0.6))
            TextField("Add to today's note…", text: $capture)
                .font(.smallFont(scale))
                .textFieldStyle(.plain)
                .onSubmit(append)
            if !capture.isEmpty {
                Button(action: append) {
                    Image(systemName: "arrow.up.circle.fill")
                        .font(.system(size: 12 * scale))
                        .foregroundColor(.accentColor)
                }
                .buttonStyle(.borderless)
                .hudTip("Append timestamped line to today's note")
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 6)
        .background(Color(.textBackgroundColor).opacity(0.08))
    }

    private var openButton: some View {
        Button(action: openInFloatingWindow) {
            HStack(spacing: 4) {
                Image(systemName: "arrow.up.right.square")
                    .font(.system(size: 10 * scale))
                Text("Open in window")
                    .font(.captionFont(scale))
            }
            .foregroundColor(.accentColor)
            .padding(.horizontal, 14)
        }
        .buttonStyle(.plain)
    }

    private func loadContent() {
        guard let path = dailyNotePath else { content = nil; return }
        content = try? String(contentsOfFile: path, encoding: .utf8)
    }

    private func toggleHeading(_ id: String) {
        if expandedHeadings.contains(id) {
            expandedHeadings.remove(id)
        } else {
            expandedHeadings.insert(id)
        }
    }

    /// Append `- HH:MM <text>` to today's daily note. Creates the file
    /// if missing (rare — `vaultManager.ensureDailyNote` runs on the
    /// `.task(id: dayOffset)` earlier and would have populated it).
    private func append() {
        let text = capture.trimmingCharacters(in: .whitespaces)
        guard !text.isEmpty, isToday, let path = dailyNotePath else { return }
        let fmt = DateFormatter()
        fmt.dateFormat = "HH:mm"
        let line = "- \(fmt.string(from: Date())) \(text)\n"
        if let existing = try? String(contentsOfFile: path, encoding: .utf8) {
            let sep = existing.hasSuffix("\n") ? "" : "\n"
            try? (existing + sep + line).write(toFile: path, atomically: true, encoding: .utf8)
        } else {
            try? line.write(toFile: path, atomically: true, encoding: .utf8)
        }
        capture = ""
        loadContent()
    }

    private func openInFloatingWindow() {
        guard let path = dailyNotePath else { return }
        let url = URL(fileURLWithPath: path)
        let attrs = try? FileManager.default.attributesOfItem(atPath: path)
        let modDate = attrs?[.modificationDate] as? Date
        let file = NoteFile(
            name: url.lastPathComponent,
            path: path,
            relativePath: "Daily Notes/\(url.lastPathComponent)",
            isDirectory: false,
            modificationDate: modDate,
            children: nil
        )
        FloatingNoteWindowManager.shared.openWindow(for: file)
    }
}

/// Inline-markdown helper: strip Obsidian wikilink brackets, let
/// SwiftUI's built-in markdown parser handle bold/italic/code. Headings
/// (`## `) and list bullets render as literal text — full markdown
/// rendering requires the floating window.
private func prettifyMarkdownInline(_ s: String) -> LocalizedStringKey {
    var out = s
    out = out.replacingOccurrences(
        of: #"\[\[([^\]|]+)\|([^\]]+)\]\]"#,
        with: "$2",
        options: .regularExpression
    )
    out = out.replacingOccurrences(
        of: #"\[\[([^\]]+)\]\]"#,
        with: "$1",
        options: .regularExpression
    )
    return LocalizedStringKey(out)
}

// MARK: - Daily Note preview rows

/// One structured line of the daily-note preview. Headings and bullets are
/// kept distinct from prose so the preview renders as a readable outline
/// instead of a reflowed wall of text (see `DailyNoteSection.previewRows`).
private enum DailyNotePreviewRow {
    case heading(text: String, level: Int)
    case bullet(text: String, checked: Bool?, indent: Int)
    case prose(String)
}

/// A run of preview rows grouped under one heading (or the leading preamble
/// when `heading == nil`). Sections are flat — a heading owns every row up to
/// the next heading, with no deeper nesting (see `DailyNoteSection.noteSections`).
private struct NoteSection: Identifiable {
    let id: String
    let heading: (text: String, level: Int)?
    var rows: [DailyNotePreviewRow]
}

/// A collapsible heading row in the daily-note preview: chevron + styled
/// heading, tap to reveal/hide the rows beneath it. A heading with no content
/// shows no chevron (nothing to reveal) and does not respond to taps.
private struct DailyNoteHeadingRow: View {
    let text: String
    let level: Int
    let isExpanded: Bool
    let hasChildren: Bool
    let onToggle: () -> Void
    @Environment(\.fontScale) private var scale

    var body: some View {
        Button(action: {
            guard hasChildren else { return }
            withAnimation(.easeInOut(duration: 0.15)) { onToggle() }
        }) {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Image(systemName: isExpanded ? "chevron.down" : "chevron.right")
                    .font(.system(size: 9 * scale, weight: .semibold))
                    .foregroundColor(.secondary.opacity(hasChildren ? 0.5 : 0))
                    .frame(width: 10)
                Text(prettifyMarkdownInline(text))
                    .font(.custom("Fira Sans", size: (level <= 2 ? 12.5 : 11.5) * scale).weight(.semibold))
                    .foregroundColor(.primary)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 0)
            }
            .contentShape(Rectangle())
            .padding(.top, 3)
        }
        .buttonStyle(.plain)
    }
}

private struct DailyNotePreviewRowView: View {
    let row: DailyNotePreviewRow
    @Environment(\.fontScale) private var scale

    var body: some View {
        switch row {
        case .heading(let text, let level):
            Text(prettifyMarkdownInline(text))
                .font(.custom("Fira Sans", size: (level <= 2 ? 12.5 : 11.5) * scale).weight(.semibold))
                .foregroundColor(.primary)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.top, 3)
        case .bullet(let text, let checked, let indent):
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Group {
                    if let checked {
                        Image(systemName: checked ? "checkmark.square" : "square")
                            .font(.system(size: 10 * scale))
                            .foregroundColor(.secondary.opacity(0.6))
                    } else {
                        Text("•")
                            .font(.captionFont(scale))
                            .foregroundColor(.secondary.opacity(0.6))
                    }
                }
                .frame(width: 12, alignment: .leading)
                Text(prettifyMarkdownInline(text))
                    .font(.captionFont(scale))
                    .foregroundColor(.primary.opacity(checked == true ? 0.5 : 0.85))
                    .strikethrough(checked == true)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(.leading, CGFloat(min(indent, 3)) * 12)
        case .prose(let text):
            Text(prettifyMarkdownInline(text))
                .font(.captionFont(scale))
                .foregroundColor(.primary.opacity(0.85))
                .lineSpacing(2)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}
