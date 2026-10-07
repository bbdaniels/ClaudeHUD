import SwiftUI

// MARK: - Dynamic Font Scale

private struct FontScaleKey: EnvironmentKey {
    static let defaultValue: CGFloat = 1.0
}

extension EnvironmentValues {
    var fontScale: CGFloat {
        get { self[FontScaleKey.self] }
        set { self[FontScaleKey.self] = newValue }
    }
}

extension Font {
    // MARK: - App Fonts (change family names here only)
    private static let bodyFamily = "Fira Sans"
    private static let codeFamily = "Fira Code"

    static func bodyFont(_ s: CGFloat) -> Font { .custom(bodyFamily, size: 17 * s) }
    static func bodyMedium(_ s: CGFloat) -> Font { .custom(bodyFamily, size: 17 * s).weight(.medium) }
    static func bodySemibold(_ s: CGFloat) -> Font { .custom(bodyFamily, size: 17 * s).weight(.semibold) }
    static func smallFont(_ s: CGFloat) -> Font { .custom(bodyFamily, size: 14 * s) }
    static func smallMedium(_ s: CGFloat) -> Font { .custom(bodyFamily, size: 14 * s).weight(.semibold) }
    static func captionFont(_ s: CGFloat) -> Font { .custom(bodyFamily, size: 12.5 * s) }
    static func codeFont(_ s: CGFloat) -> Font { .custom(codeFamily, size: 15.5 * s) }
    static func codeLarge(_ s: CGFloat) -> Font { .custom(codeFamily, size: 16.5 * s) }
}

// MARK: - Link Highlight (Vox-style)

extension View {
    /// Vox-style warm highlight behind tappable text instead of blue foreground.
    func linkHighlight() -> some View {
        self
            .foregroundColor(.primary)
            .padding(.horizontal, 4)
            .padding(.vertical, 1)
            .background(
                RoundedRectangle(cornerRadius: 3)
                    .fill(Color.yellow.opacity(0.35))
            )
    }
}

// MARK: - Highlighted-Link Markdown Text

/// Renders markdown text with Vox-style yellow-highlighted links instead of blue.
struct HighlightedMarkdownText: View {
    let markdown: String
    let font: Font
    private let attributed: AttributedString

    init(_ markdown: String, font: Font = .body) {
        self.markdown = markdown
        self.font = font
        self.attributed = Self.highlightLinks(in: markdown)
    }

    var body: some View {
        Text(attributed)
            .font(font)
            .tint(Color.primary)
            .textSelection(.enabled)
            .lineSpacing(3)
            .environment(\.openURL, OpenURLAction { url in
                NSWorkspace.shared.open(url)
                return .handled
            })
    }

    static func highlightLinks(in markdown: String) -> AttributedString {
        guard var result = try? AttributedString(markdown: markdown,
                options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)) else {
            return AttributedString(markdown)
        }
        let highlight = NSColor.systemYellow.withAlphaComponent(0.35)
        for run in result.runs {
            if run.link != nil {
                result[run.range].backgroundColor = highlight
                result[run.range].foregroundColor = NSColor.labelColor
            }
        }
        return result
    }
}

enum FixedTab: String, CaseIterable {
    // User-facing labels (one word each, also used as tooltips):
    //   history   → "Sessions"  — past Claude Code sessions
    //   library   → "Claude"    — background agents + Claude internals
    //   vault     → "Projects"  — vault-driven per-project browser
    //   today     → "Today"     — schedule, briefing, daily note
    //
    // Tab order is the enum declaration order. History first.
    //
    // Killed tabs kept inert in services (push notif, permission watcher,
    // AgentsService standalone tab, obsidian
    // Notes tab — Daily Notes are now in Today). Raw values stay so
    // hiddenTabs UserDefaults entries from older builds keep meaning.
    case history
    case library
    case vault
    case today

    var icon: String {
        switch self {
        case .history: return "clock.arrow.circlepath"
        case .vault: return "briefcase"               // overridden by ClaudeLogo asset; see assetIcon.
        case .today: return "calendar"
        case .library: return "books.vertical.fill"
        }
    }

    /// Image asset name to use INSTEAD of the SF Symbol for this tab, when set.
    /// The Projects tab wears the Claude logo (it absorbed the header's old
    /// standalone logo, 2026-08-31); Library keeps its SF Symbol so the logo
    /// stays unique in the strip.
    var assetIcon: String? {
        switch self {
        case .vault: return "ClaudeLogo"
        default: return nil
        }
    }

    var label: String {
        switch self {
        case .history: return "Sessions"
        case .vault: return "Projects"
        case .today: return "Today"
        case .library: return "Claude"
        }
    }

    // One-word tooltips matching the labels. The longer `detail` field
    // (below) still carries the descriptive explanation for the info
    // popover.
    var help: String { label }

    var detail: String {
        switch self {
        case .history: return "Browse and resume past Claude Code sessions"
        case .vault: return "Per-project status, tasks, and notes from the Karpathy archive"
        case .today: return "Schedule, AI briefing, and today's daily note"
        case .library: return "Background sessions pinned on top; Claude internals (skills, agents, hooks, rules, MCP, settings) below"
        }
    }

    /// Tabs that cannot be hidden. Projects is the spine (the undeletable
    /// home), so the anchor moved off `.history` → `.vault` in the 6→4
    /// consolidation.
    var isRequired: Bool { self == .vault }

    static func hiddenTabs() -> Set<String> {
        let raw = UserDefaults.standard.string(forKey: "hiddenTabs") ?? ""
        return Set(raw.split(separator: ",").map(String.init)).subtracting([""])
    }

    static func setHidden(_ tab: FixedTab, hidden: Bool) {
        var current = hiddenTabs()
        if hidden { current.insert(tab.rawValue) } else { current.remove(tab.rawValue) }
        UserDefaults.standard.set(current.sorted().joined(separator: ","), forKey: "hiddenTabs")
    }

    static func isHidden(_ tab: FixedTab) -> Bool {
        hiddenTabs().contains(tab.rawValue)
    }

    /// User-customized tab order (drag-to-reorder in the tab bar), persisted in
    /// UserDefaults `tabOrder` as comma-separated raw values. Any tabs not listed
    /// — e.g. a tab added in a newer build — are appended in declaration order,
    /// so the saved order never hides a new tab. Falls back to declaration order
    /// when nothing is saved.
    static func orderedTabs() -> [FixedTab] {
        let raw = UserDefaults.standard.string(forKey: "tabOrder") ?? ""
        let saved = raw.split(separator: ",").compactMap { FixedTab(rawValue: String($0)) }
        var seen = Set(saved)
        let appended = allCases.filter { !seen.contains($0) }
        seen.formUnion(appended)
        let result = saved + appended
        return result.isEmpty ? allCases : result
    }

