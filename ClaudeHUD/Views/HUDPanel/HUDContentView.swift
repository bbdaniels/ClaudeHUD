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
    // ProjectBriefingService, AgentsService standalone tab, obsidian
    // Notes tab — Daily Notes are now in Today). Raw values stay so
    // hiddenTabs UserDefaults entries from older builds keep meaning.
    case history
    case library
    case vault
    case today

    var icon: String {
        switch self {
        case .history: return "clock.arrow.circlepath"
        case .vault: return "briefcase"
        case .today: return "calendar"
        case .library: return "books.vertical.fill"   // overridden by Library asset; see TabBar.
        }
    }

    /// Image asset name to use INSTEAD of the SF Symbol for this tab, when set.
    /// Lets the Library tab use the Claude logo instead of an SF Symbol.
    var assetIcon: String? {
        switch self {
        case .library: return "ClaudeLogo"
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
    @EnvironmentObject var pushManager: PushNotificationManager
    @EnvironmentObject var terminalService: TerminalService
    @EnvironmentObject var sessionHistory: SessionHistoryService
    @EnvironmentObject var permissionWatcher: PermissionWatcherService
    @EnvironmentObject var vaultManager: VaultManager
    @EnvironmentObject var calendarService: CalendarService
    @State private var showPermissionPopover = false
    @State private var showPushPopover = false
    @State private var showTerminalPopover = false
    @State private var showInfoPopover = false
    @State private var activeFixedTab: FixedTab? = .history
    @State private var fontScale: CGFloat = 1.0

    var body: some View {
        VStack(spacing: 0) {
            // Header
            HStack(spacing: 8) {
                Image("ClaudeLogo")
                    .resizable()
                    .frame(width: 18, height: 18)

                Picker("", selection: $tabManager.selectedModel) {
                    Text("Sonnet").tag("sonnet")
                    Text("Haiku").tag("haiku")
                    Text("Opus").tag("opus")
                }
                .labelsHidden()
                .fixedSize()

                Button(action: { showPermissionPopover.toggle() }) {
                    HStack(spacing: 4) {
                        Image(systemName: permissionIcon)
                            .font(.smallFont(fontScale))
                        Text(permissionLabel)
                            .font(.smallFont(fontScale))
                    }
                    .padding(.horizontal, 6)
                    .padding(.vertical, 3)
                    .background(
                        RoundedRectangle(cornerRadius: 5)
                            .fill(permissionColor.opacity(0.15))
                    )
                    .foregroundColor(permissionColor)
                }
                .buttonStyle(.borderless)
                .hudTip("Permission mode for new sessions (click to change)")
                .popover(isPresented: $showPermissionPopover) {
                    PermissionPopover(selection: $tabManager.permissionMode)
                }

                UsageBadge()

                Spacer()

                Button(action: {
                    terminalService.launchClaudeAtHome()
                }) {
                    Text(">_")
                        .font(.codeFont(fontScale))
                        .foregroundColor(.secondary)
                }
                .buttonStyle(.borderless)
                .hudTip("New Claude session at ~ (high effort, bypass permissions)")
                .simultaneousGesture(LongPressGesture(minimumDuration: 0.4).onEnded { _ in
                    showTerminalPopover = true
                })
                .popover(isPresented: $showTerminalPopover) {
                    TerminalPopover()
                        .environmentObject(terminalService)
                }

                // DISABLED — notifications (push + permission watcher) are
                // superseded by the daemon agent's handler. UI hidden; the
                // PushPopover/PushNotificationManager/PermissionWatcher code is
                // intentionally kept. Re-enable by uncommenting this block and
                // restoring the AppState/ClaudeHUDApp wiring.
                /*
                Button(action: { showPushPopover.toggle() }) {
                    Image(systemName: pushManager.isEnabled ? "bell.fill" : "bell.slash")
                        .font(.smallFont(fontScale))
                        .foregroundColor(pushManager.isEnabled ? .blue : .secondary)
                }
                .buttonStyle(.borderless)
                .hudTip("Notifications")
                .popover(isPresented: $showPushPopover) {
                    PushPopover()
                        .environmentObject(pushManager)
                        .environmentObject(permissionWatcher)
                }
                */

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
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 8)

            // Tab bar
            TabBar(activeFixedTab: $activeFixedTab)

            Divider()
                .opacity(0.5)

            // DISABLED — permission approval is handled by the daemon agent's
            // handler now. Banner hidden; PermissionBannerView/Watcher kept.
            /*
            if permissionWatcher.isEnabled && !permissionWatcher.pending.isEmpty {
                PermissionBannerView()
                    .environmentObject(permissionWatcher)
            }
            */

            // Main content
            if let fixedTab = activeFixedTab {
                switch fixedTab {
                case .history:
                    SessionHistoryView()
                        .environmentObject(sessionHistory)
                        .environmentObject(terminalService)
                        .environmentObject(appState.projectService)
                        .environmentObject(appState.vaultIngestService)
                        // For the unclaimed-cwd marker: same canonical resolver
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
                        // ProjectBriefingService / LLM call at view time.)
                        .environmentObject(appState.agentsService)
                        // For the per-row "Open in Slack" action.
                        .environmentObject(appState.slackService)
                case .today:
                    TodayView()
                        .environmentObject(calendarService)
                        .environmentObject(appState.briefingService)
                        .environmentObject(vaultManager)
                        .environmentObject(appState.projectService)
                        .environmentObject(appState.remindersService)
                case .library:
                    LibraryView()
                        .environmentObject(appState.libraryService)
                        .environmentObject(terminalService)
                }
            } else if tabManager.currentTab?.kind == .terminal {
                TerminalTabView(sessionId: tabManager.selectedTabId)
                    .id(tabManager.selectedTabId)
                    .environmentObject(appState)
            } else {
                ChatView()
                    .id(tabManager.selectedTabId)
                    .environmentObject(tabManager.currentConversation)
            }
        }
        .frame(minWidth: 380, minHeight: 420)
        .environment(\.fontScale, fontScale)
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
            Group {
                Button("") { tabManager.addTab() }
                    .keyboardShortcut("t", modifiers: .command)
                    .frame(width: 0, height: 0)
                    .hidden()
                Button("") {
                    tabManager.closeTab(tabManager.selectedTabId)
                }
                .keyboardShortcut("w", modifiers: .command)
                .frame(width: 0, height: 0)
                .hidden()
            }
        )
        .hudTooltipLayer()
    }

    private var permissionIcon: String {
        switch tabManager.permissionMode {
        case "dangerously-skip": return "lock.open"
        case "default": return "lock"
        default: return "shield"
        }
    }

    private var permissionLabel: String {
        switch tabManager.permissionMode {
        case "dangerously-skip": return "Unsafe"
        case "default": return "Safe"
        default: return "Plan"
        }
    }

    private var permissionColor: Color {
        switch tabManager.permissionMode {
        case "dangerously-skip": return .red
        case "default": return .orange
        default: return .green
        }
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

            Divider()
                .frame(height: 16)
                .padding(.horizontal, 4)

            // Conversation tabs can overflow, so they keep the horizontal scroll.
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 0) {
                    ForEach(tabManager.tabs) { tab in
                        TabButton(tab: tab, activeFixedTab: $activeFixedTab)
                    }

                    // Add tab button
                    Button(action: {
                        tabManager.addTab()
                        activeFixedTab = nil
                    }) {
                        Image(systemName: "plus")
                            .font(.captionFont(scale))
                            .foregroundColor(.secondary)
                            .frame(width: 24, height: 24)
                    }
                    .buttonStyle(.borderless)
                    .hudTip("New tab")
                }
            }
        }
        .padding(.horizontal, 8)
        .frame(height: 30)
        .background(Color(.windowBackgroundColor).opacity(0.5))
    }

    @ViewBuilder
    private func fixedTab(_ tab: FixedTab) -> some View {
        Group {
            if let asset = tab.assetIcon {
                // Template-rendered so we can tint to a flat white silhouette
                // instead of the brand-colored glyph in the asset catalog.
                Image(asset)
                    .resizable()
                    .renderingMode(.template)
                    .scaledToFit()
                    .foregroundColor(.white.opacity(activeFixedTab == tab ? 1.0 : 0.55))
                    .frame(width: 13 * scale, height: 13 * scale)
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
            if tab.kind == .terminal {
                Image(systemName: "terminal")
                    .font(.smallFont(scale))
                    .foregroundColor(isSelected ? .accentColor : .secondary)
            }

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

            if tabManager.tabs.count > 1 {
                Button(action: { tabManager.closeTab(tab.id) }) {
                    Image(systemName: "xmark")
                        .font(.custom("Fira Sans", size: 8 * scale).weight(.bold))
                        .foregroundColor(.secondary.opacity(0.6))
                }
                .buttonStyle(.borderless)
                .hudTip("Close tab")
            }
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

// MARK: - Permission Popover

struct PermissionPopover: View {
    @Binding var selection: String
    @Environment(\.fontScale) private var scale

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            PermissionOption(
                title: "Plan",
                description: "Claude proposes a plan and asks before taking any action.",
                icon: "shield",
                color: .green,
                tag: "plan",
                selection: $selection
            )
            PermissionOption(
                title: "Safe",
                description: "Claude reads freely but asks permission for Bash commands.",
                icon: "lock",
                color: .orange,
                tag: "default",
                selection: $selection
            )
            PermissionOption(
                title: "Unsafe",
                description: "No permission checks. Claude runs any Bash command without asking.",
                icon: "lock.open",
                color: .white,
                tag: "dangerously-skip",
                selection: $selection
            )
        }
        .padding(12)
        .frame(width: 280)
    }
}

struct PermissionOption: View {
    let title: String
    let description: String
    let icon: String
    let color: Color
    let tag: String
    @Binding var selection: String
    @Environment(\.fontScale) private var scale

    var body: some View {
        Button(action: { selection = tag }) {
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: selection == tag ? "checkmark.circle.fill" : "circle")
                    .font(.bodyFont(scale))
                    .foregroundColor(selection == tag ? color : .secondary)
                    .frame(width: 18)

                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                        .font(.bodyMedium(scale))
                        .foregroundColor(.primary)
                    Text(description)
                        .font(.smallFont(scale))
                        .foregroundColor(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
        .buttonStyle(.plain)
    }
}

// MARK: - Push Notification Popover

struct PushPopover: View {
    @EnvironmentObject var pushManager: PushNotificationManager
    @EnvironmentObject var permissionWatcher: PermissionWatcherService
    @State private var topicDraft: String = ""
    @State private var testSent = false

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            // Enable toggle
            HStack {
                Image(systemName: "bell.fill")
                    .foregroundColor(.blue)
                Text("Notifications")
                    .font(.custom("Fira Sans", size: 15).weight(.semibold))
                Spacer()
                Toggle("", isOn: Binding(
                    get: { pushManager.isEnabled },
                    set: { val in Task { await pushManager.setEnabled(val) } }
                ))
                .labelsHidden()
                .toggleStyle(.switch)
            }

            Divider()

            // Desktop
            HStack(spacing: 10) {
                Image(systemName: "desktopcomputer")
                    .frame(width: 18)
                    .foregroundColor(.secondary)
                VStack(alignment: .leading, spacing: 1) {
                    Text("Desktop")
                        .font(.custom("Fira Sans", size: 13).weight(.medium))
                    Text("macOS notification banner")
                        .font(.custom("Fira Sans", size: 11))
                        .foregroundColor(.secondary)
                }
                Spacer()
                Toggle("", isOn: Binding(
                    get: { pushManager.desktopEnabled },
                    set: { val in Task { await pushManager.setDesktopEnabled(val) } }
                ))
                .labelsHidden()
                .toggleStyle(.switch)
                .disabled(!pushManager.isEnabled)
            }

            // Mobile (ntfy)
            HStack(spacing: 10) {
                Image(systemName: "iphone")
                    .frame(width: 18)
                    .foregroundColor(.secondary)
                VStack(alignment: .leading, spacing: 1) {
                    Text("Mobile (ntfy.sh)")
                        .font(.custom("Fira Sans", size: 13).weight(.medium))
                    Text("Push to iPhone / Apple Watch")
                        .font(.custom("Fira Sans", size: 11))
                        .foregroundColor(.secondary)
                }
                Spacer()
                Toggle("", isOn: Binding(
                    get: { pushManager.mobileEnabled },
                    set: { val in Task { await pushManager.setMobileEnabled(val) } }
                ))
                .labelsHidden()
                .toggleStyle(.switch)
                .disabled(!pushManager.isEnabled)
            }

            // Topic field (only when mobile enabled)
            if pushManager.mobileEnabled && pushManager.isEnabled {
                HStack(spacing: 6) {
                    TextField("ntfy topic (e.g. claude-abc123)", text: $topicDraft)
                        .font(.custom("Fira Code", size: 12))
                        .textFieldStyle(.roundedBorder)
                        .onAppear { topicDraft = pushManager.ntfyTopic }
                        .onSubmit { Task { await pushManager.setNtfyTopic(topicDraft) } }
                    Button("Set") {
                        Task { await pushManager.setNtfyTopic(topicDraft) }
                    }
                    .font(.custom("Fira Sans", size: 12))
                    .buttonStyle(.bordered)
                }
            }

            Divider()

            // Permission approvals (separate from notifications — installs
            // a PermissionRequest hook and shows an inline approve/deny banner)
            HStack(spacing: 10) {
                Image(systemName: "shield")
                    .frame(width: 18)
                    .foregroundColor(.secondary)
                VStack(alignment: .leading, spacing: 1) {
                    Text("Permission approvals")
                        .font(.custom("Fira Sans", size: 13).weight(.medium))
                    Text("Inline approve/deny banner in HUD")
                        .font(.custom("Fira Sans", size: 11))
                        .foregroundColor(.secondary)
                }
                Spacer()
                Toggle("", isOn: Binding(
                    get: { permissionWatcher.isEnabled },
                    set: { permissionWatcher.setEnabled($0) }
                ))
                .labelsHidden()
                .toggleStyle(.switch)
            }

            Divider()

            // Test button
            HStack {
                Button(action: {
                    pushManager.sendTestNotification()
                    testSent = true
                    DispatchQueue.main.asyncAfter(deadline: .now() + 2) { testSent = false }
                }) {
                    Label(testSent ? "Sent!" : "Test notification", systemImage: testSent ? "checkmark" : "paperplane")
                        .font(.custom("Fira Sans", size: 12))
                }
                .buttonStyle(.bordered)
                .disabled(!pushManager.isEnabled || !pushManager.desktopEnabled)

                Spacer()

                if pushManager.scriptInstalled {
                    Label("Hook installed", systemImage: "checkmark.circle.fill")
                        .font(.custom("Fira Sans", size: 11))
                        .foregroundColor(.green)
                } else {
                    Label("Not installed", systemImage: "xmark.circle")
                        .font(.custom("Fira Sans", size: 11))
                        .foregroundColor(.secondary)
                }
            }
        }
        .padding(14)
        .frame(width: 290)
    }
}

