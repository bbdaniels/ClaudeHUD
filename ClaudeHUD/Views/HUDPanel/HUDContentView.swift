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
    @State private var showPermissionPopover = false
    @State private var showPushPopover = false
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
            TabBar()

            Divider()
                .opacity(0.5)

            // Current conversation
            ChatView()
                .id(tabManager.selectedTabId)
                .environmentObject(tabManager.currentConversation)
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
    @EnvironmentObject var tabManager: TabManager
    @Environment(\.fontScale) private var scale

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 0) {
                ForEach(tabManager.tabs) { tab in
                    TabButton(tab: tab)
                }

                // Add tab button
                Button(action: { tabManager.addTab() }) {
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
    @EnvironmentObject var tabManager: TabManager
    @Environment(\.fontScale) private var scale

    private var isSelected: Bool {
        tabManager.selectedTabId == tab.id
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
