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
    static func smallMedium(_ s: CGFloat) -> Font { .custom(bodyFamily, size: 14 * s).weight(.medium) }
    static func captionFont(_ s: CGFloat) -> Font { .custom(bodyFamily, size: 12.5 * s) }
    static func codeFont(_ s: CGFloat) -> Font { .custom(codeFamily, size: 15.5 * s) }
    static func codeLarge(_ s: CGFloat) -> Font { .custom(codeFamily, size: 16.5 * s) }
}

enum FixedTab: String {
    case history
    case obsidian
    case today
    case projects
    case people
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
                .popover(isPresented: $showPermissionPopover) {
                    PermissionPopover(selection: $tabManager.permissionMode)
                }

                Spacer()

                Button(action: {
                    if terminalService.installedTerminals.count == 1 || !terminalService.selectedPath.isEmpty {
                        terminalService.launch()
                    } else {
                        showTerminalPopover = true
                    }
                }) {
                    Text(">_")
                        .font(.codeFont(fontScale))
                        .foregroundColor(.secondary)
                }
                .buttonStyle(.borderless)
                .help("Launch \(terminalService.selectedName)")
                .simultaneousGesture(LongPressGesture(minimumDuration: 0.4).onEnded { _ in
                    showTerminalPopover = true
                })
                .popover(isPresented: $showTerminalPopover) {
                    TerminalPopover()
                        .environmentObject(terminalService)
                }

                Button(action: { showPushPopover.toggle() }) {
                    Image(systemName: pushManager.isEnabled ? "bell.fill" : "bell.slash")
                        .font(.smallFont(fontScale))
                        .foregroundColor(pushManager.isEnabled ? .blue : .secondary)
                }
                .buttonStyle(.borderless)
                .help("Notifications")
                .popover(isPresented: $showPushPopover) {
                    PushPopover()
                        .environmentObject(pushManager)
                }

                Button(action: { showInfoPopover.toggle() }) {
                    Image(systemName: "info.circle")
                        .font(.smallFont(fontScale))
                        .foregroundColor(.secondary)
                }
                .buttonStyle(.borderless)
                .help("Setup & Info")
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

            // Permission approval banner
            if !permissionWatcher.pending.isEmpty {
                PermissionBannerView()
                    .environmentObject(permissionWatcher)
            }

