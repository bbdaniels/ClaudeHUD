import SwiftUI
import AppKit

/// Vault tab — one row per project (top-level vault folder with a
/// `Tasks.md`). Tap a row to reveal three subsections, all pulled
/// verbatim from the project's vault files:
///   - Status — Tasks.md preamble + (if present) Dashboard.md first ¶
///   - Tasks — structured `## Active` cards
///   - Notes — list of project's `.md` files, click pops out via
///             the shared `FloatingNoteWindowManager`
///
/// Phase 3 second pass (after a first pass that just dumped raw markdown
/// and made the Status section duplicate the row header). Headings are
/// downscaled, frontmatter never leaks, sub-section chevrons removed so
/// the three sections show together when a project is open.
struct VaultTabView: View {
    @EnvironmentObject var projectService: VaultProjectService
    @EnvironmentObject var ingestService: VaultIngestService
    @EnvironmentObject var vaultManager: VaultManager
    @Environment(\.fontScale) private var scale

    @State private var expandedProjects: Set<URL> = []
    @State private var showInactive: Bool = false

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider().opacity(0.3)
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 6) {
                    ForEach(activeProjects) { project in
                        ProjectRowView(
                            project: project,
                            isExpanded: expandedProjects.contains(project.id),
                            ingestService: ingestService,
                            vaultPath: vaultPath,
                            onToggle: { toggle(project.id) }
                        )
                    }
                    if !inactiveProjects.isEmpty {
                        inactiveDivider
                        if showInactive {
                            ForEach(inactiveProjects) { project in
                                ProjectRowView(
                                    project: project,
                                    isExpanded: expandedProjects.contains(project.id),
                                    ingestService: ingestService,
                                    vaultPath: vaultPath,
                                    onToggle: { toggle(project.id) }
                                )
                            }
                        }
                    }
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
            }
        }
        .onAppear {
            if projectService.vaultPath == nil, let path = vaultManager.currentVault?.path {
                projectService.start(vaultPath: URL(fileURLWithPath: path))
            } else {
                projectService.refresh()
            }
        }
    }

    private var vaultPath: URL? {
        projectService.vaultPath
            ?? vaultManager.currentVault.map { URL(fileURLWithPath: $0.path) }
    }

    private var activeProjects: [VaultProjectService.Project] {
        projectService.projects.filter { !$0.isInactive }
    }
    private var inactiveProjects: [VaultProjectService.Project] {
        projectService.projects.filter { $0.isInactive }
    }

    private var header: some View {
        HStack(spacing: 6) {
            Text("\(activeProjects.count) active")
                .font(.smallFont(scale))
                .foregroundColor(.secondary)
            if projectService.lastRefresh > .distantPast {
                Text("· refreshed \(relativeShort(projectService.lastRefresh))")
                    .font(.custom("Fira Code", size: 10 * scale))
                    .foregroundColor(.secondary.opacity(0.5))
            }
            Spacer()
            Button(action: { projectService.refresh() }) {
                Image(systemName: "arrow.clockwise")
                    .font(.system(size: 11 * scale, weight: .semibold))
                    .foregroundColor(.secondary)
            }
            .buttonStyle(.borderless)
            .hudTip("Refresh vault project list")
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 6)
        .background(Color(.textBackgroundColor).opacity(0.3))
    }

    private var inactiveDivider: some View {
        Button(action: { withAnimation(.easeInOut(duration: 0.15)) { showInactive.toggle() } }) {
            HStack(spacing: 4) {
                Image(systemName: showInactive ? "chevron.down" : "chevron.right")
                    .font(.system(size: 9 * scale, weight: .semibold))
                    .foregroundColor(.secondary.opacity(0.5))
                Text("\(inactiveProjects.count) done/archived")
                    .font(.captionFont(scale).weight(.semibold))
                    .foregroundColor(.secondary.opacity(0.7))
                    .textCase(.uppercase)
                Spacer()
            }
            .padding(.horizontal, 4)
            .padding(.top, 10)
            .padding(.bottom, 4)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .hudTip(showInactive ? "Hide done/archived" : "Show done/archived")
    }

    private func toggle(_ id: URL) {
        withAnimation(.easeInOut(duration: 0.15)) {
            if expandedProjects.contains(id) {
                expandedProjects.remove(id)
            } else {
                expandedProjects.insert(id)
            }
        }
    }

    private func relativeShort(_ date: Date) -> String {
        let secs = Date().timeIntervalSince(date)
        if secs < 60 { return "just now" }
        if secs < 3600 { return "\(Int(secs / 60))m ago" }
        if secs < 86400 { return "\(Int(secs / 3600))h ago" }
        return "\(Int(secs / 86400))d ago"
    }
}