    static func setOrder(_ tabs: [FixedTab]) {
        UserDefaults.standard.set(tabs.map(\.rawValue).joined(separator: ","), forKey: "tabOrder")
    }
}

struct HUDContentView: View {
    @EnvironmentObject var appState: AppState
    @EnvironmentObject var tabManager: TabManager
    @EnvironmentObject var terminalService: TerminalService
    @EnvironmentObject var sessionHistory: SessionHistoryService
    @EnvironmentObject var vaultManager: VaultManager
    @State private var showTerminalPopover = false
    @State private var showInfoPopover = false
    @State private var activeFixedTab: FixedTab? = .vault
    @State private var fontScale: CGFloat = 1.0

    var body: some View {
        VStack(spacing: 0) {
            // Header — one row: tabs on the left, readouts and actions on the
            // right. The tab strip is the flexible element, so it doubles as
            // the spacer.
            HStack(spacing: 8) {
                TabBar(activeFixedTab: $activeFixedTab)

                UsageBadge()

                PermissionModeMenu()

                Button(action: {
                    terminalService.launchClaudeAtHome()
                }) {
                    Text(">_")
                        .font(.codeFont(fontScale))
                        .foregroundColor(.secondary)
                }
                .buttonStyle(.borderless)
                .hudTip("New Claude session at ~")
                .simultaneousGesture(LongPressGesture(minimumDuration: 0.4).onEnded { _ in
                    showTerminalPopover = true
                })
                .popover(isPresented: $showTerminalPopover) {
                    TerminalPopover()
                        .environmentObject(terminalService)
                }

                Button(action: { showInfoPopover.toggle() }) {
                    Image(systemName: "info.circle")
                        .font(.smallFont(fontScale))
                        .foregroundColor(.secondary)
                }
                .buttonStyle(.borderless)
                .hudTip("Setup & Info")
                .popover(isPresented: $showInfoPopover) {
                    InfoPopover()
                }

                Button(action: { appState.screenCoverService.cover() }) {
                    Image(systemName: "lock.fill")
                        .font(.smallFont(fontScale))
                        .foregroundColor(.secondary)
                }
                .buttonStyle(.borderless)
                .hudTip("Cover screen — input locked, agents keep running")
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 8)

            Divider()
                .opacity(0.5)

            // Main content
            if let fixedTab = activeFixedTab {
                switch fixedTab {
                case .history:
                    SessionHistoryView()
                        .environmentObject(sessionHistory)
                        .environmentObject(terminalService)
                        // For the project tag and its unclaimed marker: same canonical resolver
                        // cache the Projects spine uses (inverse of the WORK filter).
                        .environmentObject(appState.vaultProjectService)
                case .vault:
                    VaultTabView()
                        .environmentObject(appState.vaultProjectService)
                        .environmentObject(appState.vaultIngestService)
                        .environmentObject(appState.vaultScriptInstaller)
                        .environmentObject(vaultManager)
                        // Harvested spine dependencies (sessions, terminal,
                        // tabManager, cross-ProjectService, calendar come from
                        // the panel root). Agents injected here because only the
                        // Projects/Library tabs use the live roster. (Recent
                        // activity reads pre-computed Session Log digests — no
                        // LLM call at view time.)
                        .environmentObject(appState.agentsService)
                case .today:
                    TodayView()
                        .environmentObject(vaultManager)
                case .library:
                    LibraryView()
                        .environmentObject(appState.libraryService)
                        .environmentObject(terminalService)
                }
            } else {
                TerminalTabView(sessionId: tabManager.selectedTabId)
                    .id(tabManager.selectedTabId)
                    .environmentObject(appState)
            }
        }
        .frame(minWidth: 380, minHeight: 420)
        .environment(\.fontScale, fontScale)
        .onChange(of: tabManager.tabs.isEmpty) { _, isEmpty in
            // Closing the last terminal tab leaves nothing for the `nil`
            // (tab-selected) state to render, so fall back to a fixed tab.
            if isEmpty && activeFixedTab == nil {
                activeFixedTab = FixedTab.orderedTabs().first { !FixedTab.isHidden($0) } ?? .vault
            }
        }
        .onGeometryChange(for: CGFloat.self) { geo in
            geo.size.width
        } action: { width in
            let newScale = max(0.85, min(1.4, width / 420))
            // Only update if the change is meaningful (> 0.01) to avoid layout loops
            // from sub-pixel width jitter (e.g., scrollbar show/hide)
            if abs(newScale - fontScale) > 0.01 {
                fontScale = newScale
            }
        }
        .overlay(
            Button("") {
                tabManager.closeTab(tabManager.selectedTabId)
            }
            .keyboardShortcut("w", modifiers: .command)
            .frame(width: 0, height: 0)
            .hidden()
        )
        .hudTooltipLayer()
    }
}

// MARK: - Tab Bar

struct TabBar: View {
    @Binding var activeFixedTab: FixedTab?
    @EnvironmentObject var tabManager: TabManager
    @Environment(\.fontScale) private var scale
    @AppStorage("hiddenTabs") private var hiddenTabsRaw: String = ""
    // Read the persisted order so the bar re-renders when it changes.
    @AppStorage("tabOrder") private var tabOrderRaw: String = ""
    @State private var draggingTab: FixedTab?
    @State private var dragOffset: CGFloat = 0

    /// Visual width of one fixed-tab slot (matches the icon frame below; the
    /// HStack spacing is 0). Used to convert drag distance → slots moved.
    private let tabSlotWidth: CGFloat = 28

    private var visibleTabs: [FixedTab] {
        let hidden = FixedTab.hiddenTabs()
        return FixedTab.orderedTabs().filter { !hidden.contains($0.rawValue) }
    }

    /// Move `tab` by `slots` positions among the visible tabs, rewriting the
    /// persisted full order (hidden tabs keep their relative spots). Writing
    /// `tabOrderRaw` persists to UserDefaults AND re-renders; `orderedTabs()`
    /// reads it back.
    private func moveTab(_ tab: FixedTab, by slots: Int) {
        let vis = visibleTabs
        guard let idx = vis.firstIndex(of: tab) else { return }
        let newIdx = max(0, min(vis.count - 1, idx + slots))
        guard newIdx != idx else { return }
        let landOn = vis[newIdx]
        var order = FixedTab.orderedTabs()
        guard let from = order.firstIndex(of: tab) else { return }
        order.remove(at: from)
        guard let to = order.firstIndex(of: landOn) else { return }
        let insertAt = slots > 0 ? to + 1 : to
        order.insert(tab, at: min(max(insertAt, 0), order.count))
        withAnimation(.easeInOut(duration: 0.18)) {
            tabOrderRaw = order.map(\.rawValue).joined(separator: ",")
        }
    }

