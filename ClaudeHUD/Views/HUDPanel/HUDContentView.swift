import SwiftUI

struct HUDContentView: View {
    @EnvironmentObject var appState: AppState

    var body: some View {
        VStack(spacing: 0) {
            // Header bar with mode toggle and status
            HeaderBar()

            Divider()

            // Main content
            if !appState.hasAPIKey {
                APIKeyPromptView()
            } else {
                switch appState.mode {
                case .dashboard:
                    DashboardPlaceholderView()  // Phase 4
                case .chat:
                    ChatView()
                }
            }
        }
        .frame(minWidth: 360, minHeight: 400)
    }
}

struct HeaderBar: View {
    @EnvironmentObject var appState: AppState
    @EnvironmentObject var serverManager: MCPServerManager

    var body: some View {
        HStack {
            // Mode toggle
            Picker("Mode", selection: $appState.mode) {
                Image(systemName: "rectangle.grid.1x2").tag(HUDMode.dashboard)
                Image(systemName: "bubble.left.and.bubble.right").tag(HUDMode.chat)
            }
            .pickerStyle(.segmented)
            .frame(width: 80)

            Spacer()

            // Server status indicator
            HStack(spacing: 4) {
                Circle()
                    .fill(serverManager.isReady ? Color.green : Color.orange)
                    .frame(width: 8, height: 8)
                Text("\(serverManager.clients.count) servers")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }

            // Settings button
            Button(action: { appState.showSettings = true }) {
                Image(systemName: "gear")
            }
            .buttonStyle(.borderless)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }
}

struct APIKeyPromptView: View {
    @EnvironmentObject var appState: AppState
    @State private var apiKey = ""

    var body: some View {
        VStack(spacing: 16) {
            Spacer()
            Image(systemName: "key.fill")
                .font(.largeTitle)
                .foregroundColor(.orange)
            Text("Enter your Anthropic API Key")
                .font(.headline)
            SecureField("sk-ant-...", text: $apiKey)
                .textFieldStyle(.roundedBorder)
                .frame(width: 300)
                .onSubmit { save() }
            Button("Save") { save() }
                .buttonStyle(.borderedProminent)
                .disabled(apiKey.isEmpty)
            Spacer()
        }
        .padding()
    }

    private func save() {
        appState.saveAPIKey(apiKey)
    }
}

struct DashboardPlaceholderView: View {
    var body: some View {
        VStack {
            Spacer()
            Text("Dashboard coming in Phase 4")
                .foregroundColor(.secondary)
            Spacer()
        }
    }
}