// MARK: - Project row

private struct ProjectRowView: View {
    let project: VaultProjectService.Project
    let isExpanded: Bool
    let ingestService: VaultIngestService
    let vaultPath: URL?
    let onToggle: () -> Void
    @Environment(\.fontScale) private var scale

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            rowHeader
            if isExpanded {
                VStack(alignment: .leading, spacing: 8) {
                    SectionLabel("Status")
                    StatusSubsection(project: project)
                    Divider().opacity(0.18)
                    SectionLabel("Tasks")
                    TasksSubsection(project: project)
                    Divider().opacity(0.18)
                    SectionLabel("Notes")
                    NotesSubsection(project: project, vaultPath: vaultPath)
                }
                .padding(.leading, 20)
                .padding(.top, 6)
                .padding(.bottom, 8)
            }
        }
        .padding(.vertical, 2)
    }

    private var rowHeader: some View {
        Button(action: onToggle) {
            HStack(spacing: 6) {
                Image(systemName: isExpanded ? "chevron.down" : "chevron.right")
                    .font(.system(size: 10 * scale, weight: .semibold))
                    .foregroundColor(.secondary)
                    .frame(width: 14)
                Text(project.name)
                    .font(.smallMedium(scale))
                    .foregroundColor(.primary)
                    .lineLimit(1)
                StatusPill(status: project.status)
                if project.isStale {
                    Text("stale")
                        .font(.custom("Fira Sans", size: 10 * scale).weight(.medium))
                        .padding(.horizontal, 5)
                        .padding(.vertical, 1)
                        .background(Color.orange.opacity(0.15))
                        .foregroundColor(.orange)
                        .clipShape(Capsule())
                }
                if ingestedCount > 0 {
                    Text("\(ingestedCount)")
                        .font(.custom("Fira Code", size: 10 * scale))
                        .foregroundColor(.secondary.opacity(0.6))
                        .padding(.horizontal, 4)
                        .padding(.vertical, 1)
                        .background(RoundedRectangle(cornerRadius: 3).fill(Color.secondary.opacity(0.1)))
                }
                Spacer()
                if let updated = project.updated {
                    Text(relativeAge(updated))
                        .font(.custom("Fira Code", size: 10 * scale))
                        .foregroundColor(.secondary.opacity(0.5))
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private var ingestedCount: Int {
        ingestService.sessionStatus.values
            .filter { $0.project == project.name && $0.kind == .ingested }
            .count
    }

    private func relativeAge(_ date: Date) -> String {
        let days = Int(Date().timeIntervalSince(date) / 86400)
        if days <= 0 { return "today" }
        if days < 7 { return "\(days)d" }
        if days < 30 { return "\(days / 7)w" }
        return "\(days / 30)mo"
    }
}

// MARK: - Section label

private struct SectionLabel: View {
    let text: String
    @Environment(\.fontScale) private var scale
    init(_ text: String) { self.text = text }
    var body: some View {
        Text(text.uppercased())
            .font(.system(size: 9 * scale, weight: .semibold))
            .tracking(0.6)
            .foregroundColor(.secondary.opacity(0.55))
    }
}

// MARK: - Status pill

private struct StatusPill: View {
    let status: String
    @Environment(\.fontScale) private var scale
    var body: some View {
        Text(status)
            .font(.custom("Fira Sans", size: 10 * scale).weight(.medium))
            .padding(.horizontal, 6)
            .padding(.vertical, 1)
            .background(color.opacity(0.18))
            .foregroundColor(color)
            .clipShape(Capsule())
    }
    private var color: Color {
        switch status {
        case "active": return .blue
        case "wrapping-up": return .orange
        case "stalled": return .red
        case "done": return .gray
        case "archived": return .secondary
        default: return .gray
        }
    }
}

// MARK: - Status subsection

private struct StatusSubsection: View {
    let project: VaultProjectService.Project
    @Environment(\.fontScale) private var scale
    @State private var preamble: String? = nil
    @State private var dashboardFirstParagraph: String? = nil

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            if let preamble {
                Text(prettifyMarkdown(preamble))
                    .font(.smallFont(scale))
                    .foregroundColor(.primary)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                Text("No project description in Tasks.md.")
                    .font(.captionFont(scale))
                    .foregroundColor(.secondary.opacity(0.7))
            }
            if let dashboard = dashboardFirstParagraph, !dashboard.isEmpty {
                Text(prettifyMarkdown(dashboard))
                    .font(.captionFont(scale))
                    .foregroundColor(.secondary)
                    .italic()
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.top, 2)
            }
        }
        .task(id: project.id) {
            if let raw = try? String(contentsOf: project.tasksPath, encoding: .utf8) {
                preamble = VaultProjectService.extractPreamble(from: raw)
            } else {
                preamble = nil
            }
            if project.hasDashboard,
               let raw = try? String(contentsOf: project.dashboardPath, encoding: .utf8) {
                dashboardFirstParagraph = VaultProjectService.extractFirstParagraph(from: raw)
            } else {
                dashboardFirstParagraph = nil
            }
        }
    }
}