    var body: some View {
        HStack(spacing: 0) {
            // Fixed view tabs. Deliberately NOT inside the horizontal ScrollView
            // (its pan gesture swallowed the reorder drag) and NOT Buttons (the
            // button press gesture competed with it). Plain tappable icons + a
            // manual DragGesture: a click switches tab, a >6pt sideways drag
            // reorders. (Also needs the panel's isMovableByWindowBackground off
            // — see HUDPanelController — so window-move doesn't eat the drag.)
            HStack(spacing: 0) {
                ForEach(visibleTabs, id: \.rawValue) { tab in
                    fixedTab(tab)
                }
            }

            if !tabManager.tabs.isEmpty {
                Divider()
                    .frame(height: 16)
                    .padding(.horizontal, 4)
            }

            // Terminal tabs can overflow, so they keep the horizontal scroll.
            // Empty when no session has been resumed into the HUD, in which
            // case the scroll view is just the header's flexible gap.
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 0) {
                    ForEach(tabManager.tabs) { tab in
                        TabButton(tab: tab, activeFixedTab: $activeFixedTab)
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    @ViewBuilder
    private func fixedTab(_ tab: FixedTab) -> some View {
        Group {
            if let asset = tab.assetIcon {
                // Brand-colored (orange) and slightly larger than the SF
                // symbols: Projects is the control panel, so its glyph anchors
                // the strip. Dim, don't tint, when inactive.
                Image(asset)
                    .resizable()
                    .scaledToFit()
                    .frame(width: 15 * scale, height: 15 * scale)
                    .opacity(activeFixedTab == tab ? 1.0 : 0.55)
            } else {
                Image(systemName: tab.icon)
                    .font(.captionFont(scale))
                    .foregroundColor(activeFixedTab == tab ? .primary : .secondary)
            }
        }
        .frame(width: 28, height: 24)
        .background(
            RoundedRectangle(cornerRadius: 5)
                .fill(activeFixedTab == tab ? Color.accentColor.opacity(0.12) : Color.clear)
        )
        .contentShape(Rectangle())
        .onTapGesture { activeFixedTab = tab }
        .hudTip(tab.help)
        .opacity(draggingTab == tab ? 0.6 : 1.0)
        .offset(x: draggingTab == tab ? dragOffset : 0)
        .zIndex(draggingTab == tab ? 1 : 0)
        // Manual drag-to-reorder: the icon follows the cursor and snaps to the
        // nearest slot on release. No ScrollView/Button competing now, so a
        // plain `.gesture` is enough.
        .gesture(
            DragGesture(minimumDistance: 6)
                .onChanged { value in
                    if draggingTab != tab { draggingTab = tab }
                    dragOffset = value.translation.width
                }
                .onEnded { value in
                    let slots = Int((value.translation.width / tabSlotWidth).rounded())
                    if slots != 0 { moveTab(tab, by: slots) }
                    draggingTab = nil
                    dragOffset = 0
                }
        )
    }
}

struct TabButton: View {
    let tab: ConversationTab
    @Binding var activeFixedTab: FixedTab?
    @EnvironmentObject var tabManager: TabManager
    @Environment(\.fontScale) private var scale

    private var isSelected: Bool {
        activeFixedTab == nil && tabManager.selectedTabId == tab.id
    }

    var body: some View {
        HStack(spacing: 4) {
            Image(systemName: "terminal")
                .font(.smallFont(scale))
                .foregroundColor(isSelected ? .accentColor : .secondary)

            if let subtitle = tab.subtitle, !subtitle.isEmpty {
                HStack(spacing: 2) {
                    Image(systemName: "arrow.triangle.branch")
                        .font(.system(size: 8 * scale, weight: .semibold))
                    Text(subtitle)
                        .font(.custom("Fira Code", size: 10 * scale))
                        .lineLimit(1)
                }
                .foregroundColor(.purple)
                .padding(.horizontal, 4)
                .padding(.vertical, 1)
                .background(RoundedRectangle(cornerRadius: 3).fill(Color.purple.opacity(0.15)))
                .hudTip("Worktree: \(subtitle)")
            }

            Text(tab.title)
                .font(.smallFont(scale))
                .lineLimit(1)
                .foregroundColor(isSelected ? .primary : .secondary)

            Button(action: { tabManager.closeTab(tab.id) }) {
                Image(systemName: "xmark")
                    .font(.custom("Fira Sans", size: 8 * scale).weight(.bold))
                    .foregroundColor(.secondary.opacity(0.6))
            }
            .buttonStyle(.borderless)
            .hudTip("Close tab")
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 5)
        .background(
            RoundedRectangle(cornerRadius: 5)
                .fill(isSelected ? Color.accentColor.opacity(0.12) : Color.clear)
        )
        .contentShape(Rectangle())
        .onTapGesture {
            activeFixedTab = nil
            tabManager.selectedTabId = tab.id
        }
    }
}

// MARK: - Session History View

/// Recency buckets for the History tab, newest first. One bucket rule for
/// every session row; the section order is `allCases` order.
enum RecencyBucket: Int, CaseIterable {
    case today, yesterday, thisWeek, thisMonth, older

    init(for date: Date, now: Date = Date()) {
        let cal = Calendar.current
        let startOfToday = cal.startOfDay(for: now)
        let startOfYesterday = cal.date(byAdding: .day, value: -1, to: startOfToday)!
        let startOfWeek = cal.date(byAdding: .day, value: -7, to: startOfToday)!
        let startOfMonth = cal.date(byAdding: .day, value: -30, to: startOfToday)!
        if date >= startOfToday { self = .today }
        else if date >= startOfYesterday { self = .yesterday }
        else if date >= startOfWeek { self = .thisWeek }
        else if date >= startOfMonth { self = .thisMonth }
        else { self = .older }
    }

    var title: String {
        switch self {
        case .today: return "Today"
        case .yesterday: return "Yesterday"
        case .thisWeek: return "This Week"
        case .thisMonth: return "This Month"
        case .older: return "Older"
        }
    }
}

/// One History row: a session plus its project attribution (shown as a tag,
/// not a grouping).
struct SessionHistoryRow: Identifiable {
    let session: SessionInfo
    /// Resolved Obsidian project name, else the repo folder name.
    let project: String
    /// The cwd resolves to no vault project (the Session Inbox set).
    let isUnclaimed: Bool
    var id: String { session.id }
}

struct SessionHistoryView: View {
    @EnvironmentObject var sessionHistory: SessionHistoryService
    @EnvironmentObject var vaultProjects: VaultProjectService
    @Environment(\.fontScale) private var scale
    @State private var searchText = ""
    @State private var resolvePrimed = false
    @State private var searchDebounceTask: Task<Void, Never>?
    @State private var useColors = UserDefaults.standard.bool(forKey: "history.useColors")

    /// Collapse a worktree path back to its parent repo cwd.
    private static func repoCwd(_ p: String) -> String {
        if let range = p.range(of: "/.claude/worktrees/") {
            return String(p[..<range.lowerBound])
        }
        return p
    }

    /// Every session as a row, filtered by search, newest first. The project
    /// is attribution only: the Obsidian project that OWNS the cwd (a writeable
    /// `cwds:` match, via the canonical resolver once primed), else the repo
    /// folder name.
    private var historyRows: [SessionHistoryRow] {
        let home = NSHomeDirectory()
        let q = searchText.lowercased()
        let hasSearchResults = !sessionHistory.searchResults.isEmpty
        return sessionHistory.sessions.compactMap { session -> SessionHistoryRow? in
            let cwd = Self.repoCwd(session.projectPath)
            // Root-level cwds ("/", "/tmp") are not projects; skip as before.
            let parent = cwd == home ? home : URL(fileURLWithPath: cwd).deletingLastPathComponent().path
            guard cwd != "/", parent != "/" else { return nil }
            let vaultName = resolvePrimed ? vaultProjects.folderName(forCwd: cwd) : nil
            let project = vaultName ?? URL(fileURLWithPath: cwd).lastPathComponent
            if !q.isEmpty {
                let hit = project.lowercased().contains(q) ||
                    session.projectName.lowercased().contains(q) ||
                    session.preview.lowercased().contains(q) ||
                    session.projectPath.lowercased().contains(q) ||
                    (hasSearchResults && sessionHistory.searchResults[session.id] != nil)
                guard hit else { return nil }
            }
            return SessionHistoryRow(session: session, project: project,
                                     isUnclaimed: resolvePrimed && vaultName == nil)
        }
        .sorted { $0.session.timestamp > $1.session.timestamp }
    }

    /// Rows partitioned into recency buckets, newest first within each.
    private var sections: [(title: String, rows: [SessionHistoryRow])] {
        let rows = historyRows
        var result: [(title: String, rows: [SessionHistoryRow])] = []
        let now = Date()
        let byBucket = Dictionary(grouping: rows) { RecencyBucket(for: $0.session.timestamp, now: now) }
        for bucket in RecencyBucket.allCases {
            if let group = byBucket[bucket], !group.isEmpty {
                result.append((bucket.title, group))
            }
        }
        return result
    }

    var body: some View {
        VStack(spacing: 0) {
            if sessionHistory.isLoading && sessionHistory.sessions.isEmpty {
                Spacer()
                ProgressView().controlSize(.small)
                Text("Loading sessions...")
                    .font(.smallFont(scale))
                    .foregroundColor(.secondary)
                    .padding(.top, 8)
                Spacer()
            } else if sessionHistory.sessions.isEmpty {
                Spacer()
                Image(systemName: "clock.arrow.circlepath")
                    .font(.system(size: 28))
                    .foregroundColor(.secondary.opacity(0.5))
                Text("No sessions found")
                    .font(.smallFont(scale))
                    .foregroundColor(.secondary)
                    .padding(.top, 6)
                Spacer()
            } else {
                // Search bar
                HStack(spacing: 6) {
                    Image(systemName: "magnifyingglass")
                        .font(.system(size: 11 * scale))
                        .foregroundColor(.secondary)
                    TextField("Search sessions...", text: $searchText)
                        .font(.smallFont(scale))
                        .textFieldStyle(.plain)
                        .onChange(of: searchText) { newValue in
                            searchDebounceTask?.cancel()
                            if newValue.isEmpty {
                                sessionHistory.search(query: "")
                            } else {
                                searchDebounceTask = Task {
                                    try? await Task.sleep(nanoseconds: 300_000_000)
                                    guard !Task.isCancelled else { return }
                                    sessionHistory.search(query: newValue)
                                }
                            }
                        }
                    if sessionHistory.isSearching {
                        ProgressView()
                            .scaleEffect(0.5)
                            .frame(width: 12, height: 12)
                    }
                    if !searchText.isEmpty {
                        Button(action: { searchText = "" }) {
                            Image(systemName: "xmark.circle.fill")
                                .font(.system(size: 11 * scale))
                                .foregroundColor(.secondary)
                        }
                        .buttonStyle(.borderless)
                        .hudTip("Clear search")
                    }
                    Button(action: {
                        useColors.toggle()
                        UserDefaults.standard.set(useColors, forKey: "history.useColors")
                    }) {
                        Image(systemName: useColors ? "paintpalette.fill" : "paintpalette")
                            .font(.system(size: 11 * scale))
                            .foregroundColor(useColors ? .accentColor : .secondary)
                    }
                    .buttonStyle(.borderless)
                    .hudTip(useColors ? "Project colors ON" : "Project colors OFF")
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 6)
                .background(Color(.textBackgroundColor).opacity(0.3))

                Divider().opacity(0.3)

                // `sections` filters + sorts every session; evaluate once.
                let secs = sections
                if secs.isEmpty {
                    Spacer()
                    Text("No matches")
                        .font(.smallFont(scale))
                        .foregroundColor(.secondary)
                    Spacer()
                } else {
                    ScrollView {
                        VStack(spacing: 0) {
                            ForEach(secs, id: \.title) { section in
                                TimeSectionView(
                                    title: section.title,
                                    rows: section.rows,
                                    searchResults: sessionHistory.searchResults,
                                    onDeleteSession: { deleteSession($0) }
                                )
                            }
                        }
                        .padding(.horizontal, 10)
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .onAppear {
            Task { await sessionHistory.refresh() }
        }
        // Prime the canonical cwd→folder cache for every repo cwd (worktrees
        // merged), so row tags resolve to the vault project and the unclaimed
        // marker can show. Re-runs when the session set changes; cheap on
        // repeat (only new cwds are scanned). Read-only.
        .task(id: sessionHistory.sessions.count) {
            let paths = Set(sessionHistory.sessions.map { Self.repoCwd($0.projectPath) })
            await vaultProjects.primeResolution(forCwds: paths)
            resolvePrimed = true
        }
    }

    private func deleteSession(_ sessionId: String) {
        sessionHistory.deleteSession(id: sessionId)
    }
}

// MARK: - Collapsible Time Section

struct TimeSectionView: View {
    let title: String
    let rows: [SessionHistoryRow]
    let searchResults: [String: SessionSearchResult]
    let onDeleteSession: (String) -> Void
    @State private var collapsed = false
    @State private var showAll = false
    @Environment(\.fontScale) private var scale

    /// The list is non-lazy (variable-height rows), so a long bucket renders
    /// its newest rows and a "Show all" toggle rather than thousands at once.
    private let rowCap = 40

    private var visibleRows: [SessionHistoryRow] {
        showAll || rows.count <= rowCap ? rows : Array(rows.prefix(rowCap))
    }

    var body: some View {
        // Section header
        HStack(spacing: 4) {
            Image(systemName: collapsed ? "chevron.right" : "chevron.down")
                .font(.system(size: 9 * scale, weight: .semibold))
                .foregroundColor(.secondary.opacity(0.5))
            Text(title)
                .font(.captionFont(scale).weight(.semibold))
                .foregroundColor(.secondary.opacity(0.7))
                .textCase(.uppercase)
            if collapsed {
                Text("\(rows.count)")
                    .font(.custom("Fira Code", size: 10 * scale))
                    .foregroundColor(.secondary.opacity(0.6))
                    .padding(.horizontal, 4)
                    .padding(.vertical, 1)
                    .background(RoundedRectangle(cornerRadius: 3).fill(Color.secondary.opacity(0.1)))
            }
            Spacer()
        }
        .padding(.horizontal, 4)
        .padding(.top, 10)
        .padding(.bottom, 4)
        .contentShape(Rectangle())
        .onTapGesture {
            withAnimation(.easeInOut(duration: 0.15)) { collapsed.toggle() }
        }
        .hudTip(collapsed ? "Expand section" : "Collapse section")

        if !collapsed {
            ForEach(visibleRows) { row in
                SessionDetailRow(
                    session: row.session,
                    searchResult: searchResults[row.session.id],
                    onDelete: { onDeleteSession(row.session.id) },
                    projectTag: (name: row.project, isUnclaimed: row.isUnclaimed)
                )
                .padding(.horizontal, 4)
                Divider().opacity(0.3)
            }

            if rows.count > rowCap {
                Button(action: { withAnimation(.easeInOut(duration: 0.15)) { showAll.toggle() } }) {
                    Text(showAll ? "Show less" : "Show all \(rows.count) sessions")
                        .font(.custom("Fira Sans", size: 11 * scale))
                        .foregroundColor(.accentColor)
                }
                .buttonStyle(.borderless)
                .padding(.vertical, 4)
            }
        }
    }
}

// MARK: - Launch permission mode (global)

/// The single, global permission mode every ClaudeHUD-launched session
/// starts in. Chosen from the header picker and persisted in
/// `UserDefaults` (`launch.permissionMode`); read at launch time by
/// `permissionModeFlag()`, which every launch path (magic launch, `>_` at
/// `~`, resume, HUD tab) folds into its `claude` invocation. One control,
/// one source of truth — no per-row or per-launch override (user directive
/// 2026-09-03: "a single global mode control at the top").
enum LaunchPermissionMode: String, CaseIterable, Identifiable {
    /// No flag: Claude Code's own configured default.
    case inherit = ""
    case manual = "manual"
    case acceptEdits = "acceptEdits"
    case plan = "plan"
    case auto = "auto"
    case bypass = "bypassPermissions"

    var id: String { rawValue }

    static let defaultsKey = "launch.permissionMode"

    static var current: LaunchPermissionMode {
        get {
            let raw = UserDefaults.standard.string(forKey: defaultsKey) ?? ""
            return LaunchPermissionMode(rawValue: raw) ?? .inherit
        }
        set { UserDefaults.standard.set(newValue.rawValue, forKey: defaultsKey) }
    }

    /// Menu label.
    var title: String {
        switch self {
        case .inherit: return "Default (Claude's setting)"
        case .manual: return "Manual — ask every time"
        case .acceptEdits: return "Accept edits"
        case .plan: return "Plan"
        case .auto: return "Auto"
        case .bypass: return "Bypass permissions"
        }
    }

    /// Compact header readout.
    var shortTitle: String {
        switch self {
        case .inherit: return "default"
        case .manual: return "manual"
        case .acceptEdits: return "edits"
        case .plan: return "plan"
        case .auto: return "auto"
        case .bypass: return "bypass"
        }
    }

    /// Header color — the only visible signal of the current mode.
    var color: Color {
        switch self {
        case .inherit: return .secondary
        case .manual: return .blue
        case .acceptEdits: return .green
        case .plan: return .purple
        case .auto: return .yellow
        case .bypass: return .red
        }
    }

    var symbol: String {
        switch self {
        case .inherit: return "shield"
        case .manual: return "hand.raised"
        case .acceptEdits: return "pencil"
        case .plan: return "list.bullet.clipboard"
        case .auto: return "bolt"
        case .bypass: return "shield.slash"
        }
    }

    /// The CLI argument (leading space) or empty for `.inherit`.
    var cliFlag: String {
        rawValue.isEmpty ? "" : " --permission-mode \(rawValue)"
    }
}

/// The `--permission-mode` fragment for the currently selected global mode.
func permissionModeFlag() -> String { LaunchPermissionMode.current.cliFlag }

/// Header picker: one global control for the mode every launch uses.
struct PermissionModeMenu: View {
    @AppStorage(LaunchPermissionMode.defaultsKey) private var raw: String = ""
    @Environment(\.fontScale) private var scale

    private var mode: LaunchPermissionMode { LaunchPermissionMode(rawValue: raw) ?? .inherit }

    var body: some View {
        Menu {
            ForEach(LaunchPermissionMode.allCases) { m in
                Button {
                    raw = m.rawValue
                } label: {
                    if m == mode {
                        Label(m.title, systemImage: "checkmark")
                    } else {
                        Text(m.title)
                    }
                }
            }
        } label: {
            // Hit target only: AppKit paints a Menu label opaque in its own
            // tint (ignoring opacity), so the label carries no glyph at all.
            Color.clear
                .frame(width: 16 * scale, height: 16 * scale)
                .contentShape(Rectangle())
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        // Glyph only — the header has no room for a label, so the mode is
        // carried by color (user directive 2026-09-03). Drawn BEHIND the
        // menu because a Menu label's foreground color is stripped on macOS.
        .background(glyph)
        .hudTip("Permission mode: \(mode.title)")
    }

    private var glyph: some View {
        Image(systemName: "shield.fill")
            .font(.system(size: 12 * scale, weight: .semibold))
            .foregroundColor(mode.color)
    }
}

// MARK: - Daemon registration

/// Wraps a `claude` invocation so the launched session registers with the
/// background daemon (visible in `claude agents` / Agent View) instead of
/// running as an unregistered foreground REPL that nothing can supervise.
///
/// Why: a plain `claude …` in a terminal tab is attached straight to that
/// PTY and never touches the daemon, so it can't be peeked/answered/stopped
/// from Agent View. Starting with the (undocumented but stable) `--bg` flag
/// hands the session to the daemon; we parse the printed id (ANSI-stripped)
/// and immediately `claude attach` it in the same tab so interaction is
/// unchanged. If `--bg` ever fails or no id is parsed we fall back to a
/// plain foreground `claude`, so a launch can never be broken by this.
///
/// `argSuffix` is everything after `claude` (e.g. ` --resume <id>`, or a
/// prompt). Empty for a plain new session.
///
/// `remoteControlName` — when non-nil, prepends `--remote-control "<name>"`
/// so the session is reachable via Claude Code Remote Control. Names are
/// shell-escaped here. Magic-launched sessions pass the project name so
/// each session is named after the project it serves.
func daemonizedClaudeCommand(_ argSuffix: String, remoteControlName: String? = nil) -> String {
    let rcFlag: String
    if let name = remoteControlName, !name.isEmpty {
        // Single-quote escape: every ' becomes '\'' and wrap in '...'.
        let escaped = name.replacingOccurrences(of: "'", with: "'\\''")
        rcFlag = " --remote-control '\(escaped)'"
    } else {
        rcFlag = ""
    }
    let modeFlag = permissionModeFlag()
    let bg = "claude --bg" + rcFlag + modeFlag + argSuffix
    let plain = "claude" + rcFlag + modeFlag + argSuffix
    return "__o=$(\(bg) 2>&1); "
        + "__i=$(printf '%s' \"$__o\" | perl -pe 's/\\e\\[[0-9;]*m//g' "
        + "| grep -oE 'backgrounded[^0-9a-f]*[0-9a-f]{8}' "
        + "| grep -oE '[0-9a-f]{8}' | tail -1); "
        + "if [ -n \"$__i\" ]; then "
        + "echo \"[registered with daemon: $__i -- run 'claude agents' to supervise]\"; "
        // Closing the window hangs up the pty: the script and attach get
        // SIGHUP, attach exits, and the trap stops the session so it does not
        // linger in the agents manager. attach stays a FOREGROUND child (run
        // in the background it loses the tty and dies with kqueue EINVAL); zsh
        // runs the trap once it returns. A normal detach (Ctrl+Z or the agent
        // view) exits attach with no signal, the trap is cleared, and the
        // session keeps running. Verified live in Ghostty 2026-09-16.
        + "trap 'claude stop \"$__i\" >/dev/null 2>&1; exit 129' HUP TERM; "
        + "claude attach \"$__i\"; "
        + "trap - HUP TERM; "
        + "else printf '%s\\n' \"$__o\"; \(plain); fi"
}

// MARK: - Magic launch (Projects spine)

/// Build the magic-launch argument: a `/vault-bootstrap` slash-command
/// invocation whose expansion (see ~/.claude/commands/vault-bootstrap.md)
/// loads context from the Obsidian vault (the source of truth), not a lossy
/// chat recap. Delivering the bootstrap as a slash command instead of a
/// wall-of-text positional prompt keeps the session's first turn tidy while
/// still auto-running on launch. The single argument is the project name,
/// optionally followed by ` :: <resolvedVaultPath>` — when the path is present
/// the command uses it directly (no index.md re-derivation, no user
/// confirmation); when absent it falls back to index.md resolution. Kept on
/// one line so it survives every delivery path (Ghostty temp script,
/// Terminal/iTerm AppleScript `do script`, clipboard).
func magicLaunchArg(projectName: String, resolvedVaultPath: String?) -> String {
    if let vaultPath = resolvedVaultPath, !vaultPath.isEmpty {
        return "/vault-bootstrap \(projectName) :: \(vaultPath)"
    }
    return "/vault-bootstrap \(projectName)"
}

/// Fire a magic launch for `projectName` rooted at repo `cwd`, loading vault
/// context. `resolvedVaultPath` non-nil → folder already resolved (the Projects
/// spine knows it directly; Session History resolves it via the canonical
/// `vaultFolderPath`). Returns whether the terminal auto-opened (false →
/// clipboard fallback). Enables Remote Control named after the project so each
/// session is identifiable in the agents list.
///
/// `liveSessions` are the project's OWN live interactive sessions, most recent
/// first (`VaultProjectService.liveSessions(forFolders:in:)` with that one
/// folder). If one of them is attached in a Ghostty window, the new session
/// opens as a tab there instead of in a new window. A parent project passes
/// only its own sessions, never its children's, so a parent launch cannot land
/// in a child's window.
@MainActor
func performMagicLaunch(projectName: String, cwd: String, resolvedVaultPath: String?,
                        liveSessions: [AgentSession] = [],
                        terminalService: TerminalService) -> Bool {
    let arg = magicLaunchArg(projectName: projectName, resolvedVaultPath: resolvedVaultPath)
    // Single-quote the arg for the shell (every ' becomes '\'' and the whole
    // string is wrapped in '...') so spaces in the project name or vault path
    // stay a single token and any ' in them cannot break out of the quoting.
    let escapedArg = arg.replacingOccurrences(of: "'", with: "'\\''")
    return launchClaudeSession(argSuffix: " '\(escapedArg)'", name: projectName, cwd: cwd,
                               existingGhosttyPid: liveSessions.compactMap(\.attachedGhosttyPid).first,
                               terminalService: terminalService)
}

/// THE HUD launch path for a Claude session: a new Ghostty window, or a new
/// tab in `existingGhosttyPid`'s window when the project already has one
/// (titled, folder pre-trusted by `launchWithCommand`) running the daemon-registered
/// `claude --bg … ` + `claude attach` form, so the session is in the roster
/// and gets its Projects/Agents badges and click-to-focus. Used by the wiki
/// launch and History's >_ resume. A foreground `claude` does NOT register
/// (verified 2026-09-16: no roster worker, no jobs dir).
@MainActor
@discardableResult
func launchClaudeSession(argSuffix: String, name: String, cwd: String,
                         existingGhosttyPid: pid_t? = nil,
                         terminalService: TerminalService) -> Bool {
    let command = daemonizedClaudeCommand(argSuffix, remoteControlName: name)
    let ghosttyPath = "/Applications/Ghostty.app"
    let app = FileManager.default.fileExists(atPath: ghosttyPath) ? ghosttyPath : nil
    let useColors = UserDefaults.standard.bool(forKey: "history.useColors")
    let bg = useColors ? TerminalService.projectColor(for: name) : nil
    return terminalService.launchWithCommand(command, inDirectory: cwd, usingApp: app, backgroundColor: bg,
                                             existingGhosttyPid: existingGhosttyPid)
}

// MARK: - Session Detail Row

/// One session: preview, search snippet, short id, optional project tag, age,
/// and a single `>_` action that resumes it in its original cwd. Shared by the
/// History tab and a project's own session list.
struct SessionDetailRow: View {
    let session: SessionInfo
    let searchResult: SessionSearchResult?
    let onDelete: () -> Void
    /// History tab only: the session's project (resolved Obsidian project,
    /// else repo folder). Nil where the project is already the context.
    var projectTag: (name: String, isUnclaimed: Bool)? = nil
    @EnvironmentObject var terminalService: TerminalService
    @State private var feedback: String?
    @Environment(\.fontScale) private var scale

    /// The `>_` action resumes in Ghostty.
    private var hasGhostty: Bool {
        terminalService.installedLaunchers.contains { $0.name == "Ghostty" }
    }

    var body: some View {
        HStack(spacing: 6) {
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 4) {
                    if let wt = session.worktreeName {
                        Text(wt)
                            .font(.custom("Fira Code", size: 10 * scale))
                            .lineLimit(1)
                            .foregroundColor(.purple)
                            .padding(.horizontal, 4)
                            .padding(.vertical, 1)
                            .background(RoundedRectangle(cornerRadius: 3).fill(Color.purple.opacity(0.15)))
                            .hudTip("Git worktree: \(wt)")
                    }
                    Text(session.preview)
                        .font(.custom("Fira Sans", size: 12.5 * scale))
                        .foregroundColor(.secondary)
                        .lineLimit(1)
                }

                if let snippet = searchResult?.snippet, !snippet.isEmpty {
                    Text(snippet)
                        .font(.custom("Fira Sans", size: 11 * scale))
                        .foregroundColor(.accentColor.opacity(0.8))
                        .lineLimit(2)
                }

                HStack(spacing: 4) {
                    Text(String(session.id.prefix(8)))
                        .font(.custom("Fira Code", size: 10 * scale))
                        .foregroundColor(.secondary.opacity(0.5))
                    if let tag = projectTag {
                        projectChip(tag.name, isUnclaimed: tag.isUnclaimed)
                    }
                    Spacer()
                    Text(session.timestamp.relativeString)
                        .font(.custom("Fira Code", size: 10 * scale))
                        .foregroundColor(.secondary.opacity(0.5))
                }
            }

            Spacer()

            if let feedback {
                Text(feedback)
                    .font(.custom("Fira Sans", size: 10 * scale))
                    .foregroundColor(.green)
            } else {
                if hasGhostty {
                    Button(action: resume) {
                        Text(">_")
                            .font(.custom("Fira Code", size: 9 * scale).weight(.semibold))
                            .foregroundColor(.white)
                    }
                    .buttonStyle(.borderless)
                    .hudTip("Resume in a new Ghostty window")
                }
            }
        }
        .padding(.vertical, 5)
        .contextMenu {
            Button(role: .destructive, action: onDelete) {
                Label("Delete Session", systemImage: "trash")
            }
        }
    }

    /// Project attribution chip. An unclaimed cwd (no vault project owns it,
    /// the Session Inbox set) renders italic and dimmer: a quiet triage nudge.
    private func projectChip(_ name: String, isUnclaimed: Bool) -> some View {
        Text(name)
            .font(.custom("Fira Code", size: 10 * scale))
            .italic(isUnclaimed)
            .foregroundColor(.secondary.opacity(isUnclaimed ? 0.5 : 0.8))
            .lineLimit(1)
            .padding(.horizontal, 4)
            .padding(.vertical, 1)
            .background(RoundedRectangle(cornerRadius: 3).fill(Color.secondary.opacity(0.1)))
            .hudTip(isUnclaimed
                ? "Unclaimed: maps to no vault project (Session Inbox). Add a vault folder or a cwds: glob in its Tasks.md to claim it."
                : "Project: \(name)")
    }

    /// Resume in the session's original cwd through the shared launch path.
    private func resume() {
        let projectName = URL(fileURLWithPath: session.projectPath).lastPathComponent
        let auto = launchClaudeSession(argSuffix: " --resume \(session.id)", name: projectName,
                                       cwd: session.projectPath, terminalService: terminalService)
        feedback = auto ? "Opened!" : "Cmd+V"
        DispatchQueue.main.asyncAfter(deadline: .now() + 3) { feedback = nil }
    }
}

// MARK: - Terminal Popover

struct TerminalPopover: View {
    @EnvironmentObject var terminalService: TerminalService

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Launch Terminal")
                .font(.custom("Fira Sans", size: 13).weight(.semibold))
                .foregroundColor(.secondary)
                .padding(.bottom, 2)

            if terminalService.installedTerminals.isEmpty {
                Text("No terminal apps found.")
                    .font(.custom("Fira Sans", size: 13))
                    .foregroundColor(.secondary)
            } else {
                ForEach(terminalService.installedTerminals, id: \.path) { terminal in
                    Button(action: {
                        terminalService.select(terminal.path)
                        terminalService.launch()
                    }) {
                        HStack(spacing: 8) {
                            Image(systemName: terminalService.selectedPath == terminal.path
                                  ? "checkmark.circle.fill" : "circle")
                                .foregroundColor(terminalService.selectedPath == terminal.path
                                                 ? .accentColor : .secondary)
                                .frame(width: 16)
                            Text(terminal.name)
                                .font(.custom("Fira Sans", size: 13))
                                .foregroundColor(.primary)
                            Spacer()
                        }
                    }
                    .buttonStyle(.plain)
                }
            }
        }
        .padding(12)
        .frame(width: 200)
    }
}

// MARK: - Info Popover

struct InfoPopover: View {
    private let cliFound: Bool = {
        let paths = [
            "\(NSHomeDirectory())/.local/bin/claude",
            "/usr/local/bin/claude",
            "/opt/homebrew/bin/claude",
            "\(NSHomeDirectory())/.npm-global/bin/claude",
            "\(NSHomeDirectory())/.claude/local/claude",
        ]
        return paths.contains { FileManager.default.fileExists(atPath: $0) }
    }()

    private let python3Found: Bool = {
        FileManager.default.fileExists(atPath: "/usr/bin/python3")
            || FileManager.default.fileExists(atPath: "/opt/homebrew/bin/python3")
            || FileManager.default.fileExists(atPath: "/usr/local/bin/python3")
    }()

    private let firaFound: Bool = {
        NSFontManager.shared.availableFontFamilies.contains("Fira Sans")
    }()

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("ClaudeHUD")
                .font(.custom("Fira Sans", size: 15).weight(.semibold))

            Divider()

            // Status checks
            VStack(alignment: .leading, spacing: 8) {
                Text("Requirements")
                    .font(.custom("Fira Sans", size: 12).weight(.semibold))
                    .foregroundColor(.secondary)

                StatusRow(ok: cliFound, label: "Claude CLI",
                          detail: cliFound ? "Installed" : "Not found -- install from claude.ai")
                // DISABLED — Python 3 was only required for the permission
                // hooks, now superseded by the daemon agent handler.
                /*
                StatusRow(ok: python3Found, label: "Python 3",
                          detail: python3Found ? "Installed" : "Needed for permission hooks")
                */
                StatusRow(ok: firaFound, label: "Fira Sans / Code",
                          detail: firaFound ? "Installed" : "Optional -- using system fonts")
            }

            Divider()

            // Tabs
            TabToggleSection()

            Divider()

            // claude.ai cookie (usage)
            ClaudeAICookieSection()

            Divider()

            // Features
            VStack(alignment: .leading, spacing: 8) {
                Text("Features")
                    .font(.custom("Fira Sans", size: 12).weight(.semibold))
                    .foregroundColor(.secondary)

                InfoRow(icon: "star.fill", text: "**Star:** Pin projects to a Starred section at the top of history")
                InfoRow(icon: "terminal", text: "**Terminal:** Click to launch, long-press to switch. Ghostty, iTerm2, Terminal, and more")
                // DISABLED — notifications superseded by the daemon agent handler.
                // InfoRow(icon: "bell.fill", text: "**Notifications:** Desktop via macOS, mobile via [ntfy.sh](https://ntfy.sh)")
            }

            Divider()

            // Links
            HStack(spacing: 12) {
                Link(destination: URL(string: "https://github.com/bbdaniels/ClaudeHUD")!) {
                    Label("GitHub", systemImage: "link")
                        .font(.custom("Fira Sans", size: 11))
                }
                // DISABLED — ntfy.sh was the mobile push transport, now
                // superseded by the daemon agent handler.
                /*
                Link(destination: URL(string: "https://ntfy.sh")!) {
                    Label("ntfy.sh", systemImage: "antenna.radiowaves.left.and.right")
                        .font(.custom("Fira Sans", size: 11))
                }
                */
                Spacer()
            }
        }
        .padding(14)
        .frame(width: 320)
    }
}

private struct StatusRow: View {
    let ok: Bool
    let label: String
    let detail: String

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: ok ? "checkmark.circle.fill" : "xmark.circle")
                .font(.system(size: 12))
                .foregroundColor(ok ? .green : .orange)
                .frame(width: 14)
            Text(label)
                .font(.custom("Fira Sans", size: 12).weight(.medium))
                .frame(width: 90, alignment: .leading)
            Text(detail)
                .font(.custom("Fira Sans", size: 11))
                .foregroundColor(.secondary)
        }
    }
}