            // Main content
            if let fixedTab = activeFixedTab {
                switch fixedTab {
                case .history:
                    SessionHistoryView()
                        .environmentObject(sessionHistory)
                        .environmentObject(terminalService)
                case .obsidian:
                    ObsidianBrowserView()
                        .environmentObject(vaultManager)
                case .today:
                    TodayView()
                        .environmentObject(calendarService)
                        .environmentObject(appState.briefingService)
                        .environmentObject(vaultManager)
                        .environmentObject(appState.projectService)
                case .projects:
                    ProjectDashboardView()
                        .environmentObject(appState.projectService)
                        .environmentObject(appState.projectBriefingService)
                        .environmentObject(sessionHistory)
                        .environmentObject(vaultManager)
                        .environmentObject(calendarService)
                case .people:
                    PeopleView()
                        .environmentObject(appState.contactService)
                }
            } else {
                ChatView()
                    .id(tabManager.selectedTabId)
                    .environmentObject(tabManager.currentConversation)
            }
        }
        .frame(minWidth: 380, minHeight: 420)
        .environment(\.fontScale, fontScale)
        .background(
            GeometryReader { geo in
                Color.clear.onAppear {
                    fontScale = max(0.85, min(1.4, geo.size.width / 420))
                }
                .onChange(of: geo.size.width) { _, w in
                    fontScale = max(0.85, min(1.4, w / 420))
                }
            }
        )
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

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 0) {
                // History tab (fixed)
                Button(action: { activeFixedTab = .history }) {
                    Image(systemName: "clock.arrow.circlepath")
                        .font(.captionFont(scale))
                        .foregroundColor(activeFixedTab == .history ? .primary : .secondary)
                        .frame(width: 28, height: 24)
                }
                .buttonStyle(.borderless)
                .background(
                    RoundedRectangle(cornerRadius: 5)
                        .fill(activeFixedTab == .history ? Color.accentColor.opacity(0.12) : Color.clear)
                )
                .help("Session history")

                // Obsidian tab (fixed)
                Button(action: { activeFixedTab = .obsidian }) {
                    Image(systemName: "archivebox")
                        .font(.captionFont(scale))
                        .foregroundColor(activeFixedTab == .obsidian ? .primary : .secondary)
                        .frame(width: 28, height: 24)
                }
                .buttonStyle(.borderless)
                .background(
                    RoundedRectangle(cornerRadius: 5)
                        .fill(activeFixedTab == .obsidian ? Color.accentColor.opacity(0.12) : Color.clear)
                )
                .help("Obsidian notes")

                // Today tab (fixed)
                Button(action: { activeFixedTab = .today }) {
                    Image(systemName: "calendar")
                        .font(.captionFont(scale))
                        .foregroundColor(activeFixedTab == .today ? .primary : .secondary)
                        .frame(width: 28, height: 24)
                }
                .buttonStyle(.borderless)
                .background(
                    RoundedRectangle(cornerRadius: 5)
                        .fill(activeFixedTab == .today ? Color.accentColor.opacity(0.12) : Color.clear)
                )
                .help("Today's schedule")

                // Projects tab (fixed)
                Button(action: { activeFixedTab = .projects }) {
                    Image(systemName: "briefcase")
                        .font(.captionFont(scale))
                        .foregroundColor(activeFixedTab == .projects ? .primary : .secondary)
                        .frame(width: 28, height: 24)
                }
                .buttonStyle(.borderless)
                .background(
                    RoundedRectangle(cornerRadius: 5)
                        .fill(activeFixedTab == .projects ? Color.accentColor.opacity(0.12) : Color.clear)
                )
                .help("Projects")

                // People tab (fixed)
                Button(action: { activeFixedTab = .people }) {
                    Image(systemName: "person.2")
                        .font(.captionFont(scale))
                        .foregroundColor(activeFixedTab == .people ? .primary : .secondary)
                        .frame(width: 28, height: 24)
                }
                .buttonStyle(.borderless)
                .background(
                    RoundedRectangle(cornerRadius: 5)
                        .fill(activeFixedTab == .people ? Color.accentColor.opacity(0.12) : Color.clear)
                )
                .help("People")

                Divider()
                    .frame(height: 16)
                    .padding(.horizontal, 4)

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
                .help("New tab")
            }
            .padding(.horizontal, 8)
        }
        .frame(height: 30)
        .background(Color(.windowBackgroundColor).opacity(0.5))
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
    @Environment(\.fontScale) private var scale
    @State private var searchText = ""
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
            filtered = sessionHistory.sessions.filter {
                $0.projectName.lowercased().contains(q) || $0.preview.lowercased().contains(q) ||
                $0.projectPath.lowercased().contains(q)
            }
        }

        let home = NSHomeDirectory()
        let grouped = Dictionary(grouping: filtered) { $0.projectPath }
        return grouped.map { entry in
            // Home dir project: group under "~" instead of "/Users"
            let parentPath = entry.key == home
                ? home
                : URL(fileURLWithPath: entry.key).deletingLastPathComponent().path
            return (name: entry.value.first!.projectName, path: entry.key, parentPath: parentPath, sessions: entry.value)
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
                    TextField("Search sessions...", text: $searchText)
                        .font(.smallFont(scale))
                        .textFieldStyle(.plain)
                    if !searchText.isEmpty {
                        Button(action: { searchText = "" }) {
                            Image(systemName: "xmark.circle.fill")
                                .font(.system(size: 11 * scale))
                                .foregroundColor(.secondary)
                        }
                        .buttonStyle(.borderless)
                    }
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
                                    onToggleStar: { toggleStar($0) },
                                    onDeleteSession: { deleteSession($0, projectPath: $1) }
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
    let onToggleStar: (String) -> Void
    let onDeleteSession: (String, String) -> Void
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
                    .font(.custom("Fira Code", size: 9 * scale))
                    .foregroundColor(.secondary.opacity(0.4))
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
    let onToggleStar: () -> Void
    let onDeleteSession: (String) -> Void
    @EnvironmentObject var terminalService: TerminalService
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
         isStarred: Bool, onToggleStar: @escaping () -> Void,
         onDeleteSession: @escaping (String) -> Void) {
        self.projectName = projectName
        self.projectPath = projectPath
        self.sessions = sessions
        self.isStarred = isStarred
        self.onToggleStar = onToggleStar
        self.onDeleteSession = onDeleteSession
        self._unsafeMode = State(initialValue: UserDefaults.standard.bool(forKey: "history.unsafe.\(projectPath)"))
        self._effort = State(initialValue: UserDefaults.standard.string(forKey: "history.effort.\(projectPath)") ?? "default")
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Compact project line
            HStack(spacing: 6) {
                if sessions.count > 1 {
                    Image(systemName: expanded ? "chevron.down" : "chevron.right")
                        .font(.system(size: 10 * scale, weight: .semibold))
                        .foregroundColor(.secondary)
                        .frame(width: 14)
                        .contentShape(Rectangle())
                        .onTapGesture { withAnimation(.easeInOut(duration: 0.15)) { expanded.toggle() } }
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
                .help(isStarred ? "Unstar project" : "Star project")

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
                .help(unsafeMode ? "Unsafe mode (click to toggle)" : "Safe mode (click to toggle)")

                // Effort toggle (per-project, persistent)
                Button(action: { cycleEffort() }) {
                    Image(systemName: effortIcon)
                        .font(.system(size: 11 * scale))
                        .foregroundColor(effortColor)
                        .frame(width: 16)
                }
                .buttonStyle(.borderless)
                .help("Effort: \(effort) (click to cycle)")

                Text(projectName)
                    .font(.custom("Fira Sans", size: 14 * scale).weight(.semibold))
                    .foregroundColor(.primary)
                    .lineLimit(1)

                Text(latest.timestamp.relativeString)
                    .font(.custom("Fira Sans", size: 11.5 * scale))
                    .foregroundColor(.secondary)

                if sessions.count > 1 {
                    Text("\(sessions.count)")
                        .font(.custom("Fira Code", size: 10 * scale))
                        .foregroundColor(.secondary.opacity(0.6))
                        .padding(.horizontal, 4)
                        .padding(.vertical, 1)
                        .background(RoundedRectangle(cornerRadius: 3).fill(Color.secondary.opacity(0.1)))
                }

                Spacer()

                if let feedback {
                    Text(feedback)
                        .font(.custom("Fira Sans", size: 11 * scale))
                        .foregroundColor(.green)
                } else {
                    ForEach(terminalService.installedLaunchers, id: \.path) { launcher in
                        Button(action: { newSession(usingApp: launcher.path) }) {
                            Text(launcher.name == "VS Code" ? "VS" : ">_")
                                .font(.custom("Fira Code", size: 10 * scale).weight(.semibold))
                                .foregroundColor(.white)
                        }
                        .buttonStyle(.borderless)
                        .help("New session in \(launcher.name)")
                    }
                }
            }
            .padding(.vertical, 8)
            .contentShape(Rectangle())
            .onTapGesture {
                if sessions.count > 1 {
                    withAnimation(.easeInOut(duration: 0.15)) { expanded.toggle() }
                }
            }

            if expanded {
                VStack(spacing: 0) {
                    ForEach(visibleSessions) { session in
                        SessionDetailRow(
                            session: session,
                            launchFlags: launchFlags,
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
        let command = "claude\(launchFlags)"
        let auto = terminalService.launchWithCommand(command, inDirectory: projectPath, usingApp: appPath)
        feedback = auto ? "Opened!" : "Cmd+V"
        DispatchQueue.main.asyncAfter(deadline: .now() + 3) { feedback = nil }
    }
}

// MARK: - Session Detail Row (inside expanded project)

struct SessionDetailRow: View {
    let session: SessionInfo
    let launchFlags: String
    let onDelete: () -> Void
    @EnvironmentObject var terminalService: TerminalService
    @State private var feedback: String?
    @Environment(\.fontScale) private var scale

    var body: some View {
        HStack(spacing: 6) {
            VStack(alignment: .leading, spacing: 2) {
                Text(session.preview)
                    .font(.custom("Fira Sans", size: 12.5 * scale))
                    .foregroundColor(.secondary)
                    .lineLimit(1)

                Text("\(session.id.prefix(8)) · \(session.timestamp.relativeString)")
                    .font(.custom("Fira Code", size: 10 * scale))
                    .foregroundColor(.secondary.opacity(0.5))
            }

            Spacer()

            if let feedback {
                Text(feedback)
                    .font(.custom("Fira Sans", size: 10 * scale))
                    .foregroundColor(.green)
            } else {
                ForEach(terminalService.installedLaunchers, id: \.path) { launcher in
                    Button(action: { resume(usingApp: launcher.path) }) {
                        Text(launcher.name == "VS Code" ? "VS" : ">_")
                            .font(.custom("Fira Code", size: 9 * scale).weight(.semibold))
                            .foregroundColor(.white)
                    }
                    .buttonStyle(.borderless)
                    .help("Resume in \(launcher.name)")
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
        let command = "claude --resume \(session.id)\(launchFlags)"
        let auto = terminalService.launchWithCommand(command, inDirectory: session.projectPath, usingApp: appPath)
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
                StatusRow(ok: python3Found, label: "Python 3",
                          detail: python3Found ? "Installed" : "Needed for permission hooks")
                StatusRow(ok: firaFound, label: "Fira Sans / Code",
                          detail: firaFound ? "Installed" : "Optional -- using system fonts")
            }

            Divider()

            // Quick guide
            VStack(alignment: .leading, spacing: 8) {
                Text("Quick Guide")
                    .font(.custom("Fira Sans", size: 12).weight(.semibold))
                    .foregroundColor(.secondary)

                InfoRow(icon: "calendar", text: "**Today:** AI-powered daily briefing with date navigation. Claude summarizes your schedule and preps each meeting")
                InfoRow(icon: "folder", text: "**Projects:** Cross-references Obsidian, sessions, calendar, and email for project-level intelligence")
                InfoRow(icon: "clock.arrow.circlepath", text: "**History:** Browse and resume past Claude sessions across all projects")
                InfoRow(icon: "lock.fill", text: "**Safe/Unsafe:** Per-project toggle in history. Controls whether sessions launch with --dangerously-skip-permissions")
                InfoRow(icon: "gauge.with.dots.needle.50percent", text: "**Effort:** Per-project effort level in history. Click the gauge icon to cycle through default/low/medium/high/max")
                InfoRow(icon: "star.fill", text: "**Star:** Pin frequently used projects to a Starred section at the top of history")
                InfoRow(icon: "archivebox", text: "**Obsidian:** Browse vault notes. Click to preview, pencil icon to edit. Select vault from dropdown")
                InfoRow(icon: "shield", text: "**Permissions:** Plan/Safe/Unsafe controls how much Claude can do without asking")
                InfoRow(icon: "terminal", text: "**Terminal:** Click to launch, long-press to switch. Supports Ghostty, iTerm2, Terminal, and more")
                InfoRow(icon: "bell.fill", text: "**Notifications:** Desktop alerts via macOS. Mobile via [ntfy.sh](https://ntfy.sh): install the app, pick a topic name, paste it in the bell menu")
            }

            Divider()

            // Links
            HStack(spacing: 12) {
                Link(destination: URL(string: "https://github.com/bbdaniels/ClaudeHUD")!) {
                    Label("GitHub", systemImage: "link")
                        .font(.custom("Fira Sans", size: 11))
                }
                Link(destination: URL(string: "https://ntfy.sh")!) {
                    Label("ntfy.sh", systemImage: "antenna.radiowaves.left.and.right")
                        .font(.custom("Fira Sans", size: 11))
                }
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