// MARK: - Tasks subsection

private struct TasksSubsection: View {
    let project: VaultProjectService.Project
    @Environment(\.fontScale) private var scale
    @State private var tasks: [VaultProjectService.ActiveTask] = []

    var body: some View {
        Group {
            if tasks.isEmpty {
                Text("No active tasks.")
                    .font(.captionFont(scale))
                    .foregroundColor(.secondary.opacity(0.7))
            } else {
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(Array(tasks.enumerated()), id: \.element.id) { idx, task in
                        if idx > 0 {
                            Divider().opacity(0.12)
                        }
                        TaskCardView(task: task)
                            .padding(.vertical, 4)
                    }
                }
            }
        }
        .task(id: project.id) {
            if let raw = try? String(contentsOf: project.tasksPath, encoding: .utf8) {
                tasks = VaultProjectService.parseActiveTasks(from: raw)
            } else {
                tasks = []
            }
        }
    }
}

/// One actionable item: title-only by default, like a day-planner line.
/// Click the row to reveal the body and sub-bullet titles; each sub-bullet
/// is itself a one-line row that can be expanded to show its own body.
/// Bodies are hidden by default to keep Tasks.md ## Active scannable even
/// when the underlying entries are verbose decision records.
private struct TaskCardView: View {
    let task: VaultProjectService.ActiveTask
    @Environment(\.fontScale) private var scale
    @State private var isExpanded: Bool = false
    @State private var expandedSubBullets: Set<Int> = []

