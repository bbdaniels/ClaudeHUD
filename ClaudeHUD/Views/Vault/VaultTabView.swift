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
    // Harvested-spine sources (Phase 1): the WORK section needs sessions +
    // live agents; People/Meetings/Emails + Briefing bridge to the cross
    // ProjectService by folder name. Warmed in `.onAppear` so an expanded
    // row renders without a cold wait. All read-only / idempotent.
    @EnvironmentObject var sessionHistory: SessionHistoryService
    @EnvironmentObject var agentsService: AgentsService
    @EnvironmentObject var crossProjectService: ProjectService
    @Environment(\.fontScale) private var scale

    @State private var expandedProjects: Set<URL> = []
    @State private var collapsedSections: Set<String> = []
    @State private var searchText = ""
    /// folder name → most-recent session timestamp for that project (resolved
    /// via the canonical cwds: resolver). Drives "real activity" recency so a
    /// project that's busy in sessions but whose `updated:` went stale still
    /// sorts as recent. Primed off-main in `.task`.
    @State private var folderLatestSession: [String: Date] = [:]

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
                                        effectiveDate: effectiveUpdated(project),
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
            // Warm the harvested-spine sources so an expanded row's WORK +
            // People/Meetings/Emails render without a cold wait. Idempotent:
            // `start()` no-ops if already polling, `refresh()` is cheap, and
            // sessions only reload when not already present.
            agentsService.start()
            crossProjectService.refresh()
            if sessionHistory.sessions.isEmpty {
                Task { await sessionHistory.refresh() }
            }
        }
        // Build folder → latest-session-timestamp so recency reflects real
        // activity, not just `updated:`. Primes the canonical resolver cache
        // off-main; re-runs when the session set changes. Read-only.
        .task(id: sessionHistory.sessions.count) {
            let sessions = sessionHistory.sessions
            guard !sessions.isEmpty else { return }
            await projectService.primeResolution(forCwds: Set(sessions.map { $0.projectPath }))
            var map: [String: Date] = [:]
            for s in sessions {
                guard let folder = projectService.folderName(forCwd: s.projectPath) else { continue }
                if let cur = map[folder], cur >= s.timestamp { continue }
                map[folder] = s.timestamp
            }
            folderLatestSession = map
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

    /// "When to pick up" recency, by REAL activity — `max(updated:, latest
    /// session in the project)`. `updated:` alone goes stale (it's only bumped
    /// when a session edits Tasks.md), so a project that's busy in sessions but
    /// whose `updated:` lagged (e.g. Cayda) would wrongly sink to "Older." The
    /// latest-session signal (resolved via the canonical cwds: resolver, primed
    /// in `.task`) floats it back up. Mirrors Session History's time sections.
    private func effectiveUpdated(_ p: VaultProjectService.Project) -> Date {
        max(p.updated ?? .distantPast, folderLatestSession[p.name] ?? .distantPast)
    }

    private var recencySections: [(title: String, projects: [VaultProjectService.Project])] {
        let cal = Calendar.current
        let startOfToday = cal.startOfDay(for: Date())
        let startOfWeek = cal.date(byAdding: .day, value: -7, to: startOfToday)!
        let startOfMonth = cal.date(byAdding: .day, value: -30, to: startOfToday)!

        func rank(_ p: VaultProjectService.Project) -> Int {
            let d = effectiveUpdated(p)
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
                          .sorted { effectiveUpdated($0) > effectiveUpdated($1) }
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
    /// max(updated:, latest session) — the recency the row is bucketed by.
    let effectiveDate: Date
    let onToggle: () -> Void
    @Environment(\.fontScale) private var scale
    @EnvironmentObject private var slack: SlackService
    @EnvironmentObject private var terminalService: TerminalService
    @State private var slackHovering = false
    @State private var launchHovering = false
    @State private var launched = false

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
                    // WORK — this project's sessions + live agents + Launch +
                    // resume/Safe-Unsafe/effort, keyed by the canonical cwds:
                    // resolver. Owns its own "Work" label (controls share the
                    // header line). Tasks stay READ-ONLY in Projects (Phase 1).
                    WorkSubsection(project: project)
                    // People / Meetings / Emails — harvested from the cross
                    // ProjectService intel, bridged by folder name; self-hides
                    // (incl. its leading divider) when there's nothing to show.
                    ProjectIntelSubsection(project: project)
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
        // Not a Button: the row toggles via onTapGesture so the trailing
        // "Open in Slack" Button wins the hit-test on its own bounds (a Button
        // nested inside the row's Button would otherwise be ambiguous).
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
            if effectiveDate > .distantPast {
                Text(relativeAge(effectiveDate))
                    .font(.custom("Fira Code", size: 10 * scale))
                    .foregroundColor(.secondary.opacity(0.5))
            }
            launchButton
            slackButton
        }
        // Match Session History's project-row rhythm: 8pt vertical
        // padding on the compact line, flush rows (VStack spacing 0).
        .padding(.vertical, 8)
        .contentShape(Rectangle())
        .onTapGesture { onToggle() }
    }

    /// Visible launcher icon at the trailing edge — opens (creating if needed)
    /// this project's Slack channel and jumps to it, without toggling the row.
    private var slackButton: some View {
        Button {
            slack.openInSlack(project: project)
        } label: {
            Image(systemName: "bubble.left.and.bubble.right")
                .font(.system(size: 11 * scale, weight: .medium))
                .foregroundColor(.secondary.opacity(slackHovering ? 0.95 : 0.45))
        }
        .buttonStyle(.plain)
        .help("Open in Slack")
        .onHover { slackHovering = $0 }
    }

    /// Visible WORK launcher at the trailing edge — starts a wiki-bootstrap
    /// session in the project's repo cwd with its saved Safe/Unsafe + effort, so
    /// the launch is usable WITHOUT expanding the row. Hidden when the project
    /// declares no `cwds:` (nothing to launch in).
    @ViewBuilder private var launchButton: some View {
        if let cwd = project.primaryCwd {
            Button { launch(cwd: cwd) } label: {
                Image(systemName: launched ? "checkmark.circle.fill" : "pencil.and.outline")
                    .font(.system(size: 11 * scale, weight: .semibold))
                    .foregroundColor(launched ? .green
                                     : .secondary.opacity(launchHovering ? 0.95 : 0.45))
            }
            .buttonStyle(.plain)
            .help("New session — loads project context from the Obsidian wiki")
            .onHover { launchHovering = $0 }
        }
    }

    private func launch(cwd: String) {
        // Mirror WorkSubsection's per-project flags (same UserDefaults keys, keyed
        // by the repo cwd) so a collapsed-row launch matches the expanded one.
        let key = project.primaryCwd ?? project.name
        var flags = ""
        if UserDefaults.standard.bool(forKey: "history.unsafe.\(key)") {
            flags += " --dangerously-skip-permissions"
        }
        let effort = UserDefaults.standard.string(forKey: "history.effort.\(key)") ?? "default"
        if effort != "default" { flags += " --effort \(effort)" }
        _ = performMagicLaunch(projectName: project.name, cwd: cwd,
                               resolvedVaultPath: project.folder.path,
                               launchFlags: flags, terminalService: terminalService)
        launched = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.5) { launched = false }
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

// MARK: - Status / Briefing subsection

/// The project's top "where things stand" slot, in priority order:
///   1. **Briefing** — the cleaner-generated `<!-- gen:briefing -->` block in
///      `Dashboard.md` (Now / Next / Recently done / Later). The live human
///      surface; it **replaces "About"** because the static description is
///      already known — the briefing is the marginal, current info.
///   2. **Status** — `Dashboard.md` `## Current Status`, if present and no briefing.
///   3. **About** — the `Tasks.md` preamble (static description), only when
///      there's no briefing/status yet.
/// Owns its own `SectionLabel` because the label depends on which tier renders.
private struct StatusSubsection: View {
    let project: VaultProjectService.Project
    @Environment(\.fontScale) private var scale
    @State private var briefing: String? = nil
    @State private var currentStatus: String? = nil
    @State private var preamble: String? = nil

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            if let briefing {
                SectionLabel("Briefing")
                briefingView(briefing)
            } else if let s = currentStatus, !s.isEmpty {
                SectionLabel("Status")
                Text(prettifyMarkdown(s))
                    .font(.smallFont(scale))
                    .foregroundColor(.primary)
                    .fixedSize(horizontal: false, vertical: true)
            } else if let preamble {
                SectionLabel("About")
                Text(prettifyMarkdown(preamble))
                    .font(.smallFont(scale))
                    .foregroundColor(.primary)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                SectionLabel("About")
                Text("No project description in Tasks.md.")
                    .font(.captionFont(scale))
                    .foregroundColor(.secondary.opacity(0.7))
            }
        }
        .task(id: project.id) {
            if project.hasDashboard,
               let raw = try? String(contentsOf: project.dashboardPath, encoding: .utf8) {
                briefing = VaultProjectService.extractBriefing(from: raw)
                currentStatus = VaultProjectService.extractSection(named: "Current Status", from: raw)
            } else {
                briefing = nil
                currentStatus = nil
            }
            if let raw = try? String(contentsOf: project.tasksPath, encoding: .utf8) {
                preamble = VaultProjectService.extractPreamble(from: raw)
            } else {
                preamble = nil
            }
        }
    }

    /// Render the briefing block — each non-empty line as markdown so the
    /// **Now**/**Next**/… labels bold naturally. Tolerant of whatever shape the
    /// cleaner emits (plain lines, bullets, or label–dash).
    @ViewBuilder
    private func briefingView(_ text: String) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            ForEach(Array(text.components(separatedBy: "\n").enumerated()), id: \.offset) { _, raw in
                let line = raw.trimmingCharacters(in: .whitespaces)
                if !line.isEmpty {
                    Text(prettifyMarkdown(line))
                        .font(.smallFont(scale))
                        .foregroundColor(.primary)
                        .fixedSize(horizontal: false, vertical: true)
                }
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
                        // Section header: no checkbox. A done heading (`### ✅ …`
                        // or fully struck) is a finished milestone — render it
                        // struck + muted with no count, not "0/N to do". Else a
                        // subtle done/total tallies its checkbox children.
                        Text(prettifyMarkdown(task.title))
                            .font(.captionFont(scale).weight(.bold))
                            .foregroundColor(task.isDone ? .secondary.opacity(0.7) : .primary)
                            .strikethrough(task.isDone)
                            .fixedSize(horizontal: false, vertical: true)
                            .multilineTextAlignment(.leading)
                        if task.isDone {
                            Image(systemName: "checkmark")
                                .font(.system(size: 9 * scale, weight: .bold))
                                .foregroundColor(.secondary.opacity(0.5))
                        } else if childTotal > 0 {
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

// MARK: - Work subsection (Phase 1 harvest — sessions + live agents + launch)

/// The spine's WORK section: every session and currently-alive agent whose
/// repo working directory canonically resolves to THIS project's vault folder
/// (the `cwds:` join key shared with the ingest hook), plus a wiki-bootstrap
/// Launch and the per-project Safe/Unsafe + effort toggles. Sessions reuse the
/// Session-History `SessionDetailRow` verbatim (resume buttons + ingest badge).
///
/// Resolution is done by `VaultProjectService.primeResolution` (off the main
/// actor, memoized) so filtering thousands of sessions costs only cache reads.
/// READ + LAUNCH only — no Tasks.md write happens here (Phase 1 keeps Projects
/// read-only for tasks; the toggle stays in Today).
private struct WorkSubsection: View {
    let project: VaultProjectService.Project
    @EnvironmentObject var sessionHistory: SessionHistoryService
    @EnvironmentObject var agentsService: AgentsService
    @EnvironmentObject var vaultProjects: VaultProjectService
    @EnvironmentObject var terminalService: TerminalService
    @Environment(\.fontScale) private var scale

    @State private var primed = false
    @State private var showAll = false
    @State private var unsafeMode: Bool
    @State private var effort: String
    @State private var feedback: String?

    private let sessionCap = 5
    private static let effortLevels = ["default", "low", "medium", "high", "max"]

    init(project: VaultProjectService.Project) {
        self.project = project
        // Key the per-project flags by the repo cwd so they're shared with the
        // Session-History row for the same project (one source of truth); fall
        // back to the folder name when the project declares no cwd.
        let key = project.primaryCwd ?? project.name
        _unsafeMode = State(initialValue: UserDefaults.standard.bool(forKey: "history.unsafe.\(key)"))
        _effort = State(initialValue: UserDefaults.standard.string(forKey: "history.effort.\(key)") ?? "default")
    }

    private var defaultsKey: String { "history.unsafe.\(project.primaryCwd ?? project.name)" }
    private var effortKey: String { "history.effort.\(project.primaryCwd ?? project.name)" }
    private var launchFlags: String {
        var f = ""
        if unsafeMode { f += " --dangerously-skip-permissions" }
        if effort != "default" { f += " --effort \(effort)" }
        return f
    }

    /// Sessions whose repo cwd resolves to this project's vault folder. Empty
    /// until `primed`; afterwards a live filter over the published session list.
    private var work: [SessionInfo] {
        guard primed else { return [] }
        return sessionHistory.sessions.filter {
            vaultProjects.folderName(forCwd: $0.projectPath) == project.name
        }
    }
    private var visibleSessions: [SessionInfo] {
        (showAll || work.count <= sessionCap) ? work : Array(work.prefix(sessionCap))
    }
    /// Currently-alive agents rooted in this project (same canonical join key).
    private var liveAgents: [AgentSession] {
        guard primed else { return [] }
        return agentsService.agents.filter {
            $0.isAlive && vaultProjects.folderName(forCwd: $0.cwd) == project.name
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            header
            ForEach(liveAgents) { agentRow($0) }
            if visibleSessions.isEmpty {
                Text(primed ? "No sessions in this project yet." : "Resolving sessions…")
                    .font(.captionFont(scale))
                    .foregroundColor(.secondary.opacity(0.7))
            } else {
                ForEach(visibleSessions) { session in
                    SessionDetailRow(
                        session: session,
                        launchFlags: launchFlags,
                        searchResult: nil,
                        onDelete: { sessionHistory.deleteSession(id: session.id) }
                    )
                }
                if work.count > sessionCap {
                    Button(action: { withAnimation(.easeInOut(duration: 0.15)) { showAll.toggle() } }) {
                        Text(showAll ? "Show less" : "Show all \(work.count) sessions")
                            .font(.custom("Fira Sans", size: 11 * scale))
                            .foregroundColor(.accentColor)
                    }
                    .buttonStyle(.borderless)
                    .padding(.vertical, 2)
                }
            }
        }
        .task(id: project.id) {
            // Start the agent poller (idempotent) and resolve every distinct
            // session/agent cwd ONCE, off the main actor, into the memoized
            // cache. Subsequent renders just read the cache.
            agentsService.start()
            var cwds = Set(sessionHistory.sessions.map { $0.projectPath })
            cwds.formUnion(agentsService.agents.map { $0.cwd })
            await vaultProjects.primeResolution(forCwds: cwds)
            primed = true
        }
    }

    private var header: some View {
        HStack(spacing: 8) {
            SectionLabel("Work")
            Spacer()
            // Per-project Safe/Unsafe (persisted, shared with Session History).
            Button(action: {
                unsafeMode.toggle()
                UserDefaults.standard.set(unsafeMode, forKey: defaultsKey)
            }) {
                Image(systemName: unsafeMode ? "lock.open.fill" : "lock.fill")
                    .font(.system(size: 11 * scale))
                    .foregroundColor(unsafeMode ? .red : .green)
            }
            .buttonStyle(.borderless)
            .hudTip(unsafeMode ? "Unsafe mode (click to toggle)" : "Safe mode (click to toggle)")

            // Per-project effort (persisted, shared with Session History).
            Button(action: { cycleEffort() }) {
                Image(systemName: effortIcon)
                    .font(.system(size: 11 * scale))
                    .foregroundColor(effortColor)
            }
            .buttonStyle(.borderless)
            .hudTip("Effort: \(effort) (click to cycle)")

            // Launch — magic wiki-bootstrap session in the project's repo cwd.
            // The vault folder is known directly here, so the prompt always
            // takes the "already resolved" branch (no index.md re-derivation).
            if let feedback {
                Text(feedback)
                    .font(.custom("Fira Sans", size: 11 * scale))
                    .foregroundColor(.green)
            } else if let cwd = project.primaryCwd {
                Button(action: { launch(cwd: cwd) }) {
                    Image(systemName: "pencil.and.outline")
                        .font(.system(size: 11 * scale, weight: .semibold))
                        .foregroundColor(.white)
                }
                .buttonStyle(.borderless)
                .hudTip("New session — loads project context from the Obsidian wiki")
            } else {
                // No launchable cwd: greyed + struck, same idiom as the
                // Session-History "no prior sessions" / GitHub "no remote" mark.
                ZStack {
                    Image(systemName: "pencil.and.outline")
                        .font(.system(size: 11 * scale, weight: .semibold))
                        .foregroundColor(.secondary.opacity(0.35))
                    Rectangle()
                        .frame(width: 14 * scale, height: 1.5 * scale)
                        .rotationEffect(.degrees(-45))
                        .foregroundColor(.secondary.opacity(0.7))
                }
                .hudTip("No working directory in cwds: — can't launch")
            }
        }
    }

    private func agentRow(_ a: AgentSession) -> some View {
        HStack(spacing: 6) {
            Circle()
                .fill(agentColor(a))
                .frame(width: 6, height: 6)
            Text(a.name)
                .font(.captionFont(scale))
                .foregroundColor(.primary)
                .lineLimit(1)
            if a.isOpen {
                Text("open")
                    .font(.custom("Fira Sans", size: 9 * scale).weight(.medium))
                    .padding(.horizontal, 4)
                    .padding(.vertical, 1)
                    .background(Color.green.opacity(0.16))
                    .foregroundColor(.green)
                    .clipShape(Capsule())
            }
            Spacer()
            if let u = a.updatedAt {
                Text(u.relativeString)
                    .font(.custom("Fira Code", size: 9.5 * scale))
                    .foregroundColor(.secondary.opacity(0.5))
            }
        }
        .padding(.vertical, 2)
        .hudTip("Live agent — \(a.rawState). Manage it in the Claude tab.")
    }

    private func agentColor(_ a: AgentSession) -> Color {
        if a.inFlightTasks > 0 || a.rawState == "working" { return .green }
        if a.rawState == "blocked" { return .orange }
        return .secondary.opacity(0.6)
    }

    private func launch(cwd: String) {
        let auto = performMagicLaunch(
            projectName: project.name, cwd: cwd,
            resolvedVaultPath: project.folder.path, launchFlags: launchFlags,
            terminalService: terminalService
        )
        feedback = auto ? "Opened!" : "Cmd+V"
        DispatchQueue.main.asyncAfter(deadline: .now() + 3) { feedback = nil }
    }

    private func cycleEffort() {
        guard let idx = Self.effortLevels.firstIndex(of: effort) else { effort = "default"; return }
        effort = Self.effortLevels[(idx + 1) % Self.effortLevels.count]
        UserDefaults.standard.set(effort, forKey: effortKey)
    }

    private var effortIcon: String {
        switch effort {
        case "low": return "gauge.with.dots.needle.0percent"
        case "medium": return "gauge.with.dots.needle.33percent"
        case "high": return "gauge.with.dots.needle.67percent"
        case "max": return "gauge.with.dots.needle.100percent"
        default: return "gauge.with.dots.needle.50percent"
        }
    }
    private var effortColor: Color {
        switch effort {
        case "low": return .red
        case "medium": return .orange
        case "high": return .white
        case "max": return .green
        default: return .secondary
        }
    }
}

// MARK: - Project intel subsection (Phase 1 harvest — People / Meetings / Emails)

/// People, today's meetings, and recent emails for this project — harvested
/// from the cross `ProjectService` aggregation engine, bridged by folder name
/// (`ProjectService.Project.id == folder == VaultProjectService.Project.name`).
/// `loadIntel` runs lazily on expand (Spark email DB + calendar). Renders
/// nothing — including its own leading divider — when there's no intel, so an
/// expanded row stays compact for projects with no people/mail/meetings.
private struct ProjectIntelSubsection: View {
    let project: VaultProjectService.Project
    @EnvironmentObject var crossProjectService: ProjectService
    @Environment(\.fontScale) private var scale
    @State private var bridged: Project?

    private var intel: ProjectIntel? { bridged.flatMap { crossProjectService.intel[$0.id] } }

    var body: some View {
        let people = intel?.people ?? []
        let emails = intel?.emails ?? []
        let events = bridged?.upcomingEvents ?? []
        Group {
            if people.isEmpty && emails.isEmpty && events.isEmpty {
                EmptyView()
            } else {
                VStack(alignment: .leading, spacing: 8) {
                    Divider().opacity(0.18)
                    if !events.isEmpty {
                        SectionLabel("Today")
                        ForEach(events) { event in
                            HStack(spacing: 6) {
                                Text(event.title)
                                    .font(.captionFont(scale))
                                    .foregroundColor(.primary)
                                    .lineLimit(1)
                                Spacer()
                                Text(shortClockTime(event.startDate))
                                    .font(.custom("Fira Code", size: 9.5 * scale))
                                    .foregroundColor(.secondary.opacity(0.5))
                            }
                        }
                    }
                    if !people.isEmpty {
                        SectionLabel("People")
                        ForEach(people.prefix(6)) { contact in
                            HStack(spacing: 6) {
                                Image(systemName: "person")
                                    .font(.system(size: 8 * scale))
                                    .foregroundColor(.secondary.opacity(0.5))
                                    .frame(width: 12)
                                Text(contact.name)
                                    .font(.captionFont(scale))
                                    .foregroundColor(.primary)
                                    .lineLimit(1)
                                if !contact.org.isEmpty {
                                    Text("(\(contact.org))")
                                        .font(.custom("Fira Code", size: 9 * scale))
                                        .foregroundColor(.secondary.opacity(0.5))
                                        .lineLimit(1)
                                }
                                Spacer()
                            }
                        }
                    }
                    if !emails.isEmpty {
                        SectionLabel("Emails")
                        ForEach(emails.prefix(4)) { email in
                            VStack(alignment: .leading, spacing: 1) {
                                Text(email.subject)
                                    .font(.captionFont(scale))
                                    .foregroundColor(.primary)
                                    .lineLimit(1)
                                HStack(spacing: 4) {
                                    Text(email.from)
                                        .font(.custom("Fira Sans", size: 10.5 * scale))
                                        .foregroundColor(.secondary.opacity(0.5))
                                        .lineLimit(1)
                                    Text("·").foregroundColor(.secondary.opacity(0.3))
                                    Text(email.date)
                                        .font(.custom("Fira Sans", size: 10.5 * scale))
                                        .foregroundColor(.secondary.opacity(0.5))
                                }
                            }
                        }
                    }
                }
            }
        }
        .task(id: project.id) {
            bridged = crossProjectService.projects.first { $0.name == project.name }
            if let b = bridged { crossProjectService.loadIntel(for: b) }
        }
    }
}

/// Lowercase `h:mma` clock time for the meetings rows.
private func shortClockTime(_ date: Date) -> String {
    let fmt = DateFormatter()
    fmt.dateFormat = "h:mma"
    return fmt.string(from: date).lowercased()
}
