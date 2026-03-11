import SwiftUI

struct SettingsView: View {
    @EnvironmentObject var conversation: ConversationManager

    var body: some View {
        Form {
            Section {
                Picker("Model", selection: $conversation.selectedModel) {
                    Text("Sonnet").tag("sonnet")
                    Text("Haiku").tag("haiku")
                    Text("Opus").tag("opus")
                }
            } header: {
                Text("Model")
            }

            Section {
                Picker("Permissions", selection: $conversation.permissionMode) {
                    Text("Bypass All").tag("bypassPermissions")
                    Text("Default").tag("default")
                    Text("Plan Mode").tag("plan")
                }
            } header: {
                Text("Permission Mode")
            } footer: {
                Text(permissionFooter)
                    .font(.caption)
            }
        }
        .frame(width: 380, height: 200)
        .padding()
    }

    private var permissionFooter: String {
        switch conversation.permissionMode {
        case "bypassPermissions":
            return "Skip all permission prompts (fastest)"
        case "plan":
            return "Claude proposes a plan before acting"
        default:
            return "Prompt before dangerous actions"
        }
    }
}
