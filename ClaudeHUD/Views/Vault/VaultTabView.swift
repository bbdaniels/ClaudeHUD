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
    /// The day every row's due chip and age are read against. A row redraws
    /// only when its inputs change, so the day is an input, advanced at
    /// midnight, on a clock change and on wake (2026-11-02: a chip drawn on
    /// Oct 31 still read "tmrw" for a Nov 1 deadline two days later).
    @State private var today = Date()

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
                    let lines = folderSessionLines
                    let sections = recencySections(live: live)
                    let general = generalSessions
                    let lost = lostTreesByFolder
                    let generalLost = lost[""] ?? []
                    if (!general.isEmpty || !generalLost.isEmpty) && searchText.isEmpty {
                        GeneralRowView(lines: LiveSessionLine.lines(general, now: Date()),
                                       lostTrees: generalLost,
                                       sessions: { generalSessions })
                    }
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
                                        effectiveDate: node.recency(effectiveUpdated),
                                        today: today,
                                        liveSessions: node.liveCounts(in: live),
                                        sessionLines: lines[node.project.name] ?? [],
                                        lostTrees: lost[node.project.name] ?? [],
                                        badgeSessionsProvider: { liveSessions(forFolders: node.folderNames) },
                                        ownSessionsProvider: { liveSessions(forFolders: [node.project.name]) }
                                    )
                                    ForEach(node.childrenByRecency(effectiveUpdated)) { child in
                                        ProjectRowView(
                                            project: child,
                                            isChild: true,
                                            effectiveDate: effectiveUpdated(child),
                                            today: today,
                                            liveSessions: live[child.name] ?? LiveSessionCounts(),
                                            sessionLines: lines[child.name] ?? [],
                                            lostTrees: lost[child.name] ?? [],
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
        //
        // Both this and the live badges file a session by `SessionFiling`'s
        // one rule (claim, then the transcript's record directories, then
        // the start directory), primed here for the history's sessions and
        // the roster's together. Keyed on the inputs, not on every 2s roster
        // republish: the distinct (session, cwd) set, the index's tallies
        // and the claims directory.
        .task(id: filingSignature) {
            let sessions = sessionHistory.sessions
            let history = sessions.map { (sessionId: $0.id, cwd: $0.projectPath, host: $0.host) }
            let live = agentsService.agents.compactMap { a in
                a.sessionId.map { (sessionId: $0, cwd: a.cwd, host: SessionHost.mac) }
            }
            await projectService.primeResolution(
                forCwds: Set((agentsService.agents.map(\.cwd) + agentsService.lostTrees.map(\.cwd))
                    .map { SessionFiling.repoCwd($0) }).filter { !$0.isEmpty })
            await projectService.primeFiling(sessions: history + live,
                                             cwdCounts: sessionHistory.transcriptCwdCounts)
            var map: [String: Date] = [:]
            for s in sessions {
                guard let folder = projectService.folder(forSession: s.id, cwd: s.projectPath) else { continue }
                if let cur = map[folder], cur >= s.timestamp { continue }
                map[folder] = s.timestamp
            }
            folderLatestSession = map
            agentResolutionTick &+= 1
        }
        .onReceive(NotificationCenter.default.publisher(for: .NSCalendarDayChanged)) { _ in today = Date() }
        .onReceive(NotificationCenter.default.publisher(for: .NSSystemClockDidChange)) { _ in today = Date() }
        .onReceive(NSWorkspace.shared.notificationCenter.publisher(for: NSWorkspace.didWakeNotification)) { _ in today = Date() }
        .sheet(isPresented: $showNewProject) {
            NewProjectSheet(
                vaultPath: vaultPath,
                existingNames: Set(projectService.projects.map { $0.name.lowercased() }),
                parentCandidates: ProjectTree.parentCandidates(projectService.projects)
            ) { folder in
                // Parse just the new folder and insert its row so it shows
                // immediately; a full vault scan reads every project and
                // must never gate this. The background refresh then
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
    private var filingSignature: Int {
        var h = Hasher()
        h.combine(sessionHistory.sessions.count)
        h.combine(Set(agentsService.agents.map { "\($0.sessionId ?? "")\u{0}\($0.cwd)" }))
        h.combine(Set(agentsService.lostTrees.map(\.cwd)))
        h.combine(sessionHistory.transcriptCwdGeneration)
        h.combine(SessionFiling.claimsSignature())
        return h.finalize()
    }

    /// folder name → live INTERACTIVE session counts, in one pass over the
    /// roster.
    ///
    /// Counts what `liveSessionsByFolder` lists: every running session,
    /// attached to a terminal or not, so a badge and the lines under its row
    /// always agree.
    ///
    /// States come from `AgentSession.liveState`, never from `rawState`: it
    /// carries the roster liveness gate. The daemon never flushes a terminal
    /// state when a worker dies abnormally, so a `state.json` frozen on
    /// `blocked` would otherwise be counted as "needs me" forever. Absent from
    /// `roster.workers` ⇒ not alive ⇒ not counted.
    private var folderLiveSessions: [String: LiveSessionCounts] {
        let now = Date()
        return liveSessionsByFolder.mapValues { sessions in
            sessions.reduce(into: LiveSessionCounts()) { $0.add($1.light(now: now)) }
        }
    }

    /// folder name → one line per live session of that folder: what the row
    /// lists beneath itself (Ben, 2026-11-03: one place that shows every
    /// session, each told apart by name, machine and state). Equatable
    /// values with no age in them, so the 2s roster republish re-renders a
    /// row only when a session starts, ends, is renamed or changes state.
    private var folderSessionLines: [String: [LiveSessionLine]] {
        let now = Date()
        return liveSessionsByFolder.mapValues { LiveSessionLine.lines($0, now: now) }
    }

    /// folder name → the live INTERACTIVE sessions themselves. One source for
    /// both the badge counts and the badge's click target, so what a click
    /// raises is exactly what was counted.
    private var liveSessionsByFolder: [String: [AgentSession]] {
        projectService.liveSessionsByFolder(in: agentsService.agents)
    }

    /// folder name → the process trees left out by sessions that are gone
    /// (`AgentsService.lostTrees`), filed by `SessionFiling.treeFolder`: the
    /// project of the folder the tree runs in, else its session's. "" holds
    /// those under no project, which General lists.
    private var lostTreesByFolder: [String: [StrayTree]] {
        var map: [String: [StrayTree]] = [:]
        for t in agentsService.lostTrees {
            let folder = t.cwd.isEmpty ? "" : SessionFiling.treeFolder(
                own: projectService.folderName(forCwd: SessionFiling.repoCwd(t.cwd)),
                session: projectService.folder(forSession: t.sessionId, cwd: t.cwd))
            map[folder, default: []].append(t)
        }
        return map
    }

    /// Live sessions filed under no project: most often one started in
    /// ~/Projects itself, from the phone's New session or the `>_` button.
    /// They are listed under General at the top (Ben, 2026-11-03) until work
    /// in a project folder or `/project` files them.
    private var generalSessions: [AgentSession] {
        agentsService.agents.filter { a in
            guard a.isAlive, [.working, .needsInput, .idle].contains(a.liveState) else { return false }
            return a.cwd.isEmpty || projectService.folder(forSession: a.sessionId, cwd: a.cwd) == nil
        }
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
        let startOfToday = cal.startOfDay(for: today)
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

// MARK: - General

/// The row at the top that holds the live sessions filed under no project
/// (`VaultTabView.generalSessions`): a header like a project's, with its
/// dot, and one line per session.
private struct GeneralRowView: View {
    let lines: [LiveSessionLine]
    let lostTrees: [StrayTree]
    let sessions: () -> [AgentSession]
    @Environment(\.fontScale) private var scale
    @EnvironmentObject private var terminalService: TerminalService

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 6) {
                DancingText(text: "General", size: 14 * scale, weight: .semibold)
                if let light = lines.reduce(into: LiveSessionCounts(), { $0.add($1.light) }).light {
                    HeaderLight(light: light) {
                        let all = sessions()
                        if let s = all.first(where: { $0.light(now: Date()) == .attention }) ?? all.first {
                            open(s)
                        }
                    }
                }
                Spacer()
            }
            .padding(.leading, 4)
            .padding(.vertical, 8)
            ForEach(lines) { line in
                SessionLineView(line: line, inset: 16) {
                    if let s = sessions().first(where: { $0.id == line.id }) { open(s) } else { NSSound.beep() }
                }
            }
            ForEach(lostTrees) { LostTreeLineView(tree: $0, inset: 16) }
        }
    }

    private func open(_ s: AgentSession) {
        if !AgentsService.open(s, projectWindow: nil, terminalService: terminalService) { NSSound.beep() }
    }
}

// MARK: - Header light

/// A project header's one dot (Ben, 2026-11-03): red when a session under it
/// waits on Ben, else green when one is running, else orange when one is
/// held by a long shell command. A click opens the session
/// that most needs him.
struct HeaderLight: View {
    let light: SessionLight
    var onTap: () -> Void

    var body: some View {
        Button(action: onTap) {
            Circle().fill(light.color)
                .frame(width: 7, height: 7).padding(3).contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(light == .running ? "A session is running: click to open it" : light == .holding ? "A session is held by a long shell command, such as a dev server: click to open it" : "A session waits on you: click to open it")
    }
}

// MARK: - Due chip

/// The project's soonest-due open task (`📅 YYYY-MM-DD` in `## Active`, read
/// by `ActiveTasks`), in a chip (Fira Code 10, a low-opacity fill): "3d late" in red,
/// "today"/"tmrw" and anything within two days in orange, else a weekday
/// within the week or "Oct 20" on `.secondary`. Hover names the task and the
/// full date.
private struct DueChip: View {
    let due: ActiveTasks.NextDue
    /// Passed in, never read from the clock here: see `VaultTabView.today`.
    let today: Date
    @Environment(\.fontScale) private var scale

    var body: some View {
        let days = ActiveTasks.daysUntil(due.date, today: today)
        let tint: Color = days < 0 ? .red : days <= 2 ? .orange : .secondary
        Text(ActiveTasks.dueLabel(due.date, today: today))
            .font(.custom("Fira Code", size: 10 * scale))
            .foregroundColor(tint == .secondary ? .secondary.opacity(0.6) : tint.opacity(0.95))
            .padding(.horizontal, 4)
            .padding(.vertical, 1)
            .background(RoundedRectangle(cornerRadius: 3).fill(tint.opacity(0.12)))
            .help("\(due.title) — due \(Self.full.string(from: due.date))")
    }

    private static let full: DateFormatter = {
        let f = DateFormatter(); f.dateStyle = .full; return f
    }()
}

// MARK: - Project row

private struct ProjectRowView: View {
    let project: VaultProjectService.Project
    /// A child renders inset beneath its parent row.
    let isChild: Bool
    /// max(updated:, latest session) — the recency shown as the row's age. On
    /// a parent it spans the children too, since that is what the row is
    /// bucketed by.
    let effectiveDate: Date
    /// The day the chip and the age are read against (`VaultTabView.today`).
    let today: Date
    /// Live interactive-session counts for this row: a project's own, or on a
    /// parent its own plus its children's. Passed by value (not read off
    /// `AgentsService` here) so the row does not subscribe to the 2s roster
    /// republish — this list is deliberately non-lazy and fully realized.
    let liveSessions: LiveSessionCounts
    /// This project's own live sessions, one line each, listed under the row.
    let sessionLines: [LiveSessionLine]
    /// The process trees its ended sessions left running, one line each
    /// under the sessions (`LostTreeLineView`).
    let lostTrees: [StrayTree]
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

    /// Leading inset that marks a row as a child of the row above it.
    private static let childInset: CGFloat = 18

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            ForEach(sessionLines) { line in
                SessionLineView(line: line, inset: (isChild ? Self.childInset : 4) + 12) {
                    if let s = badgeSessionsProvider().first(where: { $0.id == line.id }) { open(s) } else { NSSound.beep() }
                }
            }
            ForEach(lostTrees) { LostTreeLineView(tree: $0, inset: (isChild ? Self.childInset : 4) + 12) }
        }
    }

    private var header: some View {
        HStack(spacing: 6) {
            DancingText(text: project.name, size: 14 * scale, weight: isChild ? .regular : .semibold)
            if let light = liveSessions.light {
                HeaderLight(light: light, onTap: focusNextLiveSession)
            }
            if let due = project.nextDue {
                DueChip(due: due, today: today)
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
        .help(hasCwd ? "New session on the iMac, loading project context from the wiki; right-click to choose the machine"
                     : "New session in ~ (no cwds: set yet), loading project context from the wiki")
        .onHover { launchHovering = $0 }
        .contextMenu {
            Button("New session on the iMac") { launch(cwd: launchCwd) }
            Button("New session on the MacBook") { launch(cwd: launchCwd, onThisMac: true) }
        }
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

    /// A badge click: the session that most needs Ben (waiting on him, then
    /// the most recently active) among the row's, a parent's children
    /// included. Every session is also its own line under its row.
    private func focusNextLiveSession() {
        let sessions = badgeSessionsProvider()
        guard let first = sessions.first(where: { $0.light(now: Date()) == .attention }) ?? sessions.first else {
            GhosttyWindowService.activateApp(); return
        }
        open(first)
    }

    /// Put Ben in the session, as a tab of this project's Ghostty window
    /// (`AgentsService.open`). The window is the one another session of the
    /// same project is attached in, when there is one.
    private func open(_ session: AgentSession) {
        let window = ownSessionsProvider().lazy.compactMap(\.attachedGhosttyPid).first
        if !AgentsService.open(session, projectWindow: window, terminalService: terminalService) { NSSound.beep() }
    }

    /// `onThisMac`: the right-click menu's "New session on the MacBook"; a
    /// plain click starts the session on the iMac (`launchClaudeSession`).
    private func launch(cwd: String, onThisMac: Bool = false) {
        _ = performMagicLaunch(projectName: project.name, cwd: cwd,
                               resolvedVaultPath: project.folder.path,
                               liveSessions: ownSessionsProvider(),
                               onThisMac: onThisMac,
                               terminalService: terminalService)
        launched = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.5) { launched = false }
    }

    private func relativeAge(_ date: Date) -> String {
        let days = Int(today.timeIntervalSince(date) / 86400)
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

/// One live session as a project row (or General) lists it. Equatable and
/// free of ages, so a row redraws only when what it shows changes.
struct LiveSessionLine: Identifiable, Equatable {
    let id: String
    let sessionId: String?
    let name: String
    let machine: String
    let isIMac: Bool
    let light: SessionLight
    let hasWindow: Bool

    /// The name is the session's title, the one History shows, so a line
    /// says what the session is doing; a placeholder such as "personal-8c"
    /// (a tmux session name) shows only until a title is written.
    init(_ a: AgentSession, now: Date) {
        id = a.id
        sessionId = a.sessionId
        name = a.title ?? (a.name.isEmpty ? URL(fileURLWithPath: a.cwd).lastPathComponent : a.name)
        hasWindow = a.hasWindow
        isIMac = a.isIMac
        machine = a.isIMac ? "iMac" : a.isRemoteControl ? "phone" : "MacBook"
        light = a.light(now: now)
    }

    /// The lines of these sessions in their order, leftovers last.
    static func lines(_ sessions: [AgentSession], now: Date) -> [LiveSessionLine] {
        SessionLight.leftoversLast(sessions.map { LiveSessionLine($0, now: now) }, light: \.light)
    }
}

/// One session under its project or under General: its dot, its title, its
/// machine in grey. A click opens it (`onOpen`); under the pointer a × stops
/// it at once through the gate's `end` on its machine, with no confirmation
/// (Ben, 2026-11-03). Closing its terminal tab only detaches. A leftover
/// (`SessionLight.dimmed`) shows faded.
struct SessionLineView: View {
    let line: LiveSessionLine
    let inset: CGFloat
    let onOpen: () -> Void
    @Environment(\.fontScale) private var scale
    @State private var hovering = false
    @State private var stopping = false

    var body: some View {
        HStack(spacing: 6) {
            Button(action: onOpen) {
                HStack(spacing: 6) {
                    Circle().fill(line.light.color)
                        .frame(width: 6, height: 6).frame(width: 10)
                    Text(line.name)
                        .font(.system(size: 11.5 * scale))
                        .foregroundColor(.primary.opacity(line.hasWindow ? 0.85 : 0.6))
                        .lineLimit(1).truncationMode(.tail)
                    Spacer(minLength: 8)
                    Text(line.machine)
                        .font(.custom("Fira Code", size: 9.5 * scale))
                        .foregroundColor(.secondary.opacity(0.7))
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help(line.hasWindow ? "Click to bring its tab forward." : "Not open in a terminal here: click to open it in a new tab.")
            Button(action: stop) {
                Image(systemName: "xmark")
                    .font(.system(size: 9 * scale, weight: .semibold))
                    .foregroundColor(.secondary)
                    .frame(width: 12)
            }
            .buttonStyle(.plain)
            .opacity(hovering && !stopping ? 1 : 0)
            .disabled(!hovering || stopping || line.sessionId == nil)
            .help("Stop this session")
        }
        .padding(.leading, inset)
        .padding(.trailing, 4)
        .padding(.vertical, 2)
        .background(RoundedRectangle(cornerRadius: 4).fill(Color.primary.opacity(hovering ? 0.08 : 0)))
        .opacity(stopping ? 0.35 : line.light == .dimmed ? 0.45 : 1)
        .onHover { hovering = $0 }
    }

    private func stop() {
        guard let sid = line.sessionId else { return }
        stopping = true
        let onIMac = line.isIMac, name = line.name
        Task.detached(priority: .userInitiated) {
            let failure = AgentsService.end(sessionId: sid, onIMac: onIMac)
            await MainActor.run {
                guard let failure else { return }
                stopping = false
                let alert = NSAlert()
                alert.alertStyle = .warning
                alert.messageText = "The session did not stop"
                alert.informativeText = "\(failure)\n\n\(name)"
                alert.runModal()
            }
        }
    }
}

/// One process tree left hanging, its session gone (Ben, 2026-11-06: "a
/// hanging process should get a red dot and a cancel button"): a red dot,
/// its command, its machine and age in grey, and a × that stops the whole
/// tree through the gate's `reap` on its machine, with no confirmation. The Mac's scan misses trees made only of Apple's
/// own binaries, so no line there does not mean nothing is left.
struct LostTreeLineView: View {
    let tree: StrayTree
    let inset: CGFloat
    @Environment(\.fontScale) private var scale
    @State private var hovering = false
    @State private var stopping = false

    var body: some View {
        HStack(spacing: 6) {
            Circle().fill(Color.red)
                .frame(width: 6, height: 6).frame(width: 10)
            Text(tree.command)
                .font(.custom("Fira Code", size: 10.5 * scale))
                .foregroundColor(.primary.opacity(0.6))
                .lineLimit(1).truncationMode(.tail)
            Spacer(minLength: 8)
            Text("\(tree.host == .iMac ? "iMac" : "MacBook") · \(Self.age(tree.seconds))")
                .font(.custom("Fira Code", size: 9.5 * scale))
                .foregroundColor(.secondary.opacity(0.7))
            Button(action: stop) {
                Image(systemName: "xmark")
                    .font(.system(size: 9 * scale, weight: .semibold))
                    .foregroundColor(.secondary.opacity(hovering ? 1 : 0.6))
                    .frame(width: 12)
            }
            .buttonStyle(.plain)
            .disabled(stopping)
            .help("Stop this process and everything it started")
        }
        .padding(.leading, inset)
        .padding(.trailing, 4)
        .padding(.vertical, 2)
        .background(RoundedRectangle(cornerRadius: 4).fill(Color.primary.opacity(hovering ? 0.08 : 0)))
        .opacity(stopping ? 0.35 : 1)
        .onHover { hovering = $0 }
        .help("Left running by a session that has ended: \(tree.command)\n\(tree.processes) process\(tree.processes == 1 ? "" : "es") in \(tree.cwd.isEmpty ? "?" : tree.cwd)")
    }

    /// "12m", "5h", "3d".
    static func age(_ seconds: Int) -> String {
        if seconds < 3600 { return "\(max(seconds / 60, 1))m" }
        if seconds < 86400 { return "\(seconds / 3600)h" }
        return "\(seconds / 86400)d"
    }

    private func stop() {
        stopping = true
        let tree = tree
        Task.detached(priority: .userInitiated) {
            let failure = HostProcs.reap(tree)
            await MainActor.run {
                guard let failure else { return }
                stopping = false
                let alert = NSAlert()
                alert.alertStyle = .warning
                alert.messageText = "The process did not stop"
                alert.informativeText = "\(failure)\n\n\(tree.command)"
                alert.runModal()
            }
        }
    }
}

extension SessionLight {
    /// The dot: green running, orange holding a long shell command or work
    /// left out, red
    /// for anything that needs Ben (dimmed lines fade the red).
    var color: Color {
        switch self {
        case .running: return .green
        case .holding: return .orange
        case .attention, .dimmed: return .red
        }
    }
}
