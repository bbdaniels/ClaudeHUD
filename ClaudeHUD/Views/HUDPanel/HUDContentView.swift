import SwiftUI

struct HUDContentView: View {
    @EnvironmentObject var appState: AppState
    @EnvironmentObject var conversation: ConversationManager

    var body: some View {
        VStack(spacing: 0) {
            // Header
            HStack(spacing: 8) {
                Image(systemName: "sparkle")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundColor(.orange)

                Picker("", selection: $conversation.selectedModel) {
                    Text("Sonnet").tag("sonnet")
                    Text("Haiku").tag("haiku")
                    Text("Opus").tag("opus")
                }
                .labelsHidden()
                .fixedSize()

                Picker("", selection: $conversation.permissionMode) {
                    Image(systemName: "lock.open").tag("dangerously-skip")
                    Image(systemName: "lock").tag("default")
                    Image(systemName: "list.clipboard").tag("plan")
                }
                .pickerStyle(.segmented)
                .frame(width: 90)
                .help(permissionHelp)

                Spacer()

                Button(action: { conversation.newConversation() }) {
                    Image(systemName: "plus.circle")
                        .font(.system(size: 14))
                        .foregroundColor(.secondary)
                }
                .buttonStyle(.borderless)
                .help("New conversation")
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 8)

            Divider()
                .opacity(0.5)

            ChatView()
        }
        .frame(minWidth: 380, minHeight: 420)
    }

    private var permissionHelp: String {
        switch conversation.permissionMode {
        case "dangerously-skip": return "Skip all permissions"
        case "plan": return "Plan mode"
        default: return "Default permissions"
        }
    }
}