private struct InfoRow: View {
    let icon: String
    let text: LocalizedStringKey

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: icon)
                .font(.system(size: 11))
                .foregroundColor(.secondary)
                .frame(width: 14, alignment: .center)
                .padding(.top, 2)
            Text(text)
                .font(.custom("Fira Sans", size: 12))
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

// MARK: - Tab Toggle Settings

private struct TabToggleSection: View {
    @AppStorage("hiddenTabs") private var hiddenTabsRaw: String = ""
    @State private var hiddenTabs: Set<String> = FixedTab.hiddenTabs()

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Tabs")
                .font(.custom("Fira Sans", size: 12).weight(.semibold))
                .foregroundColor(.secondary)

            ForEach(FixedTab.allCases, id: \.rawValue) { tab in
                HStack(spacing: 8) {
                    Group {
                        if let asset = tab.assetIcon {
                            Image(asset)
                                .resizable()
                                .renderingMode(.template)
                                .scaledToFit()
                                .foregroundColor(hiddenTabs.contains(tab.rawValue) ? .secondary.opacity(0.3) : .secondary)
                        } else {
                            Image(systemName: tab.icon)
                                .font(.system(size: 11))
                                .foregroundColor(hiddenTabs.contains(tab.rawValue) ? .secondary.opacity(0.3) : .secondary)
                        }
                    }
                    .frame(width: 14, height: 14, alignment: .center)
                    Text("**\(tab.label):**")
                        .font(.custom("Fira Sans", size: 12))
                        .foregroundColor(hiddenTabs.contains(tab.rawValue) ? .secondary.opacity(0.4) : .primary)
                    Text(tab.detail)
                        .font(.custom("Fira Sans", size: 11))
                        .foregroundColor(.secondary.opacity(0.7))
                        .lineLimit(1)
                    Spacer()
                    if !tab.isRequired {
                        Toggle("", isOn: Binding(
                            get: { !hiddenTabs.contains(tab.rawValue) },
                            set: { enabled in
                                if enabled {
                                    hiddenTabs.remove(tab.rawValue)
                                } else {
                                    hiddenTabs.insert(tab.rawValue)
                                }
                                FixedTab.setHidden(tab, hidden: !enabled)
                                // Trigger @AppStorage refresh in TabBar
                                hiddenTabsRaw = hiddenTabs.sorted().joined(separator: ",")
                            }
                        ))
                        .toggleStyle(.switch)
                        .controlSize(.mini)
                    }
                }
            }
        }
    }
}

