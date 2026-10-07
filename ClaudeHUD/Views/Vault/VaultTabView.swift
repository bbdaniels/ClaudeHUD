import SwiftUI
import AppKit

/// Projects tab — one row per project (top-level vault folder with a
/// `Tasks.md`): name, live-session badges, age, and the launch controls. A
/// project whose `Tasks.md` declares `parent:` is not a top-level row; it
/// renders inset beneath its parent, always visible, and travels with the
/// parent into its recency section. Rows do not expand: the tree comes from
/// `ProjectTree.build`, the only reader of `parent:`.
struct VaultTabView: View {
    @EnvironmentObject var projectService: VaultProjectService
    @EnvironmentObject var ingestService: VaultIngestService
    @EnvironmentObject var vaultManager: VaultManager
    // Sessions drive recency, the agent roster drives the live-session
    // badges. Warmed in `.onAppear`. All read-only / idempotent.
    @EnvironmentObject var sessionHistory: SessionHistoryService
    @EnvironmentObject var agentsService: AgentsService
    @Environment(\.fontScale) private var scale

    @State private var collapsedSections: Set<String> = []
    @State private var searchText = ""
    @State private var showNewProject = false
    /// folder name → most-recent session timestamp for that project (resolved
    /// via the canonical cwds: resolver). Drives "real activity" recency so a
    /// project that's busy in sessions but whose `updated:` went stale still
    /// sorts as recent. Primed off-main in `.task`.
    @State private var folderLatestSession: [String: Date] = [:]
    /// Bumped after the agent roster's cwds are primed into the resolver cache.
    /// `primeResolution` fills a private cache with no `objectWillChange`, so
    /// this is what re-renders the rows with warm badges instead of waiting on
    /// the next 2s roster republish.
    @State private var agentResolutionTick = 0

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider().opacity(0.3)
            ScrollView {
                // NOTE: must be a plain VStack, NOT LazyVStack. Inside a
                // ScrollView, LazyVStack estimates content height from realized
                // rows, and when row heights varied (the rows used to expand)
                // the estimate oscillated:
                // ScrollView.sizeThatFits ↔ LazySubviewPlacements.placeSubviews
                // re-trigger each other every runloop pass and never converge,
                // pinning the main thread at 100% (the Projects-tab pinwheel,
                // confirmed via `sample`). A non-lazy VStack gives the ScrollView
                // a deterministic content height. The list is only tens of
                // one-line rows, so eager layout is fine.
                VStack(alignment: .leading, spacing: 0) {
                    // Built ONCE per body pass and handed to both the sort and
                    // the rows: `AgentsService` republishes every 2s, so a
                    // per-row filter over the roster would be O(rows × agents)
                    // on every tick of a non-lazy, fully-realized list.
                    let live = folderLiveSessions
                    let sections = recencySections(live: live)
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
                                // Rows, not families: children are counted.
                                count: section.nodes.reduce(0) { $0 + 1 + $1.children.count },
                                collapsed: collapsedSections.contains(section.title),
                                onToggle: { toggleSection(section.title) }
                            )
                            if !collapsedSections.contains(section.title) {
                                ForEach(section.nodes) { node in
                                    // Parent row: badge and click-to-focus span
                                    // the family; the launch gets its OWN
                                    // sessions only, so it can never open as a
                                    // tab in a child's Ghostty window.
                                    ProjectRowView(
                                        project: node.project,
                                        isChild: false,
                                        ingestService: ingestService,
                                        effectiveDate: node.recency(effectiveUpdated),
                                        liveSessions: node.liveCounts(in: live),
                                        badgeSessionsProvider: { liveSessions(forFolders: node.folderNames) },
                                        ownSessionsProvider: { liveSessions(forFolders: [node.project.name]) }
                                    )
                                    ForEach(node.childrenByRecency(effectiveUpdated)) { child in
                                        ProjectRowView(
                                            project: child,
                                            isChild: true,
                                            ingestService: ingestService,
                                            effectiveDate: effectiveUpdated(child),
                                            liveSessions: live[child.name] ?? LiveSessionCounts(),
                                            badgeSessionsProvider: { liveSessions(forFolders: [child.name]) },
                                            ownSessionsProvider: { liveSessions(forFolders: [child.name]) }
                                        )
                                    }
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
            // Warm the badge and recency sources. Idempotent: `start()` no-ops
            // if already polling, and sessions only reload when not already
            // present.
            agentsService.start()
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
        // The live-session badges join agents to projects through the same
        // memoized resolver, but the session prime above only sees session
        // cwds. Prime the agent roster's cwds too, keyed on the DISTINCT cwd
        // set so this re-runs when a session appears in a new repo — not on
        // every 2s roster republish.
        .task(id: agentCwdSignature) {
            let cwds = Set(agentsService.agents.map { $0.cwd }).filter { !$0.isEmpty }
            guard !cwds.isEmpty else { return }
            await projectService.primeResolution(forCwds: cwds)
            agentResolutionTick &+= 1
        }
        .sheet(isPresented: $showNewProject) {
            NewProjectSheet(
                vaultPath: vaultPath,
                existingNames: Set(projectService.projects.map { $0.name.lowercased() }),
                parentCandidates: ProjectTree.parentCandidates(projectService.projects)
            ) { folder in
                // Parse just the new folder and insert its row so it shows
                // immediately; a full vault scan (iCloud-cold, tens of
                // seconds) must never gate this. The background refresh then
                // reconciles the rest of the list.
                projectService.insertProject(folder: folder)
                projectService.refresh()
            }
        }
    }

    private var vaultPath: URL? {
        projectService.vaultPath
            ?? vaultManager.currentVault.map { URL(fileURLWithPath: $0.path) }
    }

    /// The project tree after the search box is applied. A match on a child
    /// keeps it under its parent (see `ProjectTree.filter`).
    private var filteredNodes: [ProjectTree.Node] {
        ProjectTree.filter(ProjectTree.build(projectService.projects), query: searchText)
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

    /// Distinct working directories across the agent roster. Used as the
    /// `.task(id:)` key for the resolver prime so it re-fires on a genuinely
    /// new cwd rather than on the poller's 2s republish.
    private var agentCwdSignature: Int {
        Set(agentsService.agents.map { $0.cwd }).hashValue
    }

    /// folder name → live INTERACTIVE session counts, in one pass over the
    /// roster.
    ///
    /// "Interactive" is `isOpen` — a live `claude attach <short>` process. The
    /// daemon's job dirs carry no interactive flag (ClaudeHUD's own magic
    /// launch runs interactive sessions through `claude --bg` and then attaches
    /// them), so an attached terminal is the only honest discriminator.
    ///
    /// States come from `AgentSession.bucket`, never from `rawState`. `bucket`
    /// carries the roster liveness gate: the daemon never flushes a terminal
    /// state when a worker dies abnormally, so a `state.json` frozen on
    /// `blocked` would otherwise be counted as "needs me" forever. Absent from
    /// `roster.workers` ⇒ `.stopped` ⇒ not counted.
    private var folderLiveSessions: [String: LiveSessionCounts] {
        var map: [String: LiveSessionCounts] = [:]
        for (folder, sessions) in liveSessionsByFolder {
            var counts = LiveSessionCounts()
            for a in sessions {
                switch a.bucket {
                case .working:    counts.working += 1
                case .needsInput: counts.blocked += 1
                case .idle:       counts.idle += 1
                default:          break
                }
            }
            map[folder] = counts
        }
        return map
    }

    /// folder name → the live INTERACTIVE sessions themselves. One source for
    /// both the badge counts and the badge's click target, so what a click
    /// raises is exactly what was counted.
    private var liveSessionsByFolder: [String: [AgentSession]] {
        projectService.liveSessionsByFolder(in: agentsService.agents)
    }

    /// The live sessions of these project folders, most recently active
    /// first. Called from a badge or launch click only.
    private func liveSessions(forFolders folders: [String]) -> [AgentSession] {
        projectService.liveSessions(forFolders: folders, in: agentsService.agents)
    }

    /// Top-level rows grouped by recency. A parent is bucketed by the most
    /// recent activity among itself and its children, and its children travel
    /// with it; within a bucket `ProjectTree.ordered` floats families with a
    /// session waiting on the user. Bucket membership is by recency alone, so
    /// nothing crosses a section boundary by waiting.
    private func recencySections(live: [String: LiveSessionCounts])
        -> [(title: String, nodes: [ProjectTree.Node])] {
        let cal = Calendar.current
        let startOfToday = cal.startOfDay(for: Date())
        let startOfWeek = cal.date(byAdding: .day, value: -7, to: startOfToday)!
        let startOfMonth = cal.date(byAdding: .day, value: -30, to: startOfToday)!

        func rank(_ n: ProjectTree.Node) -> Int {
            let d = n.recency(effectiveUpdated)
            if d >= startOfToday { return 0 }
            if d >= startOfWeek { return 1 }
            if d >= startOfMonth { return 2 }
            return 3
        }
        let titles = ["Today", "This Week", "This Month", "Older"]
        let nodes = filteredNodes
        var out: [(title: String, nodes: [ProjectTree.Node])] = []
        for (idx, title) in titles.enumerated() {
            let group = ProjectTree.ordered(nodes.filter { rank($0) == idx },
                                            live: live, activity: effectiveUpdated)
            if !group.isEmpty { out.append((title: title, nodes: group)) }
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
            Button(action: { showNewProject = true }) {
                Image(systemName: "folder.badge.plus")
                    .font(.system(size: 12 * scale, weight: .semibold))
                    .foregroundColor(.secondary)
            }
            .buttonStyle(.borderless)
            .hudTip("New project")
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
}

// MARK: - Live session badges

/// Compact state cluster on the project row: green dot = running a turn,
/// amber dot = waiting on you, clock = alive but idle. On a parent row the
/// counts are its own plus its children's.
///
/// With `onTap` supplied the whole cluster is one button that raises the
/// session windows behind the counts (see
/// `ProjectRowView.focusNextLiveSession`). Left nil the cluster is
/// display-only.
///
/// Deliberately borrows the ingested-count chip's idiom (Fira Code 10, 4/1
/// padding, radius-3 low-opacity fill) so a busy row still reads as calm; the
/// idle segment stays on `.secondary` because it is informational, not a call
/// to act. Hover only deepens the chip fill, so the resting appearance is
/// unchanged.
private struct LiveSessionBadges: View {
    let counts: LiveSessionCounts
    var onTap: (() -> Void)?
    @Environment(\.fontScale) private var scale
    @State private var hovering = false

    var body: some View {
        if let onTap {
            Button(action: onTap) { cluster }
                .buttonStyle(.plain)
                .onHover { hovering = $0 }
                .help(helpText + " — click to focus, again to cycle")
        } else {
            cluster.help(helpText)
        }
    }

    private var cluster: some View {
        HStack(spacing: 4) {
            if counts.working > 0 {
                chip(count: counts.working, tint: .green, text: .green.opacity(0.9)) {
                    Circle().fill(Color.green).frame(width: 5, height: 5)
                }
            }
            if counts.blocked > 0 {
                chip(count: counts.blocked, tint: .orange, text: .orange.opacity(0.95)) {
                    Circle().fill(Color.orange).frame(width: 5, height: 5)
                }
            }
            if counts.idle > 0 {
                chip(count: counts.idle, tint: .secondary, text: .secondary.opacity(0.6)) {
                    Image(systemName: "clock")
                        .font(.system(size: 8 * scale))
                        .foregroundColor(.secondary.opacity(0.6))
                }
            }
        }
        .contentShape(Rectangle())
    }

    private func chip<Glyph: View>(count: Int, tint: Color, text: Color,
                                   @ViewBuilder glyph: () -> Glyph) -> some View {
        HStack(spacing: 3) {
            glyph()
            Text("\(count)")
                .font(.custom("Fira Code", size: 10 * scale))
                .foregroundColor(text)
        }
        .padding(.horizontal, 4)
        .padding(.vertical, 1)
        .background(RoundedRectangle(cornerRadius: 3).fill(tint.opacity(hovering ? 0.22 : 0.12)))
    }

    private var helpText: String {
        var parts: [String] = []
        if counts.working > 0 { parts.append("\(counts.working) working") }
        if counts.blocked > 0 { parts.append("\(counts.blocked) waiting on you") }
        if counts.idle > 0 { parts.append("\(counts.idle) idle") }
        return "Open sessions — " + parts.joined(separator: " · ")
    }
}

// MARK: - Project row

private struct ProjectRowView: View {
    let project: VaultProjectService.Project
    /// A child renders inset beneath its parent row.
    let isChild: Bool
    let ingestService: VaultIngestService
    /// max(updated:, latest session) — the recency shown as the row's age. On
    /// a parent it spans the children too, since that is what the row is
    /// bucketed by.
    let effectiveDate: Date
    /// Live interactive-session counts for this row: a project's own, or on a
    /// parent its own plus its children's. Passed by value (not read off
    /// `AgentsService` here) so the row does not subscribe to the 2s roster
    /// republish — this list is deliberately non-lazy and fully realized.
    let liveSessions: LiveSessionCounts
    /// Resolves the sessions behind `liveSessions`, most recently active
    /// first: what a badge click cycles through. A closure, not an array, so
    /// the roster is walked on click only — holding the sessions here would
    /// re-diff every row on the 2s republish this list is built to avoid.
    let badgeSessionsProvider: () -> [AgentSession]
    /// This project's OWN live sessions, never a child's: what a launch may
    /// reuse a Ghostty window from.
    let ownSessionsProvider: () -> [AgentSession]
    @Environment(\.fontScale) private var scale
    @EnvironmentObject private var terminalService: TerminalService
    @State private var launchHovering = false
    @State private var launched = false
    /// Which of this project's live sessions the next badge click raises.
    /// Keyed by the session-id list so the cycle restarts whenever the set
    /// changes rather than pointing at whatever now sits at a stale index.
    @State private var badgeCycleIndex = 0
    @State private var badgeCycleKey: [String] = []

    /// Leading inset that marks a row as a child of the row above it.
    private static let childInset: CGFloat = 18

    var body: some View {
        HStack(spacing: 6) {
            Text(project.name)
                .font(isChild ? .smallFont(scale) : .smallMedium(scale))
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
            if !liveSessions.isEmpty {
                LiveSessionBadges(counts: liveSessions, onTap: focusNextLiveSession)
            }
            Spacer()
            manuscriptorButton
            if effectiveDate > .distantPast {
                Text(relativeAge(effectiveDate))
                    .font(.custom("Fira Code", size: 10 * scale))
                    .foregroundColor(.secondary.opacity(0.5))
            }
            magicLaunchButton
        }
        // Match Session History's project-row rhythm: 8pt vertical padding on
        // a top-level line, flush rows (VStack spacing 0). Children sit a
        // little tighter so a family reads as one group.
        .padding(.leading, isChild ? Self.childInset : 4)
        .padding(.vertical, isChild ? 5 : 8)
    }

    /// The directory a launch targets: the project's first glob-free `cwds:`
    /// path, or the home directory (`~`) when the project has none yet. A
    /// new / notes-only project (empty `cwds:`) still launches — into `~` —
    /// until the human sets a real `cwds:` (user directive 2026-07-06). So the
    /// controls are ALWAYS shown, not gated on a resolvable cwd.
    private var launchCwd: String { project.primaryCwd ?? NSHomeDirectory() }
    private var hasCwd: Bool { project.primaryCwd != nil }

    /// The row's launcher controls. Row order: Manuscriptor (only when
    /// `manuscript:` is declared) · age · magic launch. Always shown; a
    /// project with no `cwds:` launches into `~` (see `launchCwd`).
    @ViewBuilder private var magicLaunchButton: some View {
        Button { launch(cwd: launchCwd) } label: {
            Image(systemName: launched ? "checkmark.circle.fill" : "pencil.and.outline")
                .font(.system(size: 11 * scale, weight: .semibold))
                .foregroundColor(launched ? .green
                                 : .secondary.opacity(launchHovering ? 0.95 : 0.45))
        }
        .buttonStyle(.plain)
        .help(hasCwd ? "New session — loads project context from the Obsidian wiki"
                     : "New session in ~ (no cwds: set yet) — loads project context from the wiki")
        .onHover { launchHovering = $0 }
    }

    @ViewBuilder private var manuscriptorButton: some View {
        if let dir = project.manuscriptDir {
            Button {
                terminalService.openInManuscriptor(URL(fileURLWithPath: dir))
            } label: {
                // TODO: swap for the Manuscriptor quill mark
                Image(systemName: "signature")
                    .font(.system(size: 11 * scale))
                    .foregroundColor(.secondary.opacity(0.45))
            }
            .buttonStyle(.plain)
            .help("Open in Manuscriptor")
        }
    }

    /// Raise the window of the most recently active live session behind the
    /// badge (on a parent, its own and its children's); click again to walk
    /// the rest. Read-only — it never touches the daemon
    /// and never launches anything, so a click on a stale badge is harmless.
    private func focusNextLiveSession() {
        let sessions = badgeSessionsProvider()
        guard !sessions.isEmpty else {
            GhosttyWindowService.activateApp()
            return
        }
        let key = sessions.map(\.id)
        if key != badgeCycleKey {
            badgeCycleKey = key
            badgeCycleIndex = 0
        }
        let idx = badgeCycleIndex % sessions.count
        badgeCycleIndex = (idx + 1) % sessions.count

        let session = sessions[idx]
        let basename = URL(fileURLWithPath: session.cwd).lastPathComponent
        if GhosttyWindowService.focusWindow(hostPid: session.attachedGhosttyPid,
                                            titleContains: basename) { return }
        // Nothing identifiable (no host pid, no matching title, or no AX
        // grant): still put the user in the terminal if it's running at all.
        GhosttyWindowService.activateApp()
    }

    private func launch(cwd: String) {
        _ = performMagicLaunch(projectName: project.name, cwd: cwd,
                               resolvedVaultPath: project.folder.path,
                               liveSessions: ownSessionsProvider(),
                               terminalService: terminalService)
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

// MARK: - New project sheet

/// Minimal "new project" sheet reached from the Projects-tab header "+".
/// Collects a folder name and an optional parent project, and scaffolds a
/// schema-correct project folder (`Tasks.md` + `Dashboard.md` +
/// `Technical Notes.md`) via `VaultManager.createProject`; a chosen parent is
/// written as `parent:` in the new `Tasks.md`. The working directory (`cwds:`) is left empty
/// for the human to fill in Obsidian — per the vault's canonical project model,
/// `cwds:` is human-owned and never machine-written.
private struct NewProjectSheet: View {
    let vaultPath: URL?
    /// Lowercased existing folder names — for a friendly pre-check before the
    /// filesystem-level collision guard in `createProject`.
    let existingNames: Set<String>
    /// Projects that may be chosen as the parent
    /// (`ProjectTree.parentCandidates`).
    let parentCandidates: [String]
    /// Called with the freshly-written project folder URL on success.
    let onCreate: (URL) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var name = ""
    /// Chosen parent folder name; empty = a top-level project.
    @State private var parent = ""
    @State private var errorText: String?

    private var trimmed: String { name.trimmingCharacters(in: .whitespacesAndNewlines) }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("New Project")
                .font(.headline)

            VStack(alignment: .leading, spacing: 5) {
                TextField("Project name", text: $name)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit(create)
                Picker("Parent", selection: $parent) {
                    Text("None").tag("")
                    ForEach(parentCandidates, id: \.self) { Text($0).tag($0) }
                }
                Text("Creates a vault folder with Tasks, Dashboard, and Technical Notes. Set the working directory (cwds:) later in Obsidian.")
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            if let errorText {
                Text(errorText)
                    .font(.caption)
                    .foregroundColor(.red)
                    .fixedSize(horizontal: false, vertical: true)
            }

            HStack {
                Spacer()
                Button("Cancel", role: .cancel) { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("Create", action: create)
                    .keyboardShortcut(.defaultAction)
                    .disabled(trimmed.isEmpty)
            }
        }
        .padding(20)
        .frame(width: 360)
    }

    private func create() {
        errorText = nil
        guard !trimmed.isEmpty else { return }
        guard let vaultPath else {
            errorText = VaultManager.CreateProjectError.noVault.errorDescription
            return
        }
        if existingNames.contains(trimmed.lowercased()) {
            errorText = VaultManager.CreateProjectError.alreadyExists(trimmed).errorDescription
            return
        }
        switch VaultManager.createProject(vaultPath: vaultPath, name: trimmed, parent: parent) {
        case .success(let folder):
            onCreate(folder)
            dismiss()
        case .failure(let err):
            errorText = err.errorDescription
        }
    }
}
