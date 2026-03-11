import SwiftUI

struct HUDContentView: View {
    @EnvironmentObject var appState: AppState
    @EnvironmentObject var tabManager: TabManager
    @State private var showPermissionPopover = false

    var body: some View {
        VStack(spacing: 0) {
            // Header
            HStack(spacing: 8) {
                Image(systemName: "sparkle")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundColor(.orange)

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
                            .font(.system(size: 11))
                        Text(permissionLabel)
                            .font(.system(size: 11))
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

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 0) {
                ForEach(tabManager.tabs) { tab in
                    TabButton(tab: tab)
                }

                // Add tab button
                Button(action: { tabManager.addTab() }) {
                    Image(systemName: "plus")
                        .font(.system(size: 10))
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

    private var isSelected: Bool {
        tabManager.selectedTabId == tab.id
    }

    var body: some View {
        HStack(spacing: 4) {
            Text(tab.title)
                .font(.system(size: 11))
                .lineLimit(1)
                .foregroundColor(isSelected ? .primary : .secondary)

            if tabManager.tabs.count > 1 {
                Button(action: { tabManager.closeTab(tab.id) }) {
                    Image(systemName: "xmark")
                        .font(.system(size: 8, weight: .bold))
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

    var body: some View {
        Button(action: { selection = tag }) {
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: selection == tag ? "checkmark.circle.fill" : "circle")
                    .font(.system(size: 14))
                    .foregroundColor(selection == tag ? color : .secondary)
                    .frame(width: 18)

                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                        .font(.system(size: 13, weight: .medium))
                        .foregroundColor(.primary)
                    Text(description)
                        .font(.system(size: 11))
                        .foregroundColor(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
        .buttonStyle(.plain)
    }
}
