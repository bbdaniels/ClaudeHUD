import SwiftUI
import Cocoa

@main
struct ClaudeHUDApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate

    var body: some Scene {
        // No visible scenes — panel is managed by AppDelegate
        Settings {
            EmptyView()
        }
    }
}

// MARK: - App Delegate

@MainActor
class AppDelegate: NSObject, NSApplicationDelegate {
    let appState = AppState()
    private var panelController: HUDPanelController?
    private var statusItem: NSStatusItem?

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)

        panelController = HUDPanelController(appState: appState)
        setupStatusItem()

        appState.hotkeyService.register { [weak self] in
            self?.panelController?.toggle()
        }

        Task {
            await appState.setup()
        }
    }

    private func setupStatusItem() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)

        if let button = statusItem?.button {
            button.image = NSImage(systemSymbolName: "sparkle", accessibilityDescription: "ClaudeHUD")
            button.action = #selector(statusItemClicked(_:))
            button.target = self
            button.sendAction(on: [.leftMouseUp, .rightMouseUp])
        }
    }

    @objc private func statusItemClicked(_ sender: NSStatusBarButton) {
        let event = NSApp.currentEvent!

        if event.type == .rightMouseUp {
            showContextMenu(sender)
        } else {
            panelController?.toggle()
        }
    }

    private func showContextMenu(_ sender: NSStatusBarButton) {
        let menu = NSMenu()

        menu.addItem(withTitle: "New Conversation", action: #selector(newConversation), keyEquivalent: "n")
            .target = self

        menu.addItem(.separator())

        menu.addItem(withTitle: "Quit ClaudeHUD", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")

        statusItem?.menu = menu
        statusItem?.button?.performClick(nil)
        statusItem?.menu = nil
    }

    @objc private func newConversation() {
        appState.tabManager.addTab()
        panelController?.show()
    }

    func applicationWillTerminate(_ notification: Notification) {
        appState.hotkeyService.unregister()
    }
}
