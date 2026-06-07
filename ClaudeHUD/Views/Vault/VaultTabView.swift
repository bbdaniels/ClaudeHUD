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
    @State private var collapsedSections: Set<String> = []
    @State private var searchText = ""

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider().opacity(0.3)
            ScrollView {
                // NOTE: must be a plain VStack, NOT LazyVStack. The rows have
                // wildly variable heights (a collapsed row is one line; an
                // expanded row renders Status + Tasks + Notes). Inside a
                // ScrollView, LazyVStack estimates content height from realized
                // rows, and with heights this variable the estimate oscillates:
                // ScrollView.sizeThatFits ↔ LazySubviewPlacements.placeSubviews
                // re-trigger each other every runloop pass and never converge,
                // pinning the main thread at 100% (the Projects-tab pinwheel,
                // confirmed via `sample`). A non-lazy VStack gives the ScrollView
                // a deterministic content height. The list is only tens of rows
                // and collapsed rows are cheap headers, so eager layout is fine.
                VStack(alignment: .leading, spacing: 0) {
                    let sections = recencySections
                    if sections.isEmpty {
                        Text(searchText.isEmpty ? "No projects." : "No matches")
                            .font(.smallFont(scale))
                            .foregroundColor(.secondary)
                            .frame(maxWidth: .infinity)
                            .padding(.top, 40)
                    } else {
                        ForEach(sections, id: \.title) { section in
                            sectionHeader(
                                title: section.title,
                                count: section.projects.count,
                                collapsed: collapsedSections.contains(section.title),
                                onToggle: { toggleSection(section.title) }
                            )
                            if !collapsedSections.contains(section.title) {
                                ForEach(section.projects) { project in
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
                }
                .padding(.horizontal, 10)
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

    /// Projects matching the search box (name or status text). An empty
    /// query returns everything.
    private var filteredProjects: [VaultProjectService.Project] {
        let q = searchText.trimmingCharacters(in: .whitespaces).lowercased()
        guard !q.isEmpty else { return projectService.projects }
        return projectService.projects.filter {
            $0.name.lowercased().contains(q) || $0.status.lowercased().contains(q)
        }
    }

    /// Projects partitioned by recency of their `updated:` date — "when to
    /// pick up" — mirroring Session History's time sections. `updated:` is
    /// bumped whenever a session edits the project's Tasks.md (per the
    /// task-management workflow) and kept in sync by the cleaner, so these
    /// buckets re-sort themselves with no manual tagging.
    private var recencySections: [(title: String, projects: [VaultProjectService.Project])] {
        let cal = Calendar.current
        let startOfToday = cal.startOfDay(for: Date())
        let startOfWeek = cal.date(byAdding: .day, value: -7, to: startOfToday)!
        let startOfMonth = cal.date(byAdding: .day, value: -30, to: startOfToday)!

        func rank(_ p: VaultProjectService.Project) -> Int {
            let d = p.updated ?? .distantPast
            if d >= startOfToday { return 0 }
            if d >= startOfWeek { return 1 }
            if d >= startOfMonth { return 2 }
            return 3
        }
        let titles = ["Today", "This Week", "This Month", "Older"]
        let fp = filteredProjects
        var out: [(title: String, projects: [VaultProjectService.Project])] = []
        for (idx, title) in titles.enumerated() {
            let group = fp.filter { rank($0) == idx }
                          .sorted { ($0.updated ?? .distantPast) > ($1.updated ?? .distantPast) }
            if !group.isEmpty { out.append((title: title, projects: group)) }
        }
        return out
    }

    private var header: some View {
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 11 * scale))
                .foregroundColor(.secondary)
            TextField("Search projects...", text: $searchText)
                .font(.smallFont(scale))
                .textFieldStyle(.plain)
            if !searchText.isEmpty {
                Button(action: { searchText = "" }) {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 11 * scale))
                        .foregroundColor(.secondary)
                }
                .buttonStyle(.borderless)
                .hudTip("Clear search")
            }
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

    /// Collapsible recency-section header — mirrors Session History's
    /// `TimeSectionView` header (chevron · uppercase title · count badge).
    private func sectionHeader(title: String, count: Int, collapsed: Bool,
                               onToggle: @escaping () -> Void) -> some View {
        Button(action: onToggle) {
            HStack(spacing: 4) {
                Image(systemName: collapsed ? "chevron.right" : "chevron.down")
                    .font(.system(size: 9 * scale, weight: .semibold))
                    .foregroundColor(.secondary.opacity(0.5))
                Text(title)
                    .font(.captionFont(scale).weight(.semibold))
                    .foregroundColor(.secondary.opacity(0.7))
                    .textCase(.uppercase)
                Text("\(count)")
                    .font(.custom("Fira Code", size: 10 * scale))
                    .foregroundColor(.secondary.opacity(0.6))
                    .padding(.horizontal, 4)
                    .padding(.vertical, 1)
                    .background(RoundedRectangle(cornerRadius: 3).fill(Color.secondary.opacity(0.1)))
                Spacer()
            }
            .padding(.horizontal, 4)
            .padding(.top, 10)
            .padding(.bottom, 4)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .hudTip(collapsed ? "Expand section" : "Collapse section")
    }

    private func toggleSection(_ title: String) {
        withAnimation(.easeInOut(duration: 0.15)) {
            if collapsedSections.contains(title) { collapsedSections.remove(title) }
            else { collapsedSections.insert(title) }
        }
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
                    // StatusSubsection owns its own section label because
                    // the label is conditional on what the project has:
                    // "Status" when Dashboard.md has a `## Current Status`
                    // block (real status, populated by Phase 7 cleaner
                    // enrichment), otherwise "About" with the Tasks.md
                    // preamble. Tasks and Notes follow the parent-owns-
                    // label pattern; Status is the deliberate exception.
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
            // Match Session History's project-row rhythm: 8pt vertical
            // padding on the compact line, flush rows (VStack spacing 0).
            .padding(.vertical, 8)
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

/// Renders either a real "Status" block (when `Dashboard.md` has a
/// `## Current Status` section, populated by Phase 7 cleaner enrichment)
/// or falls back to an "About" block built from the `Tasks.md` preamble
/// + `Dashboard.md` first paragraph. The subsection owns its own
/// `SectionLabel` because the label is conditional on the content; the
/// other two subsections (Tasks, Notes) keep the parent-owns-label
/// pattern.
private struct StatusSubsection: View {
    let project: VaultProjectService.Project
    @Environment(\.fontScale) private var scale
    @State private var currentStatus: String? = nil
    @State private var preamble: String? = nil
    @State private var dashboardFirstParagraph: String? = nil

    private var hasRealStatus: Bool {
        !(currentStatus ?? "").isEmpty
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            SectionLabel(hasRealStatus ? "Status" : "About")
            if hasRealStatus {
                Text(prettifyMarkdown(currentStatus!))
                    .font(.smallFont(scale))
                    .foregroundColor(.primary)
                    .fixedSize(horizontal: false, vertical: true)
            } else if let preamble {
                Text(prettifyMarkdown(preamble))
                    .font(.smallFont(scale))
                    .foregroundColor(.primary)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                Text("No project description in Tasks.md.")
                    .font(.captionFont(scale))
                    .foregroundColor(.secondary.opacity(0.7))
            }
            // Dashboard first paragraph is a secondary signal in both
            // modes — under Status, it's flavor context; under About,
            // it's the dashboard intro.
            if let dashboard = dashboardFirstParagraph, !dashboard.isEmpty,
               dashboard != currentStatus {
                Text(prettifyMarkdown(dashboard))
                    .font(.captionFont(scale))
                    .foregroundColor(.secondary)
                    .italic()
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.top, 2)
            }
        }
        .task(id: project.id) {
            // Dashboard.md ## Current Status — real status when present.
            // Reader contract (Phase 7 cleaner enrichment populates this).
            if project.hasDashboard,
               let raw = try? String(contentsOf: project.dashboardPath, encoding: .utf8) {
                currentStatus = VaultProjectService.extractSection(named: "Current Status", from: raw)
                dashboardFirstParagraph = VaultProjectService.extractFirstParagraph(from: raw)
            } else {
                currentStatus = nil
                dashboardFirstParagraph = nil
            }
            // Tasks.md preamble — "About" fallback when no real status.
            if let raw = try? String(contentsOf: project.tasksPath, encoding: .utf8) {
                preamble = VaultProjectService.extractPreamble(from: raw)
            } else {
                preamble = nil
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

                    if task.isHeading {
                        // Section header: no checkbox, never struck; a
                        // subtle done/total tallies its checkbox children.
                        Text(prettifyMarkdown(task.title))
                            .font(.captionFont(scale).weight(.bold))
                            .foregroundColor(.primary)
                            .fixedSize(horizontal: false, vertical: true)
                            .multilineTextAlignment(.leading)
                        if childTotal > 0 {
                            Text("\(childDone)/\(childTotal)")
                                .font(.custom("Fira Code", size: 9 * scale))
                                .foregroundColor(.secondary.opacity(0.55))
                        }
                    } else {
                        Image(systemName: task.isDone ? "checkmark.square" : "square")
                            .font(.system(size: 12 * scale))
                            .foregroundColor(task.isDone ? .secondary : .secondary.opacity(0.5))

                        Text(prettifyMarkdown(task.title))
                            .font(.captionFont(scale).weight(.semibold))
                            .foregroundColor(task.isDone ? .secondary : .primary)
                            .strikethrough(task.isDone)
                            .fixedSize(horizontal: false, vertical: true)
                            .multilineTextAlignment(.leading)
                    }
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
                    ForEach(Array(task.subBullets.enumerated()), id: \.offset) { idx, bullet in
                        SubBulletRow(
                            bullet: bullet,
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
                .padding(.leading, task.isHeading ? 16 : 28)
                .padding(.top, 2)
            }
        }
    }

    private var childTotal: Int { task.subBullets.count }
    private var childDone: Int { task.subBullets.filter { $0.isDone }.count }
}

/// A sub-bullet rendered as its own one-line row. The sub-bullet text in
/// Tasks.md typically starts with a `**Title**: body` pattern (the user's
/// own one-liner); we extract the bold portion as the title and hide the
/// body behind a click, same idiom as the parent task.
private struct SubBulletRow: View {
    let bullet: VaultProjectService.SubBullet
    let isExpanded: Bool
    let onToggle: () -> Void
    @Environment(\.fontScale) private var scale

    private struct Parsed {
        let title: String
        let body: String
    }

    private var parsed: Parsed {
        let split = VaultProjectService.splitBullet(bullet.text)
        return Parsed(title: split.title, body: split.body)
    }

    var body: some View {
        let p = parsed
        let isDone = bullet.isDone
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

                    Image(systemName: isDone ? "checkmark.square" : "square")
                        .font(.system(size: 10 * scale))
                        .foregroundColor(isDone ? .secondary.opacity(0.7) : .secondary.opacity(0.4))

                    Text(prettifyMarkdown(p.title))
                        .font(.captionFont(scale))
                        .foregroundColor(isDone ? .secondary.opacity(0.7) : .secondary)
                        .strikethrough(isDone)
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

// MARK: - Vault cockpit (Phase 5) — NO LONGER RENDERED

/// Ingest queue, sync status, settings. **Removed from the Projects tab
/// 2026-06-07** (the tab is now a clean project list matching Session
/// History). Kept inert — same "instantiated-but-unused, re-enable later"
/// pattern as `ProjectBriefingService` — in case it returns as a dedicated
/// Settings surface. The ingest/sync recovery actions it exposed remain
/// available via the scripts (`obsidian-sync.sh`, `vault-ingest.sh`).
/// Cleaner trigger (5b) was always deferred (needs GitHub PAT wiring).
private struct VaultCockpitView: View {
    @EnvironmentObject var ingestService: VaultIngestService
    @EnvironmentObject var scriptInstaller: VaultScriptInstaller
    @Environment(\.fontScale) private var scale
    @State private var expanded: Set<String> = []

    /// True when any installed managed script is `userEdited` or
    /// `unmanagedDifferentBody` — needs the Force overwrite button.
    private var hasInstallConflict: Bool {
        scriptInstaller.lastAudit.values.contains { status in
            switch status {
            case .userEdited, .unmanagedDifferentBody: return true
            default: return false
            }
        }
    }

    /// The cockpit stays hidden while healthy and appears only when
    /// there's something to ACT on: a failed sync, failed ingest items,
    /// or a paused queue. A deep-but-draining pending queue is normal
    /// (backfill works it off on a timer) and deliberately does NOT
    /// surface the panel — otherwise the structural backlog would keep
    /// it on permanently. Script "needs attention" is also not a trigger.
    private var hasProblem: Bool {
        let q = ingestService.queue
        if case .failed = ingestService.sync.lastResult { return true }
        if q.failed.count > 0 { return true }
        if q.paused { return true }
        return false
    }

    var body: some View {
        // Hidden while healthy; only renders when `hasProblem` is true.
        if hasProblem {
            VStack(alignment: .leading, spacing: 8) {
                cockpitHeader

                CockpitSection(
                    title: "Ingest",
                    summary: ingestSummary,
                    isExpanded: expanded.contains("ingest"),
                    onToggle: { toggle("ingest") },
                    content: { ingestQueueBody }
                )

                CockpitSection(
                    title: "Sync",
                    summary: syncSummary,
                    isExpanded: expanded.contains("sync"),
                    onToggle: { toggle("sync") },
                    content: { syncStatusBody }
                )

                CockpitSection(
                    title: "Settings",
                    summary: settingsSummary,
                    isExpanded: expanded.contains("settings"),
                    onToggle: { toggle("settings") },
                    content: { settingsBody }
                )
            }
            .padding(.top, 12)
        }
    }

    // MARK: Header

    private var cockpitHeader: some View {
        HStack(spacing: 6) {
            Text("Cockpit")
                .font(.captionFont(scale).weight(.semibold))
                .foregroundColor(.secondary.opacity(0.7))
                .textCase(.uppercase)
                .tracking(0.6)
            if ingestService.queue.paused {
                Text("paused")
                    .font(.custom("Fira Sans", size: 9 * scale).weight(.medium))
                    .padding(.horizontal, 5)
                    .padding(.vertical, 1)
                    .background(Color.orange.opacity(0.18))
                    .foregroundColor(.orange)
                    .clipShape(Capsule())
            }
            Spacer()
            Button(action: { ingestService.refresh() }) {
                Image(systemName: "arrow.clockwise")
                    .font(.system(size: 10 * scale, weight: .semibold))
                    .foregroundColor(.secondary)
            }
            .buttonStyle(.borderless)
            .hudTip("Refresh cockpit state")
        }
        .padding(.horizontal, 4)
    }

    // MARK: Summaries (collapsed-row right-hand text)

    private var ingestSummary: String {
        let q = ingestService.queue
        var parts: [String] = []
        if q.pending.count > 0 { parts.append("\(q.pending.count) pending") }
        if q.failed.count > 0 { parts.append("\(q.failed.count) failed") }
        if parts.isEmpty { parts.append("clear · \(q.doneLifetimeCount) ingested") }
        return parts.joined(separator: " · ")
    }

    private var syncSummary: String {
        let s = ingestService.sync
        switch s.lastResult {
        case .ok:
            if let end = s.lastEnd { return "ok · \(relativeShort(end))" }
            return "ok"
        case .failed:
            if let end = s.lastEnd ?? s.lastStart { return "failed · \(relativeShort(end))" }
            return "failed"
        case .unknown:
            return "no log yet"
        }
    }

    private var settingsSummary: String {
        let installerLines = scriptInstaller.lastAudit.values
        let needsAttention = installerLines.contains(where: {
            if case .userEdited = $0 { return true }
            if case .unmanagedDifferentBody = $0 { return true }
            if case .outdated = $0 { return true }
            return false
        })
        return needsAttention ? "scripts need attention" : "scripts current"
    }

    // MARK: Ingest section

    private var ingestQueueBody: some View {
        VStack(alignment: .leading, spacing: 6) {
            if !ingestService.queue.pending.isEmpty {
                cockpitMiniHeader("Pending (\(ingestService.queue.pending.count))")
                ForEach(ingestService.queue.pending.prefix(8)) { p in
                    pendingRow(p)
                }
                if ingestService.queue.pending.count > 8 {
                    Text("+ \(ingestService.queue.pending.count - 8) more")
                        .font(.captionFont(scale))
                        .foregroundColor(.secondary.opacity(0.5))
                        .padding(.leading, 4)
                }
                HStack(spacing: 8) {
                    cockpitButton("Process 10", system: "play.rectangle") {
                        ingestService.runBacklog(limit: 10)
                    }
                    if ingestService.queue.pending.count > 10 {
                        cockpitButton("Process 50", system: "play.rectangle.fill") {
                            ingestService.runBacklog(limit: 50)
                        }
                    }
                }
                .padding(.top, 2)
            }
            if !ingestService.queue.failed.isEmpty {
                cockpitMiniHeader("Failed (\(ingestService.queue.failed.count))")
                ForEach(ingestService.queue.failed) { f in
                    failedRow(f)
                }
                HStack(spacing: 8) {
                    cockpitButton("Retry all", system: "arrow.counterclockwise") {
                        ingestService.retryAllFailed()
                    }
                    cockpitButton("Run ingest now", system: "play.fill") {
                        ingestService.triggerIngestNow()
                    }
                }
                .padding(.top, 2)
            }
            if ingestService.queue.pending.isEmpty && ingestService.queue.failed.isEmpty {
                Text("Queue clear. \(ingestService.queue.doneLifetimeCount) sessions ingested lifetime.")
                    .font(.captionFont(scale))
                    .foregroundColor(.secondary.opacity(0.7))
            }
        }
    }

    private func pendingRow(_ p: VaultIngestService.PendingTranscript) -> some View {
        HStack(spacing: 6) {
            Text(String(p.sessionID.prefix(8)))
                .font(.custom("Fira Code", size: 10 * scale))
                .foregroundColor(.secondary.opacity(0.7))
            Text(byteString(p.bytes))
                .font(.custom("Fira Code", size: 10 * scale))
                .foregroundColor(.secondary.opacity(0.5))
            Spacer()
            Text(relativeShort(p.mtime))
                .font(.custom("Fira Code", size: 10 * scale))
                .foregroundColor(.secondary.opacity(0.5))
            Button(action: {
                NSWorkspace.shared.activateFileViewerSelecting([p.path])
            }) {
                Image(systemName: "doc.text.magnifyingglass")
                    .font(.system(size: 10 * scale))
                    .foregroundColor(.secondary)
            }
            .buttonStyle(.borderless)
            .hudTip("Reveal transcript")
        }
        .padding(.horizontal, 4)
    }

    private func failedRow(_ f: VaultIngestService.FailedMarker) -> some View {
        HStack(spacing: 6) {
            Image(systemName: "xmark.circle.fill")
                .font(.system(size: 10 * scale))
                .foregroundColor(.red)
            Text(String(f.sessionID.prefix(8)))
                .font(.custom("Fira Code", size: 10 * scale))
                .foregroundColor(.secondary.opacity(0.7))
            Text(byteString(f.bytes))
                .font(.custom("Fira Code", size: 10 * scale))
                .foregroundColor(.secondary.opacity(0.5))
            Spacer()
            Text(relativeShort(f.mtime))
                .font(.custom("Fira Code", size: 10 * scale))
                .foregroundColor(.secondary.opacity(0.5))
            Button(action: { ingestService.retryFailed(f) }) {
                Image(systemName: "arrow.counterclockwise")
                    .font(.system(size: 10 * scale, weight: .semibold))
                    .foregroundColor(.accentColor)
            }
            .buttonStyle(.borderless)
            .hudTip("Clear .failed marker so next SessionEnd retries")
        }
        .padding(.horizontal, 4)
    }

    // MARK: Sync section

    private var syncStatusBody: some View {
        VStack(alignment: .leading, spacing: 6) {
            let s = ingestService.sync
            if let end = s.lastEnd {
                cockpitKeyValue(key: "Last sync end", value: absoluteTime(end))
            } else {
                cockpitKeyValue(key: "Last sync end", value: "—")
            }
            if let start = s.lastStart {
                cockpitKeyValue(key: "Last sync start", value: absoluteTime(start))
            }
            cockpitKeyValue(key: "Result", value: s.lastResult.rawValue)
            if let err = s.lastError {
                Text(err)
                    .font(.captionFont(scale))
                    .foregroundColor(.red.opacity(0.8))
                    .lineLimit(3)
                    .padding(.top, 2)
            }
            HStack(spacing: 8) {
                cockpitButton("Sync now", system: "arrow.triangle.2.circlepath") {
                    ingestService.triggerSync()
                }
                cockpitButton("Open log", system: "doc.text") {
                    let log = FileManager.default.homeDirectoryForCurrentUser
                        .appending(path: "Library/Logs/obsidian-sync.log")
                    NSWorkspace.shared.activateFileViewerSelecting([log])
                }
            }
            .padding(.top, 2)
        }
    }

    // MARK: Settings section

    private var settingsBody: some View {
        VStack(alignment: .leading, spacing: 8) {
            // Paused toggle
            HStack(spacing: 6) {
                Toggle(isOn: Binding(
                    get: { ingestService.queue.paused },
                    set: { ingestService.setPaused($0) }
                )) {
                    Text("Pause ingest")
                        .font(.captionFont(scale))
                        .foregroundColor(.primary)
                }
                .toggleStyle(.switch)
                .controlSize(.mini)
                Spacer()
            }
            .padding(.horizontal, 4)

            // Script installer status — iterate the canonical list so
            // order is stable (dictionary keys are not).
            cockpitMiniHeader("Managed scripts (\(VaultScriptInstaller.managed.count))")
            ForEach(VaultScriptInstaller.managed, id: \.self) { script in
                installerRow(script)
            }

            HStack(spacing: 8) {
                cockpitButton("Reveal in Finder", system: "folder") {
                    ingestService.revealScriptsInFinder()
                }
                cockpitButton("Reinstall managed", system: "arrow.down.doc") {
                    try? scriptInstaller.install(force: false)
                    _ = scriptInstaller.audit()
                    ingestService.refresh()
                }
            }
            .padding(.top, 2)

            // Force button surfaces whenever any installed script is
            // in conflict (`userEdited` or `unmanagedDifferentBody`) —
            // no `pendingReinstall` gating, because the user can see
            // the per-script pills above and may want to force-overwrite
            // without clicking Reinstall first.
            if hasInstallConflict {
                cockpitButton("Force overwrite (clobbers local edits)",
                              system: "exclamationmark.triangle.fill") {
                    try? scriptInstaller.install(force: true)
                    _ = scriptInstaller.audit()
                    ingestService.refresh()
                }
                .padding(.top, 2)
            }
        }
    }

    private func installerRow(_ script: VaultScriptInstaller.ManagedScript) -> some View {
        let status = scriptInstaller.lastAudit[script]
        return HStack(spacing: 6) {
            Text(script.bundleResource)
                .font(.custom("Fira Code", size: 10 * scale))
                .foregroundColor(.secondary.opacity(0.85))
                .lineLimit(1)
            Spacer()
            installerStatusBadge(status)
        }
        .padding(.horizontal, 4)
    }

    @ViewBuilder
    private func installerStatusBadge(_ status: VaultScriptInstaller.Status?) -> some View {
        let (label, color): (String, Color) = {
            switch status {
            case .current: return ("current", .secondary.opacity(0.55))
            case .missing: return ("missing", .orange)
            case .outdated: return ("outdated", .orange)
            case .userEdited: return ("user-edited", .yellow)
            case .unmanagedSameBody: return ("ready", .blue)
            case .unmanagedDifferentBody: return ("conflict", .red)
            case .none: return ("?", .secondary)
            }
        }()
        Text(label)
            .font(.custom("Fira Sans", size: 9 * scale).weight(.medium))
            .padding(.horizontal, 5)
            .padding(.vertical, 1)
            .background(color.opacity(0.15))
            .foregroundColor(color)
            .clipShape(Capsule())
    }

    // MARK: Helpers

    private func toggle(_ id: String) {
        withAnimation(.easeInOut(duration: 0.12)) {
            if expanded.contains(id) { expanded.remove(id) } else { expanded.insert(id) }
        }
    }

    private func cockpitMiniHeader(_ s: String) -> some View {
        Text(s.uppercased())
            .font(.system(size: 9 * scale, weight: .semibold))
            .tracking(0.5)
            .foregroundColor(.secondary.opacity(0.55))
            .padding(.horizontal, 4)
    }

    private func cockpitKeyValue(key: String, value: String) -> some View {
        HStack(spacing: 6) {
            Text(key)
                .font(.captionFont(scale))
                .foregroundColor(.secondary.opacity(0.7))
            Spacer()
            Text(value)
                .font(.custom("Fira Code", size: 10 * scale))
                .foregroundColor(.secondary)
        }
        .padding(.horizontal, 4)
    }

    private func cockpitButton(_ label: String, system: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 4) {
                Image(systemName: system)
                    .font(.system(size: 9 * scale, weight: .semibold))
                Text(label)
                    .font(.custom("Fira Sans", size: 10 * scale).weight(.medium))
            }
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(RoundedRectangle(cornerRadius: 4).fill(Color.secondary.opacity(0.12)))
            .foregroundColor(.primary)
        }
        .buttonStyle(.plain)
    }

    private func relativeShort(_ date: Date) -> String {
        let secs = Date().timeIntervalSince(date)
        if secs < 60 { return "just now" }
        if secs < 3600 { return "\(Int(secs / 60))m ago" }
        if secs < 86400 { return "\(Int(secs / 3600))h ago" }
        return "\(Int(secs / 86400))d ago"
    }

    private func absoluteTime(_ date: Date) -> String {
        let fmt = DateFormatter()
        fmt.dateFormat = "MMM d, h:mma"
        return fmt.string(from: date)
    }

    private func byteString(_ bytes: Int) -> String {
        let kb = Double(bytes) / 1024.0
        if kb < 1024 { return String(format: "%.0f KB", kb) }
        return String(format: "%.1f MB", kb / 1024.0)
    }
}

private struct CockpitSection<Content: View>: View {
    let title: String
    let summary: String
    let isExpanded: Bool
    let onToggle: () -> Void
    @ViewBuilder let content: () -> Content
    @Environment(\.fontScale) private var scale

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Button(action: onToggle) {
                HStack(spacing: 6) {
                    Image(systemName: isExpanded ? "chevron.down" : "chevron.right")
                        .font(.system(size: 9 * scale, weight: .semibold))
                        .foregroundColor(.secondary.opacity(0.5))
                        .frame(width: 10)
                    Text(title.uppercased())
                        .font(.system(size: 10 * scale, weight: .semibold))
                        .tracking(0.5)
                        .foregroundColor(.secondary.opacity(0.75))
                    Spacer()
                    Text(summary)
                        .font(.custom("Fira Code", size: 10 * scale))
                        .foregroundColor(.secondary.opacity(0.55))
                        .lineLimit(1)
                }
                .contentShape(Rectangle())
                .padding(.vertical, 2)
            }
            .buttonStyle(.plain)

            if isExpanded {
                content()
                    .padding(.leading, 12)
                    .padding(.bottom, 4)
            }
        }
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