    private var hasDetail: Bool {
        !task.body.isEmpty || !task.subBullets.isEmpty
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Button(action: {
                guard hasDetail else { return }
                withAnimation(.easeInOut(duration: 0.12)) { isExpanded.toggle() }
            }) {
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Group {
                        if hasDetail {
                            Image(systemName: isExpanded ? "chevron.down" : "chevron.right")
                                .font(.system(size: 9 * scale, weight: .semibold))
                                .foregroundColor(.secondary.opacity(0.6))
                        } else {
                            Color.clear
                        }
                    }
                    .frame(width: 10, alignment: .center)

                    Image(systemName: task.isDone ? "checkmark.square" : "square")
                        .font(.system(size: 12 * scale))
                        .foregroundColor(task.isDone ? .secondary : .secondary.opacity(0.5))

                    Text(prettifyMarkdown(task.title))
                        .font(.captionFont(scale).weight(.semibold))
                        .foregroundColor(task.isDone ? .secondary : .primary)
                        .strikethrough(task.isDone)
                        .fixedSize(horizontal: false, vertical: true)
                        .multilineTextAlignment(.leading)
                    Spacer(minLength: 0)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .disabled(!hasDetail)

            if isExpanded {
                VStack(alignment: .leading, spacing: 4) {
                    if !task.body.isEmpty {
                        Text(prettifyMarkdown(task.body))
                            .font(.captionFont(scale))
                            .foregroundColor(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                            .padding(.bottom, task.subBullets.isEmpty ? 0 : 2)
                    }
                    ForEach(Array(task.subBullets.enumerated()), id: \.offset) { idx, raw in
                        SubBulletRow(
                            raw: raw,
                            isExpanded: expandedSubBullets.contains(idx),
                            onToggle: {
                                withAnimation(.easeInOut(duration: 0.12)) {
                                    if expandedSubBullets.contains(idx) {
                                        expandedSubBullets.remove(idx)
                                    } else {
                                        expandedSubBullets.insert(idx)
                                    }
                                }
                            }
                        )
                    }
                }
                .padding(.leading, 28)
                .padding(.top, 2)
            }
        }
    }
}

/// A sub-bullet rendered as its own one-line row. The sub-bullet text in
/// Tasks.md typically starts with a `**Title**: body` pattern (the user's
/// own one-liner); we extract the bold portion as the title and hide the
/// body behind a click, same idiom as the parent task.
private struct SubBulletRow: View {
    let raw: String
    let isExpanded: Bool
    let onToggle: () -> Void
    @Environment(\.fontScale) private var scale

    private struct Parsed {
        let title: String
        let body: String
        let isDone: Bool
    }

    private var parsed: Parsed {
        let isDone = raw.contains("✅") || raw.contains(" DONE")
        let ns = raw as NSString
        let pattern = try? NSRegularExpression(pattern: #"^\*\*(.+?)\*\*:?\s*(.*)$"#)
        if let m = pattern?.firstMatch(in: raw, range: NSRange(location: 0, length: ns.length)),
           m.numberOfRanges >= 3 {
            let title = ns.substring(with: m.range(at: 1)).trimmingCharacters(in: .whitespaces)
            let body = ns.substring(with: m.range(at: 2)).trimmingCharacters(in: .whitespaces)
            return Parsed(title: title, body: body, isDone: isDone)
        }
        return Parsed(title: raw, body: "", isDone: isDone)
    }

    var body: some View {
        let p = parsed
        let canExpand = !p.body.isEmpty
        VStack(alignment: .leading, spacing: 2) {
            Button(action: {
                guard canExpand else { return }
                onToggle()
            }) {
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Group {
                        if canExpand {
                            Image(systemName: isExpanded ? "chevron.down" : "chevron.right")
                                .font(.system(size: 8 * scale, weight: .semibold))
                                .foregroundColor(.secondary.opacity(0.5))
                        } else {
                            Color.clear
                        }
                    }
                    .frame(width: 8, alignment: .center)

                    Image(systemName: p.isDone ? "checkmark.square" : "square")
                        .font(.system(size: 10 * scale))
                        .foregroundColor(p.isDone ? .secondary.opacity(0.7) : .secondary.opacity(0.4))

                    Text(prettifyMarkdown(p.title))
                        .font(.captionFont(scale))
                        .foregroundColor(p.isDone ? .secondary.opacity(0.7) : .secondary)
                        .strikethrough(p.isDone)
                        .fixedSize(horizontal: false, vertical: true)
                        .multilineTextAlignment(.leading)
                    Spacer(minLength: 0)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .disabled(!canExpand)

            if isExpanded && canExpand {
                Text(prettifyMarkdown(p.body))
                    .font(.captionFont(scale))
                    .foregroundColor(.secondary.opacity(0.7))
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.leading, 22)
            }
        }
    }
}

// MARK: - Notes subsection

private struct NotesSubsection: View {
    let project: VaultProjectService.Project
    let vaultPath: URL?
    @Environment(\.fontScale) private var scale