// MARK: - Session History View

struct SessionHistoryView: View {
    @EnvironmentObject var sessionHistory: SessionHistoryService
    @EnvironmentObject var terminalService: TerminalService
    @EnvironmentObject var vaultProjects: VaultProjectService
    @Environment(\.fontScale) private var scale
    @State private var searchText = ""
    @State private var resolvePrimed = false
    @State private var searchDebounceTask: Task<Void, Never>?
    @State private var useColors = UserDefaults.standard.bool(forKey: "history.useColors")
    @State private var starredPaths: Set<String> = {
        Set(UserDefaults.standard.stringArray(forKey: "history.starredProjects") ?? [])
    }()

    private typealias ProjectGroup = (name: String, path: String, parentPath: String, sessions: [SessionInfo])

    /// Sessions grouped by project path, filtered by search, sorted by most recent.
    private var projectGroups: [ProjectGroup] {
        let filtered: [SessionInfo]
        if searchText.isEmpty {
            filtered = sessionHistory.sessions
        } else {
            let q = searchText.lowercased()
            let hasSearchResults = !sessionHistory.searchResults.isEmpty
            filtered = sessionHistory.sessions.filter {
                $0.projectName.lowercased().contains(q) || $0.preview.lowercased().contains(q) ||
                $0.projectPath.lowercased().contains(q) ||
                (hasSearchResults && sessionHistory.searchResults[$0.id] != nil)
            }
        }

        let home = NSHomeDirectory()
        // Collapse a worktree path back to its parent repo cwd.
        func repoCwd(_ p: String) -> String {
            if let range = p.range(of: "/.claude/worktrees/") {
                return String(p[..<range.lowerBound])
            }
            return p
        }
        // Group by the Obsidian project that OWNS the cwd (a writeable `cwds:`
        // match) so a project spanning several repos/paths is ONE row named for the
        // vault project. Unclaimed cwds fall back to grouping by the repo cwd
        // (leaf-named), exactly as before. Same canonical resolver as the unclaimed
        // marker; a "vault::" key can't collide with an absolute cwd path.
        let grouped = Dictionary(grouping: filtered) { session -> String in
            let cwd = repoCwd(session.projectPath)
            if resolvePrimed, let vid = vaultProjects.folderName(forCwd: cwd) {
                return "vault::\(vid)"
            }
            return cwd
        }
        return grouped.map { entry in
            // The most-recent session supplies the launch/open cwd and the folder
            // bucket for a merged vault project (its sessions may span repos).
            let recent = entry.value.max { $0.timestamp < $1.timestamp }!
            let repCwd = repoCwd(recent.projectPath)
            let isVault = entry.key.hasPrefix("vault::")
            let name = isVault ? String(entry.key.dropFirst("vault::".count))
                               : URL(fileURLWithPath: repCwd).lastPathComponent
            // Home dir project: group under "~" instead of "/Users"
            let parentPath = repCwd == home
                ? home
                : URL(fileURLWithPath: repCwd).deletingLastPathComponent().path
            return (name: name, path: repCwd, parentPath: parentPath, sessions: entry.value)
        }
        .filter { $0.path != "/" && $0.parentPath != "/" }
        .sorted { $0.sessions.first!.timestamp > $1.sessions.first!.timestamp }
    }