// MARK: - Cookie Settings

private struct ClaudeAICookieSection: View {
    @EnvironmentObject var usageService: UsageService
    @State private var cookieText: String = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Claude.ai Usage")
                .font(.custom("Fira Sans", size: 12).weight(.semibold))
                .foregroundColor(.secondary)

            if usageService.hasCookie {
                HStack(spacing: 8) {
                    Image(systemName: "checkmark.circle.fill")
                        .font(.system(size: 12))
                        .foregroundColor(.green)
                    Text("Cookie configured")
                        .font(.custom("Fira Sans", size: 12))
                    Spacer()
                    Button("Remove") {
                        UsageService.deleteCookie()
                        usageService.cookieDidChange()
                    }
                    .font(.custom("Fira Sans", size: 11))
                    .buttonStyle(.borderless)
                    .foregroundColor(.red)
                }
            } else {
                Text("Paste your claude.ai sessionKey cookie to track your 5-hour and weekly usage:")
                    .font(.custom("Fira Sans", size: 11))
                    .foregroundColor(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                HStack(spacing: 6) {
                    TextField("sessionKey value", text: $cookieText)
                        .textFieldStyle(.roundedBorder)
                        .font(.custom("Fira Code", size: 10))
                    Button("Save") {
                        guard !cookieText.isEmpty else { return }
                        UsageService.saveCookie(cookieText)
                        usageService.cookieDidChange()
                        cookieText = ""
                    }
                    .font(.custom("Fira Sans", size: 11))
                    .buttonStyle(.borderless)
                    .disabled(cookieText.isEmpty)
                }
            }
        }
    }
}
