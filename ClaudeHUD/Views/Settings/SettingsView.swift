import SwiftUI

struct SettingsView: View {
    @EnvironmentObject var appState: AppState

    var body: some View {
        TabView {
            APIKeySettingsTab()
                .tabItem { Label("API Key", systemImage: "key") }

            MCPSettingsTab()
                .tabItem { Label("Servers", systemImage: "server.rack") }

            GeneralSettingsTab()
                .tabItem { Label("General", systemImage: "gear") }
        }
        .frame(width: 450, height: 350)
        .padding()
    }
}

struct APIKeySettingsTab: View {
    @EnvironmentObject var appState: AppState
    @State private var apiKey = ""
    @State private var showKey = false
    @State private var saved = false

    var body: some View {
        Form {
            Section {
                if showKey {
                    TextField("API Key", text: $apiKey)
                } else {
                    SecureField("API Key", text: $apiKey)
                }
                Toggle("Show key", isOn: $showKey)

                HStack {
                    Button("Save") {
                        appState.saveAPIKey(apiKey)
                        saved = true
                        DispatchQueue.main.asyncAfter(deadline: .now() + 2) { saved = false }
                    }
                    .disabled(apiKey.isEmpty)

                    if saved {
                        Text("Saved!")
                            .foregroundColor(.green)
                            .font(.caption)
                    }
                }
            } header: {
                Text("Anthropic API Key")
            } footer: {
                Text("Get your key at console.anthropic.com")
                    .font(.caption)
            }

            Section {
                Picker("Default Model", selection: Binding(
                    get: { appState.conversationManager.selectedModel },
                    set: { appState.conversationManager.selectedModel = $0 }
                )) {
                    Text("Claude Sonnet 4").tag("claude-sonnet-4-20250514")
                    Text("Claude Haiku 4.5").tag("claude-haiku-4-5-20251001")
                    Text("Claude Opus 4").tag("claude-opus-4-20250514")
                }
            } header: {
                Text("Model")
            }
        }
        .onAppear {
            apiKey = KeychainService.load() ?? ""
        }
    }
}

struct MCPSettingsTab: View {
    @EnvironmentObject var serverManager: MCPServerManager

    var body: some View {
        Form {
            Section {
                ForEach(Array(serverManager.clients.keys.sorted()), id: \.self) { name in
                    HStack {
                        Circle()
                            .fill(statusColor(for: name))
                            .frame(width: 8, height: 8)
                        Text(name)
                            .font(.body)
                        Spacer()
                        Text(toolCount(for: name))
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                }
            } header: {
                Text("Connected MCP Servers")
            } footer: {
                Text("Servers loaded from ~/.claude/mcp_settings.json")
                    .font(.caption)
            }

            Section {
                Button("Reconnect All") {
                    Task { await serverManager.loadAndStart() }
                }
            }
        }
    }

    private func statusColor(for name: String) -> Color {
        guard let client = serverManager.clients[name] else { return .gray }
        switch client.status {
        case .ready: return .green
        case .connecting: return .orange
        case .error: return .red
        case .disconnected: return .gray
        }
    }

    private func toolCount(for name: String) -> String {
        guard let client = serverManager.clients[name] else { return "" }
        return "\(client.tools.count) tools"
    }
}

struct GeneralSettingsTab: View {
    var body: some View {
        Form {
            Section {
                Text("Cmd + Shift + Space")
                    .font(.system(.body, design: .monospaced))
            } header: {
                Text("Global Hotkey")
            } footer: {
                Text("Customizable hotkeys coming in a future update")
                    .font(.caption)
            }

            Section {
                Toggle("Launch at Login", isOn: .constant(false))
                    .disabled(true)
            } header: {
                Text("Startup")
            } footer: {
                Text("Coming in a future update")
                    .font(.caption)
            }
        }
    }
}