    var body: some View {
        let files = orderedNoteFiles
        if files.isEmpty {
            Text("No notes in project folder.")
                .font(.captionFont(scale))
                .foregroundColor(.secondary.opacity(0.7))
        } else {
            VStack(alignment: .leading, spacing: 1) {
                ForEach(files, id: \.self) { url in
                    NoteFileRow(url: url, project: project, vaultPath: vaultPath)
                }
            }
        }
    }

    /// Dashboard, Technical Notes, Session Log, Sessions, then any other
    /// `.md` files in the folder alphabetically. Tasks.md is excluded
    /// (it's the Tasks section above).
    private var orderedNoteFiles: [URL] {
        var out: [URL] = []
        let fm = FileManager.default
        for path in [project.dashboardPath, project.technicalNotesPath,
                     project.sessionLogPath, project.sessionsPath] {
            if fm.fileExists(atPath: path.path) { out.append(path) }
        }
        out.append(contentsOf: project.otherMarkdownFiles)
        return out
    }
}

private struct NoteFileRow: View {
    let url: URL
    let project: VaultProjectService.Project
    let vaultPath: URL?
    @Environment(\.fontScale) private var scale
    @State private var isHovered = false

    var body: some View {
        Button(action: openInFloatingWindow) {
            HStack(spacing: 6) {
                Image(systemName: "doc.text")
                    .font(.system(size: 10 * scale))
                    .foregroundColor(.secondary.opacity(0.5))
                Text(url.deletingPathExtension().lastPathComponent)
                    .font(isHovered ? .smallMedium(scale) : .smallFont(scale))
                    .foregroundColor(isHovered ? .primary : .secondary)
                Spacer()
                if let age = modifiedAge {
                    Text(age)
                        .font(.custom("Fira Code", size: 10 * scale))
                        .foregroundColor(.secondary.opacity(0.5))
                }
            }
            .padding(.vertical, 3)
            .padding(.horizontal, 4)
            .background(isHovered ? Color.primary.opacity(0.05) : Color.clear)
            .clipShape(RoundedRectangle(cornerRadius: 4))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { isHovered = $0 }
        .hudTip("Open in pop-out window")
    }

    private var modifiedAge: String? {
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: url.path),
              let date = attrs[.modificationDate] as? Date else { return nil }
        let days = Int(Date().timeIntervalSince(date) / 86400)
        if days <= 0 { return "today" }
        if days < 7 { return "\(days)d" }
        if days < 30 { return "\(days / 7)w" }
        return "\(days / 30)mo"
    }

    private func openInFloatingWindow() {
        // Build the same NoteFile shape the Obsidian browser uses so the
        // floating window's wikilink + image resolution all work.
        let attrs = try? FileManager.default.attributesOfItem(atPath: url.path)
        let modDate = attrs?[.modificationDate] as? Date
        let relativePath: String
        if let vault = vaultPath, url.path.hasPrefix(vault.path) {
            relativePath = String(url.path.dropFirst(vault.path.count + 1))
        } else {
            relativePath = "\(project.name)/\(url.lastPathComponent)"
        }
        let file = NoteFile(
            name: url.lastPathComponent,
            path: url.path,
            relativePath: relativePath,
            isDirectory: false,
            modificationDate: modDate,
            children: nil
        )
        FloatingNoteWindowManager.shared.openWindow(for: file)
    }
}

// MARK: - Inline-markdown helper

/// Strip Obsidian wikilink brackets so `[[X]]` / `[[X|Display]]` render
/// as plain text (or display text), and pass the result back as a
/// LocalizedStringKey so SwiftUI's built-in markdown parser handles
/// inline `**bold**`, `_italic_`, and `` `code` ``.
private func prettifyMarkdown(_ s: String) -> LocalizedStringKey {
    var out = s
    // `[[X|Display]]` → `Display`
    out = out.replacingOccurrences(
        of: #"\[\[([^\]|]+)\|([^\]]+)\]\]"#,
        with: "$2",
        options: .regularExpression
    )
    // `[[X]]` → `X`
    out = out.replacingOccurrences(
        of: #"\[\[([^\]]+)\]\]"#,
        with: "$1",
        options: .regularExpression
    )
    return LocalizedStringKey(out)
}
