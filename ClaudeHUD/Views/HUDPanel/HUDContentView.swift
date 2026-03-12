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

struct HUDContentView: View {
    @EnvironmentObject var appState: AppState
    @EnvironmentObject var tabManager: TabManager
    @EnvironmentObject var pushManager: PushNotificationManager
    @EnvironmentObject var terminalService: TerminalService
    @EnvironmentObject var sessionHistory: SessionHistoryService
    @State private var showPermissionPopover = false
    @State private var showPushPopover = false
    @State private var showTerminalPopover = false
    @State private var showingHistory = false
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
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 8)

            // Tab bar
            TabBar(showingHistory: $showingHistory)

            Divider()
                .opacity(0.5)

            // Main content: history or conversation
            if showingHistory {
                SessionHistoryView()
                    .environmentObject(sessionHistory)
                    .environmentObject(terminalService)
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
    @Binding var showingHistory: Bool
    @EnvironmentObject var tabManager: TabManager
    @Environment(\.fontScale) private var scale

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 0) {
                // History tab (fixed, far left)
                Button(action: { showingHistory = true }) {
                    Image(systemName: "clock.arrow.circlepath")
                        .font(.captionFont(scale))
                        .foregroundColor(showingHistory ? .primary : .secondary)
                        .frame(width: 28, height: 24)
                }
                .buttonStyle(.borderless)
                .background(
                    RoundedRectangle(cornerRadius: 5)
                        .fill(showingHistory ? Color.accentColor.opacity(0.12) : Color.clear)
                )
                .help("Session history")

                Divider()
                    .frame(height: 16)
                    .padding(.horizontal, 4)

                ForEach(tabManager.tabs) { tab in
                    TabButton(tab: tab, showingHistory: $showingHistory)
                }

                // Add tab button
                Button(action: {
                    tabManager.addTab()
                    showingHistory = false
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
    @Binding var showingHistory: Bool
    @EnvironmentObject var tabManager: TabManager
    @Environment(\.fontScale) private var scale

    private var isSelected: Bool {
        !showingHistory && tabManager.selectedTabId == tab.id
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
            showingHistory = false
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
                color: .red,
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

    /// Sessions grouped by project, sorted by most recent session in each group.
    private var projectGroups: [(name: String, path: String, sessions: [SessionInfo])] {
        let grouped = Dictionary(grouping: sessionHistory.sessions) { $0.projectName }
        return grouped.map { (name: $0.key, path: $0.value.first!.projectPath, sessions: $0.value) }
            .sorted { $0.sessions.first!.timestamp > $1.sessions.first!.timestamp }
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
                ScrollView {
                    LazyVStack(spacing: 0) {
                        ForEach(projectGroups, id: \.name) { group in
                            ProjectRow(
                                projectName: group.name,
                                projectPath: group.path,
                                sessions: group.sessions
                            )
                            Divider().opacity(0.3)
                        }
                    }
                    .padding(.horizontal, 10)
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .onAppear {
            Task { await sessionHistory.refresh() }
        }
    }
}

// MARK: - Project Row (collapsible)

struct ProjectRow: View {
    let projectName: String
    let projectPath: String
    let sessions: [SessionInfo]
    @EnvironmentObject var terminalService: TerminalService
    @State private var expanded = false
    @State private var feedback: String?
    @Environment(\.fontScale) private var scale

    private var latest: SessionInfo { sessions.first! }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Compact project line
            HStack(spacing: 6) {
                if sessions.count > 1 {
                    Image(systemName: expanded ? "chevron.down" : "chevron.right")
                        .font(.system(size: 9 * scale, weight: .semibold))
                        .foregroundColor(.secondary)
                        .frame(width: 12)
                        .contentShape(Rectangle())
                        .onTapGesture { withAnimation(.easeInOut(duration: 0.15)) { expanded.toggle() } }
                } else {
                    Spacer().frame(width: 12)
                }

                Text(projectName)
                    .font(.custom("Fira Sans", size: 12.5 * scale).weight(.semibold))
                    .foregroundColor(.primary)
                    .lineLimit(1)

                Text(latest.timestamp.relativeString)
                    .font(.custom("Fira Sans", size: 10 * scale))
                    .foregroundColor(.secondary)

                if sessions.count > 1 {
                    Text("\(sessions.count)")
                        .font(.custom("Fira Code", size: 9 * scale))
                        .foregroundColor(.secondary.opacity(0.6))
                        .padding(.horizontal, 4)
                        .padding(.vertical, 1)
                        .background(RoundedRectangle(cornerRadius: 3).fill(Color.secondary.opacity(0.1)))
                }

                Spacer()

                if let feedback {
                    Text(feedback)
                        .font(.custom("Fira Sans", size: 10 * scale))
                        .foregroundColor(.green)
                } else {
                    Button(action: { resumeSession(latest) }) {
                        Image(systemName: "play.fill")
                            .font(.system(size: 10 * scale))
                            .foregroundColor(.accentColor)
                    }
                    .buttonStyle(.borderless)
                    .help("Resume latest session")
                }
            }
            .padding(.vertical, 7)
            .contentShape(Rectangle())
            .onTapGesture {
                if sessions.count > 1 {
                    withAnimation(.easeInOut(duration: 0.15)) { expanded.toggle() }
                }
            }

            if expanded {
                VStack(spacing: 0) {
                    ForEach(sessions) { session in
                        SessionDetailRow(session: session)
                    }
                }
                .padding(.leading, 18)
            }
        }
    }

    private func resumeSession(_ session: SessionInfo) {
        let command = "claude --resume \(session.id)"
        let auto = terminalService.launchWithCommand(command, inDirectory: session.projectPath)
        feedback = auto ? "Opened!" : "Cmd+V"
        DispatchQueue.main.asyncAfter(deadline: .now() + 3) { feedback = nil }
    }
}

// MARK: - Session Detail Row (inside expanded project)

struct SessionDetailRow: View {
    let session: SessionInfo
    @EnvironmentObject var terminalService: TerminalService
    @State private var feedback: String?
    @Environment(\.fontScale) private var scale

    var body: some View {
        HStack(spacing: 6) {
            VStack(alignment: .leading, spacing: 1) {
                Text(session.preview)
                    .font(.custom("Fira Sans", size: 11 * scale))
                    .foregroundColor(.secondary)
                    .lineLimit(1)

                Text("\(session.id.prefix(8)) · \(session.timestamp.relativeString)")
                    .font(.custom("Fira Code", size: 9 * scale))
                    .foregroundColor(.secondary.opacity(0.5))
            }

            Spacer()

            if let feedback {
                Text(feedback)
                    .font(.custom("Fira Sans", size: 9 * scale))
                    .foregroundColor(.green)
            } else {
                Button(action: resume) {
                    Image(systemName: "play.fill")
                        .font(.system(size: 9 * scale))
                        .foregroundColor(.accentColor)
                }
                .buttonStyle(.borderless)
                .help("Resume this session")
            }
        }
        .padding(.vertical, 4)
    }

    private func resume() {
        let command = "claude --resume \(session.id)"
        let auto = terminalService.launchWithCommand(command, inDirectory: session.projectPath)
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
