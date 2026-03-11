import SwiftUI
import Cocoa

@main
struct ClaudeHUDApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate

    var body: some Scene {
        // Menu bar icon only — no main window
        MenuBarExtra {
            MenuBarMenu()
                .environmentObject(appDelegate.appState)
                .environmentObject(appDelegate.appState.serverManager)
        } label: {
            Image(systemName: "brain.head.profile")
        }

        // Settings window
        Settings {
            SettingsView()
                .environmentObject(appDelegate.appState)
                .environmentObject(appDelegate.appState.serverManager)
                .environmentObject(appDelegate.appState.conversationManager)
        }
    }
}

// MARK: - App Delegate

@MainActor
class AppDelegate: NSObject, NSApplicationDelegate {
    let appState = AppState()
    private var panelController: HUDPanelController?

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Hide from dock
        NSApp.setActivationPolicy(.accessory)

        // Create panel controller
        panelController = HUDPanelController(appState: appState)

        // Register hotkey
        appState.hotkeyService.register { [weak self] in
            self?.panelController?.toggle()
        }

        // Start MCP servers
        Task {
            await appState.setup()
        }

        // Observe visibility changes
        Task { @MainActor in
            for await isVisible in appState.$isHUDVisible.values {
                if isVisible {
                    panelController?.show()
                } else {
                    panelController?.hide()
                }
            }
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        appState.serverManager.stopAll()
        appState.hotkeyService.unregister()
    }
}

// MARK: - Menu Bar Menu

struct MenuBarMenu: View {
    @EnvironmentObject var appState: AppState
    @EnvironmentObject var serverManager: MCPServerManager

    var body: some View {
        Button("Show HUD") {
            appState.isHUDVisible = true
        }
        .keyboardShortcut("h", modifiers: [.command, .shift])

        Divider()

        HStack {
            Circle()
                .fill(serverManager.isReady ? Color.green : Color.orange)
                .frame(width: 8, height: 8)
            Text("\(serverManager.clients.count) MCP servers")
        }

        Divider()

        Button("New Conversation") {
            appState.conversationManager.newConversation()
            appState.isHUDVisible = true
        }

        Divider()

        SettingsLink {
            Text("Settings...")
        }

        Button("Quit ClaudeHUD") {
            NSApplication.shared.terminate(nil)
        }
        .keyboardShortcut("q")
    }
}