    /// Partition groups into time-based sections.
    private var sections: [(title: String, groups: [ProjectGroup])] {
        let cal = Calendar.current
        let now = Date()
        let startOfToday = cal.startOfDay(for: now)
        let startOfWeek = cal.date(byAdding: .day, value: -7, to: startOfToday)!

        let starred = projectGroups.filter { starredPaths.contains($0.path) }
        let unstarred = projectGroups.filter { !starredPaths.contains($0.path) }

        let today = unstarred.filter { $0.sessions.first!.timestamp >= startOfToday }
        let thisWeek = unstarred.filter {
            $0.sessions.first!.timestamp >= startOfWeek && $0.sessions.first!.timestamp < startOfToday
        }
        let older = unstarred.filter { $0.sessions.first!.timestamp < startOfWeek }

        var result: [(title: String, groups: [ProjectGroup])] = []
        if !starred.isEmpty { result.append(("Starred", starred)) }
        if !today.isEmpty { result.append(("Today", today)) }
        if !thisWeek.isEmpty { result.append(("This Week", thisWeek)) }
        if !older.isEmpty { result.append(("Older", older)) }
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
                    TextField("Search chats...", text: $searchText)
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

                if projectGroups.isEmpty {
                    Spacer()
                    Text("No matches")
                        .font(.smallFont(scale))
                        .foregroundColor(.secondary)
                    Spacer()
                } else {
                    ScrollView {
                        VStack(spacing: 0) {
                            ForEach(sections, id: \.title) { section in
                                TimeSectionView(
                                    title: section.title,
                                    groups: section.groups,
                                    starredPaths: starredPaths,
                                    searchResults: sessionHistory.searchResults,
                                    onToggleStar: { toggleStar($0) },
                                    onDeleteSession: { deleteSession($0, projectPath: $1) },
                                    // Unclaimed = repo cwd resolves to no vault
                                    // project (the Session Inbox set). Only after
                                    // the resolver cache is primed.
                                    isUnclaimed: { resolvePrimed && vaultProjects.folderName(forCwd: $0) == nil }
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
        // Prime the canonical cwd→folder cache for every project group (the
        // worktree-merged paths the rows key on), so the unclaimed marker can
        // resolve. Re-runs when the session set changes; cheap on repeat
        // (only new cwds are scanned). Read-only.
        .task(id: sessionHistory.sessions.count) {
            var paths = Set<String>()
            for s in sessionHistory.sessions {
                if let r = s.projectPath.range(of: "/.claude/worktrees/") {
                    paths.insert(String(s.projectPath[..<r.lowerBound]))
                } else {
                    paths.insert(s.projectPath)
                }
            }
            await vaultProjects.primeResolution(forCwds: paths)
            resolvePrimed = true
        }
    }

    private func toggleStar(_ path: String) {
        if starredPaths.contains(path) {
            starredPaths.remove(path)
        } else {
            starredPaths.insert(path)
        }
        UserDefaults.standard.set(Array(starredPaths), forKey: "history.starredProjects")
    }

    private func deleteSession(_ sessionId: String, projectPath: String) {
        sessionHistory.deleteSession(id: sessionId)
    }
}

// MARK: - Path Display Helpers

private func tildeCollapsedPath(_ path: String) -> String {
    let home = NSHomeDirectory()
    if path == home { return "~" }
    if path.hasPrefix(home + "/") {
        return "~/" + String(path.dropFirst(home.count + 1))
    }
    return path
}

private func abbreviatedFolderName(_ path: String) -> String {
    let collapsed = tildeCollapsedPath(path)
    if collapsed == "~" { return "~" }
    return URL(fileURLWithPath: path).lastPathComponent
}

// MARK: - Collapsible Time Section

struct TimeSectionView: View {
    let title: String
    let groups: [(name: String, path: String, parentPath: String, sessions: [SessionInfo])]
    let starredPaths: Set<String>
    let searchResults: [String: SessionSearchResult]
    let onToggleStar: (String) -> Void
    let onDeleteSession: (String, String) -> Void
    /// True when a group's repo cwd resolves to no vault project.
    let isUnclaimed: (String) -> Bool
    @State private var collapsed = false
    @State private var hoveredFolder: String?
    @Environment(\.fontScale) private var scale

    /// Projects sub-grouped by parent folder, sorted by most recent activity.
    private var folderGroups: [(path: String, displayName: String, fullPath: String,
                                projects: [(name: String, path: String, parentPath: String, sessions: [SessionInfo])])] {
        let byFolder = Dictionary(grouping: groups) { $0.parentPath }
        return byFolder.map { entry in
            (path: entry.key,
             displayName: abbreviatedFolderName(entry.key),
             fullPath: tildeCollapsedPath(entry.key),
             projects: entry.value.sorted { $0.sessions.first!.timestamp > $1.sessions.first!.timestamp })
        }
        .sorted { $0.projects.first!.sessions.first!.timestamp > $1.projects.first!.sessions.first!.timestamp }
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
                Text("\(groups.count)")
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
            ForEach(folderGroups, id: \.path) { folder in
                VStack(spacing: 0) {
                    // Folder header
                    HStack(spacing: 4) {
                        Image(systemName: "folder")
                            .font(.system(size: 9 * scale))
                            .foregroundColor(.secondary.opacity(0.6))
                        Text(folder.displayName)
                            .font(.custom("Fira Code", size: 10 * scale))
                            .foregroundColor(.secondary.opacity(0.7))
                        if hoveredFolder == folder.path {
                            Text(folder.fullPath)
                                .font(.custom("Fira Code", size: 9 * scale))
                                .foregroundColor(.secondary.opacity(0.4))
                                .lineLimit(1)
                                .truncationMode(.head)
                        }
                        Spacer()
                    }
                    .padding(.horizontal, 4)
                    .padding(.top, 4)
                    .padding(.bottom, 1)
                    .contentShape(Rectangle())
                    .onHover { hoveredFolder = $0 ? folder.path : nil }
                    .onTapGesture { NSWorkspace.shared.selectFile(nil, inFileViewerRootedAtPath: folder.path) }

                    ForEach(folder.projects, id: \.path) { group in
                        ProjectRow(
                            projectName: group.name,
                            projectPath: group.path,
                            sessions: group.sessions,
                            isStarred: starredPaths.contains(group.path),
                            isUnclaimed: isUnclaimed(group.path),
                            searchResults: searchResults,
                            onToggleStar: { onToggleStar(group.path) },
                            onDeleteSession: { sessionId in
                                onDeleteSession(sessionId, group.path)
                            }
                        )
                        Divider().opacity(0.3)
                    }
                }
            }
        }
    }
}

// MARK: - Project Row (collapsible)

struct ProjectRow: View {
    let projectName: String
    let projectPath: String
    let sessions: [SessionInfo]
    let isStarred: Bool
    /// Repo cwd resolves to no vault project → show the Session-Inbox marker.
    let isUnclaimed: Bool
    let searchResults: [String: SessionSearchResult]
    let onToggleStar: () -> Void
    let onDeleteSession: (String) -> Void
    @EnvironmentObject var terminalService: TerminalService
    @EnvironmentObject var tabManager: TabManager
    @EnvironmentObject var projectService: ProjectService
    @State private var expanded = false
    @State private var showAll = false
    @State private var feedback: String?
    @State private var unsafeMode: Bool
    @State private var effort: String
    @Environment(\.fontScale) private var scale

    private let sessionCap = 5
    private static let effortLevels = ["default", "low", "medium", "high", "max"]

    private var latest: SessionInfo { sessions.first! }

    private var launchFlags: String {
        var flags = ""
        if unsafeMode { flags += " --dangerously-skip-permissions" }
        if effort != "default" { flags += " --effort \(effort)" }
        return flags
    }

    private var defaultsKey: String { "history.unsafe.\(projectPath)" }
    private var effortKey: String { "history.effort.\(projectPath)" }

    /// Whether this project has any full-text search matches.
    private var hasSearchMatches: Bool {
        !searchResults.isEmpty && sessions.contains { searchResults[$0.id] != nil }
    }

    /// Whether sessions list should be shown (explicit expand or search match).
    private var isExpanded: Bool { expanded || hasSearchMatches }

    private var visibleSessions: [SessionInfo] {
        if showAll || sessions.count <= sessionCap {
            return sessions
        }
        return Array(sessions.prefix(sessionCap))
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

    init(projectName: String, projectPath: String, sessions: [SessionInfo],
         isStarred: Bool, isUnclaimed: Bool = false,
         searchResults: [String: SessionSearchResult] = [:],
         onToggleStar: @escaping () -> Void,
         onDeleteSession: @escaping (String) -> Void) {
        self.projectName = projectName
        self.projectPath = projectPath
        self.sessions = sessions
        self.isStarred = isStarred
        self.isUnclaimed = isUnclaimed
        self.searchResults = searchResults
        self.onToggleStar = onToggleStar
        self.onDeleteSession = onDeleteSession
        self._unsafeMode = State(initialValue: UserDefaults.standard.bool(forKey: "history.unsafe.\(projectPath)"))
        self._effort = State(initialValue: UserDefaults.standard.string(forKey: "history.effort.\(projectPath)") ?? "default")
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Compact project line
            HStack(spacing: 6) {
                if sessions.count > 1 || hasSearchMatches {
                    Image(systemName: isExpanded ? "chevron.down" : "chevron.right")
                        .font(.system(size: 10 * scale, weight: .semibold))
                        .foregroundColor(.secondary)
                        .frame(width: 14)
                        .contentShape(Rectangle())
                        .onTapGesture { withAnimation(.easeInOut(duration: 0.15)) { expanded.toggle() } }
                        .hudTip(isExpanded ? "Collapse sessions" : "Expand sessions")
                } else {
                    Spacer().frame(width: 14)
                }

                // Star toggle
                Button(action: onToggleStar) {
                    Image(systemName: isStarred ? "star.fill" : "star")
                        .font(.system(size: 11 * scale))
                        .foregroundColor(isStarred ? .yellow : .secondary.opacity(0.4))
                        .frame(width: 14)
                }
                .buttonStyle(.borderless)
                .hudTip(isStarred ? "Unstar project" : "Star project")

                // Unsafe toggle (per-project, persistent)
                Button(action: {
                    unsafeMode.toggle()
                    UserDefaults.standard.set(unsafeMode, forKey: defaultsKey)
                }) {
                    Image(systemName: unsafeMode ? "lock.open.fill" : "lock.fill")
                        .font(.system(size: 11 * scale))
                        .foregroundColor(unsafeMode ? .red : .green)
                        .frame(width: 16)
                }
                .buttonStyle(.borderless)
                .hudTip(unsafeMode ? "Unsafe mode (click to toggle)" : "Safe mode (click to toggle)")

                // Effort toggle (per-project, persistent)
                Button(action: { cycleEffort() }) {
                    Image(systemName: effortIcon)
                        .font(.system(size: 11 * scale))
                        .foregroundColor(effortColor)
                        .frame(width: 16)
                }
                .buttonStyle(.borderless)
                .hudTip("Effort: \(effort) (click to cycle)")

                Text(projectName)
                    .font(.smallMedium(scale))
                    .foregroundColor(.primary)
                    .lineLimit(1)

                // Unclaimed-cwd marker (Phase 2): this repo maps to no vault
                // project — the Session Inbox set. A quiet triage nudge, not a
                // loud badge; the Projects spine never shows these.
                if isUnclaimed {
                    Image(systemName: "tray")
                        .font(.system(size: 9 * scale))
                        .foregroundColor(.secondary.opacity(0.45))
                        .hudTip("Unclaimed — maps to no vault project (Session Inbox). Add a vault folder or a cwds: glob in its Tasks.md to claim it.")
                }

                if sessions.count > 1 {
                    Text("\(sessions.count)")
                        .font(.custom("Fira Code", size: 10 * scale))
                        .foregroundColor(.secondary.opacity(0.6))
                        .padding(.horizontal, 4)
                        .padding(.vertical, 1)
                        .background(RoundedRectangle(cornerRadius: 3).fill(Color.secondary.opacity(0.1)))
                }

                Spacer()

                Text(latest.timestamp.relativeString)
                    .font(.custom("Fira Code", size: 10 * scale))
                    .foregroundColor(.secondary.opacity(0.5))

                GitHubRepoIndicator(
                    info: projectService.gitHubInfo(forPath: projectPath),
                    scale: scale
                )

                if let feedback {
                    Text(feedback)
                        .font(.custom("Fira Sans", size: 11 * scale))
                        .foregroundColor(.green)
                } else {
                    Button(action: {
                        NSWorkspace.shared.selectFile(nil, inFileViewerRootedAtPath: projectPath)
                    }) {
                        Image(systemName: "folder")
                            .font(.system(size: 11 * scale, weight: .semibold))
                            .foregroundColor(.white)
                    }
                    .buttonStyle(.borderless)
                    .hudTip("Reveal in Finder")

                    if !sessions.isEmpty {
                        Button(action: { magicLaunchInGhostty() }) {
                            Image(systemName: "pencil.and.outline")
                                .font(.system(size: 11 * scale, weight: .semibold))
                                .foregroundColor(.white)
                        }
                        .buttonStyle(.borderless)
                        .hudTip("New session — loads project context from the Obsidian wiki")
                    } else {
                        // Unavailable (no prior sessions): greyed + struck
                        // through, the same idiom as GitHubRepoIndicator's
                        // "no remote" state, instead of hiding the control.
                        ZStack {
                            Image(systemName: "pencil.and.outline")
                                .font(.system(size: 11 * scale, weight: .semibold))
                                .foregroundColor(.secondary.opacity(0.35))
                            Rectangle()
                                .frame(width: 14 * scale, height: 1.5 * scale)
                                .rotationEffect(.degrees(-45))
                                .foregroundColor(.secondary.opacity(0.7))
                        }
                        .hudTip("No prior sessions yet")
                    }

                    ForEach(terminalService.installedLaunchers, id: \.path) { launcher in
                        Button(action: { newSession(usingApp: launcher.path) }) {
                            Text(launcher.name == "VS Code" ? "VS" : ">_")
                                .font(.custom("Fira Code", size: 10 * scale).weight(.semibold))
                                .foregroundColor(.white)
                        }
                        .buttonStyle(.borderless)
                        .hudTip("New session in \(launcher.name)")
                    }
                }
            }
            .padding(.vertical, 8)
            .contentShape(Rectangle())
            .onTapGesture {
                if sessions.count > 1 || hasSearchMatches {
                    withAnimation(.easeInOut(duration: 0.15)) { expanded.toggle() }
                }
            }
            .task(id: projectPath) {
                projectService.refreshGitHubInfo(forPath: projectPath)
            }

            if isExpanded {
                VStack(spacing: 0) {
                    ForEach(visibleSessions) { session in
                        SessionDetailRow(
                            session: session,
                            launchFlags: launchFlags,
                            searchResult: searchResults[session.id],
                            onDelete: { onDeleteSession(session.id) }
                        )
                    }

                    // "Show more" / "Show less" toggle
                    if sessions.count > sessionCap {
                        Button(action: { withAnimation(.easeInOut(duration: 0.15)) { showAll.toggle() } }) {
                            Text(showAll ? "Show less" : "Show all \(sessions.count) sessions")
                                .font(.custom("Fira Sans", size: 11 * scale))
                                .foregroundColor(.accentColor)
                        }
                        .buttonStyle(.borderless)
                        .padding(.vertical, 4)
                    }
                }
                .padding(.leading, 20)
            }
        }
    }

    private func cycleEffort() {
        guard let idx = Self.effortLevels.firstIndex(of: effort) else { effort = "default"; return }
        effort = Self.effortLevels[(idx + 1) % Self.effortLevels.count]
        UserDefaults.standard.set(effort, forKey: effortKey)
    }

    private func newSession(usingApp appPath: String) {
        let command = daemonizedClaudeCommand(launchFlags)
        let useColors = UserDefaults.standard.bool(forKey: "history.useColors")
        let bg = useColors ? TerminalService.projectColor(for: projectName) : nil
        let auto = terminalService.launchWithCommand(command, inDirectory: projectPath, usingApp: appPath, backgroundColor: bg)
        feedback = auto ? "Opened!" : "Cmd+V"
        DispatchQueue.main.asyncAfter(deadline: .now() + 3) { feedback = nil }
    }

    private func magicLaunchInGhostty() {
        // Canonical registry lookup keyed by this project's absolute repo
        // working directory. On a hit the shared launcher names the resolved
        // vault folder directly (dropping the legacy "confirm with the user"
        // ambiguity); on a miss it preserves the fuzzy index.md behavior.
        let resolvedVaultPath = projectService.vaultFolderPath(forRepoPath: projectPath)
        let auto = performMagicLaunch(
            projectName: projectName, cwd: projectPath,
            resolvedVaultPath: resolvedVaultPath, launchFlags: launchFlags,
            terminalService: terminalService
        )
        feedback = auto ? "Opened!" : "Cmd+V"
        DispatchQueue.main.asyncAfter(deadline: .now() + 3) { feedback = nil }
    }

}

// MARK: - GitHub Repo Indicator

/// Reserved-slot indicator. Always renders so rows stay aligned: a white mark
/// when the project has a GitHub remote, a greyed-out mark with a diagonal
/// slash when it doesn't. `nil` info covers both "no remote" and "not yet
/// fetched"; the slot is stable across both states. (Moved here from the
/// deleted ProjectDashboardView husk — its only consumer is the ProjectRow.)
struct GitHubRepoIndicator: View {
    let info: GitHubRepoInfo?
    let scale: CGFloat

    private var tooltip: String {
        guard let info else { return "No GitHub remote" }
        let host = info.url
            .replacingOccurrences(of: "https://", with: "")
            .replacingOccurrences(of: "http://", with: "")
        return "\(info.isPrivate ? "Private" : "Public") · \(host)"
    }

    var body: some View {
        Group {
            if let info {
                Button {
                    if let url = URL(string: info.url) {
                        NSWorkspace.shared.open(url)
                    }
                } label: {
                    ZStack(alignment: .bottomTrailing) {
                        markImage.foregroundColor(.white)
                        if info.isPrivate {
                            Image(systemName: "lock.fill")
                                .font(.system(size: 6 * scale, weight: .bold))
                                .foregroundColor(.green)
                                // Push the lock just past the bottom-right of
                                // the mark so it reads as an overlay glyph.
                                .offset(x: 2, y: 2)
                        }
                    }
                }
                .buttonStyle(.borderless)
            } else {
                ZStack {
                    markImage.foregroundColor(.secondary.opacity(0.35))
                    Rectangle()
                        .frame(width: 14 * scale, height: 1.5 * scale)
                        .rotationEffect(.degrees(-45))
                        .foregroundColor(.secondary.opacity(0.7))
                }
                .frame(width: 12 * scale, height: 12 * scale)
            }
        }
        .hudTip(tooltip)
    }

    private var markImage: some View {
        Image("GitHubMark")
            .renderingMode(.template)
            .resizable()
            .aspectRatio(contentMode: .fit)
            .frame(width: 12 * scale, height: 12 * scale)
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
/// `argSuffix` is everything after `claude` (e.g. ` --effort high`,
/// ` --resume <id> --dangerously-skip-permissions`, or flags + a prompt).
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
    let bg = "claude --bg" + rcFlag + argSuffix
    let plain = "claude" + rcFlag + argSuffix
    return "__o=$(\(bg) 2>&1); "
        + "__i=$(printf '%s' \"$__o\" | perl -pe 's/\\e\\[[0-9;]*m//g' "
        + "| grep -oE 'backgrounded[^0-9a-f]*[0-9a-f]{8}' "
        + "| grep -oE '[0-9a-f]{8}' | tail -1); "
        + "if [ -n \"$__i\" ]; then "
        + "echo \"[registered with daemon: $__i -- run 'claude agents' to supervise]\"; "
        + "claude attach \"$__i\"; "
        + "else printf '%s\\n' \"$__o\"; \(plain); fi"
}

// MARK: - Magic launch (shared by Session History + Projects spine)

/// Build the wiki-bootstrap magic-launch prompt: the launched session loads
/// context from the Obsidian vault (the source of truth), not a lossy chat
/// recap. `resolvedVaultPath` non-nil → step 2 names the resolved folder
/// directly (no index.md re-derivation, no user confirmation); nil → legacy
/// index.md resolution. Kept on one line so it survives every delivery path
/// (Ghostty temp script, Terminal/iTerm AppleScript `do script`, clipboard).
/// {{PROJECT}} is the project name.
func magicLaunchPrompt(projectName: String, resolvedVaultPath: String?) -> String {
    let template = [
        "Fresh session on the Obsidian vault project: {{PROJECT}}. Load context from the wiki at ~/Documents/Obsidian (the source of truth) — not from a chat recap or a prior-session summary. Tool priority: (1) mcp__obsidian__ tools for structured metadata; (2) Obsidian CLI (/Applications/Obsidian.app/Contents/MacOS/obsidian <cmd>; see `obsidian help`) — fast for `search`, `tasks`, `append`, `create`, `read`, `backlinks`; (3) direct file Read/Write/Edit at the vault path.",
        "1. Read schema.md (the vault contract).",
        "{{STEP2}}",
        "3. Read that project's Dashboard.md, Tasks.md (its \"## Active\" section), and Technical Notes.md.",
        "4. Report in ~3 lines: project status, the top 1–3 active tasks, and any \"Attention needed\" flags. Then stop and wait for the user to choose what to work on — do NOT start a task automatically.",
        "Rules: Tasks.md is the source of truth — as work completes or appears, update its ## Active / ## Completed and the `updated:` frontmatter, append a daily-note entry, and externalize decisions into the project notes (never leave state only in chat). Never `git reset --hard` or `git clean` the vault; local edits become durable only when pushed (the 15-min sync, or ~/.claude/scripts/vault-reset.sh).",
    ].joined(separator: " ")

    let step2: String
    if let vaultPath = resolvedVaultPath {
        step2 = "2. This project's vault folder is already resolved: \"\(vaultPath)\". Use it directly — do NOT re-derive it from index.md and do NOT ask the user to confirm the path."
    } else {
        step2 = "2. Read index.md (or HOME.md) to resolve \"{{PROJECT}}\" to its folder. If there is no exact folder match, pick the closest catalog entry and confirm the path with the user in one line before proceeding."
    }

    return template
        .replacingOccurrences(of: "{{STEP2}}", with: step2)
        .replacingOccurrences(of: "{{PROJECT}}", with: projectName)
}

/// Fire a magic launch for `projectName` rooted at repo `cwd`, loading vault
/// context. `resolvedVaultPath` non-nil → folder already resolved (the Projects
/// spine knows it directly; Session History resolves it via the canonical
/// `vaultFolderPath`). Returns whether the terminal auto-opened (false →
/// clipboard fallback). Enables Remote Control named after the project so each
/// session is identifiable in the agents list.
@MainActor
func performMagicLaunch(projectName: String, cwd: String, resolvedVaultPath: String?,
                        launchFlags: String, terminalService: TerminalService) -> Bool {
    let prompt = magicLaunchPrompt(projectName: projectName, resolvedVaultPath: resolvedVaultPath)
    // Single-quote the prompt for the shell (every ' becomes '\'' and the whole
    // string is wrapped in '...'). Neutralises the backticks (`git reset
    // --hard`, `updated:`) and `$` so they cannot run as command substitution —
    // which double-quoting would NOT prevent.
    let escapedPrompt = prompt.replacingOccurrences(of: "'", with: "'\\''")
    let command = daemonizedClaudeCommand(
        "\(launchFlags) '\(escapedPrompt)'",
        remoteControlName: projectName
    )
    let ghosttyPath = "/Applications/Ghostty.app"
    let app = FileManager.default.fileExists(atPath: ghosttyPath) ? ghosttyPath : nil
    let useColors = UserDefaults.standard.bool(forKey: "history.useColors")
    let bg = useColors ? TerminalService.projectColor(for: projectName) : nil
    return terminalService.launchWithCommand(command, inDirectory: cwd, usingApp: app, backgroundColor: bg)
}

// MARK: - Session Detail Row (inside expanded project)

struct SessionDetailRow: View {
    let session: SessionInfo
    let launchFlags: String
    let searchResult: SessionSearchResult?
    let onDelete: () -> Void
    @EnvironmentObject var terminalService: TerminalService
    @EnvironmentObject var tabManager: TabManager
    @EnvironmentObject var ingestService: VaultIngestService
    @State private var feedback: String?
    @Environment(\.fontScale) private var scale

    /// Provenance badge state for this session. Reads
    /// `VaultIngestService` (Phase 4): a session is `ingested` if its
    /// `Sessions.md` row landed, `failed` if a `.failed` marker exists
    /// in `~/.claude/ingest-state/`, `pending` if a transcript is in
    /// the worker's queue but hasn't been processed yet, otherwise no
    /// badge.
    private enum BadgeKind { case ingested, failed, pending, none }

    private var badgeKind: BadgeKind {
        let s = ingestService.status(forSessionID: session.id)
        switch s.kind {
        case .ingested: return .ingested
        case .failed: return .failed
        case .unknown:
            if ingestService.queue.pending.contains(where: { $0.sessionID == session.id }) {
                return .pending
            }
            return .none
        }
    }

    var body: some View {
        HStack(spacing: 6) {
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 4) {
                    if let wt = session.worktreeName {
                        HStack(spacing: 2) {
                            Image(systemName: "arrow.triangle.branch")
                                .font(.system(size: 8 * scale, weight: .semibold))
                            Text(wt)
                                .font(.custom("Fira Code", size: 10 * scale))
                                .lineLimit(1)
                        }
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

                if let snippet = searchResult?.snippet {
                    Text(snippet)
                        .font(.custom("Fira Sans", size: 11 * scale))
                        .foregroundColor(.accentColor.opacity(0.8))
                        .lineLimit(2)
                }

                HStack(spacing: 4) {
                    Text(String(session.id.prefix(8)))
                        .font(.custom("Fira Code", size: 10 * scale))
                        .foregroundColor(.secondary.opacity(0.5))
                    ingestBadge
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
                Button(action: resumeInHUD) {
                    Image(systemName: "plus.rectangle.on.rectangle")
                        .font(.system(size: 10 * scale, weight: .semibold))
                        .foregroundColor(.white)
                }
                .buttonStyle(.borderless)
                .hudTip("Resume as HUD terminal tab")

                ForEach(terminalService.installedLaunchers, id: \.path) { launcher in
                    Button(action: { resume(usingApp: launcher.path) }) {
                        Text(launcher.name == "VS Code" ? "VS" : ">_")
                            .font(.custom("Fira Code", size: 9 * scale).weight(.semibold))
                            .foregroundColor(.white)
                    }
                    .buttonStyle(.borderless)
                    .hudTip("Resume in \(launcher.name)")
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

    private func resume(usingApp appPath: String) {
        let command = daemonizedClaudeCommand(" --resume \(session.id)\(launchFlags)")
        let useColors = UserDefaults.standard.bool(forKey: "history.useColors")
        let projectName = URL(fileURLWithPath: session.projectPath).lastPathComponent
        let bg = useColors ? TerminalService.projectColor(for: projectName) : nil
        let auto = terminalService.launchWithCommand(command, inDirectory: session.projectPath, usingApp: appPath, backgroundColor: bg)
        feedback = auto ? "Opened!" : "Cmd+V"
        DispatchQueue.main.asyncAfter(deadline: .now() + 3) { feedback = nil }
    }

    private func resumeInHUD() {
        let command = daemonizedClaudeCommand(" --resume \(session.id)\(launchFlags)")
        let projectName = URL(fileURLWithPath: session.projectPath).lastPathComponent
        let useColors = UserDefaults.standard.bool(forKey: "history.useColors")
        let bg = useColors ? TerminalService.projectColor(for: projectName) : nil
        tabManager.addTerminalTab(
            title: String(session.id.prefix(8)),
            command: command,
            workingDirectory: session.projectPath,
            backgroundColor: bg,
            subtitle: session.worktreeName
        )
        feedback = "Opened"
        DispatchQueue.main.asyncAfter(deadline: .now() + 1) { feedback = nil }
    }

    /// Small ingest-state badge next to the short session ID. Tooltip
    /// explains the state. Click reveals the relevant file in Finder
    /// (Sessions.md for ingested, the `.failed` marker for failed, the
    /// transcript for pending).
    @ViewBuilder
    private var ingestBadge: some View {
        switch badgeKind {
        case .ingested:
            badgePill(symbol: "checkmark", color: .green,
                      tip: "Ingested into vault — click to open Sessions.md",
                      action: revealIngestedRow)
        case .failed:
            badgePill(symbol: "xmark", color: .red,
                      tip: "Ingest failed — click to reveal the .failed marker",
                      action: revealFailedMarker)
        case .pending:
            badgePill(symbol: "hourglass", color: .orange,
                      tip: "Queued — worker will pick it up on next SessionEnd",
                      action: revealPendingTranscript)
        case .none:
            EmptyView()
        }
    }

    private func badgePill(symbol: String, color: Color, tip: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 8 * scale, weight: .bold))
                .foregroundColor(color)
                .padding(.horizontal, 4)
                .padding(.vertical, 1)
                .background(RoundedRectangle(cornerRadius: 3).fill(color.opacity(0.18)))
        }
        .buttonStyle(.plain)
        .hudTip(tip)
    }

    private func revealIngestedRow() {
        let s = ingestService.status(forSessionID: session.id)
        guard let project = s.project,
              let vault = ingestService.vaultPath else { return }
        let url = vault.appending(path: "\(project)/Sessions.md")
        NSWorkspace.shared.activateFileViewerSelecting([url])
    }

    private func revealFailedMarker() {
        let stateDir = FileManager.default.homeDirectoryForCurrentUser.appending(path: ".claude/ingest-state")
        guard let entries = try? FileManager.default.contentsOfDirectory(at: stateDir, includingPropertiesForKeys: nil),
              let marker = entries.first(where: { $0.lastPathComponent.hasPrefix("\(session.id).") && $0.pathExtension == "failed" })
        else {
            NSWorkspace.shared.activateFileViewerSelecting([stateDir])
            return
        }
        NSWorkspace.shared.activateFileViewerSelecting([marker])
    }

    private func revealPendingTranscript() {
        if let p = ingestService.queue.pending.first(where: { $0.sessionID == session.id }) {
            NSWorkspace.shared.activateFileViewerSelecting([p.path])
        }
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

                InfoRow(icon: "lock.fill", text: "**Safe/Unsafe:** Per-project toggle in history. Controls --dangerously-skip-permissions")
                InfoRow(icon: "gauge.with.dots.needle.50percent", text: "**Effort:** Click gauge icon in history to cycle default/low/medium/high/max")
                InfoRow(icon: "star.fill", text: "**Star:** Pin projects to a Starred section at the top of history")
                InfoRow(icon: "shield", text: "**Permissions:** Plan/Safe/Unsafe controls how much Claude can do without asking")
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

// MARK: - Permission Approval Banner

struct PermissionBannerView: View {
    @EnvironmentObject var permissionWatcher: PermissionWatcherService
    @Environment(\.fontScale) private var scale

    var body: some View {
        VStack(spacing: 0) {
            ForEach(permissionWatcher.pending) { request in
                HStack(spacing: 8) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .font(.system(size: 12 * scale))
                        .foregroundColor(.yellow)

                    VStack(alignment: .leading, spacing: 1) {
                        HStack(spacing: 4) {
                            Text(request.toolName)
                                .font(.custom("Fira Code", size: 11 * scale).weight(.semibold))
                                .foregroundColor(.white)
                            Text("· \(request.project)")
                                .font(.custom("Fira Sans", size: 11 * scale))
                                .foregroundColor(.secondary)
                        }
                        Text(request.summary)
                            .font(.custom("Fira Code", size: 10 * scale))
                            .foregroundColor(.secondary)
                            .lineLimit(2)
                    }

                    Spacer()

                    Button(action: { permissionWatcher.deny(request.id) }) {
                        Text("Deny")
                            .font(.custom("Fira Sans", size: 11 * scale).weight(.medium))
                            .foregroundColor(.white.opacity(0.8))
                            .padding(.horizontal, 8)
                            .padding(.vertical, 3)
                            .background(RoundedRectangle(cornerRadius: 4).fill(Color.secondary.opacity(0.3)))
                    }
                    .buttonStyle(.borderless)

                    Button(action: { permissionWatcher.approve(request.id) }) {
                        Text("Allow")
                            .font(.custom("Fira Sans", size: 11 * scale).weight(.semibold))
                            .foregroundColor(.white)
                            .padding(.horizontal, 8)
                            .padding(.vertical, 3)
                            .background(RoundedRectangle(cornerRadius: 4).fill(Color.green.opacity(0.7)))
                    }
                    .buttonStyle(.borderless)
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
            }
        }
        .background(Color.orange.opacity(0.12))
    }
}
