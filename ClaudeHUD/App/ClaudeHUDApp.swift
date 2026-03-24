import SwiftUI
import Cocoa
import Combine

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
    private var badgeCancellable: AnyCancellable?
    private var badgeView: NSView?

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)

        panelController = HUDPanelController(appState: appState)
        setupStatusItem()

        appState.hotkeyService.register { [weak self] in
            self?.panelController?.toggle()
        }

        // Watch for pending permissions → update menu bar badge
        badgeCancellable = appState.permissionWatcher.$pending
            .receive(on: RunLoop.main)
            .sink { [weak self] pending in
                self?.updateBadge(count: pending.count)
            }

        Task {
            await appState.setup()
        }
    }

    private func setupStatusItem() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)

        if let button = statusItem?.button {
            let icon = NSImage(named: "MenuBarIcon")
            icon?.isTemplate = true
            button.image = icon
            button.action = #selector(statusItemClicked(_:))
            button.target = self
            button.sendAction(on: [.leftMouseUp, .rightMouseUp])
        }
    }

    private func updateBadge(count: Int) {
        guard let button = statusItem?.button else { return }

        if count > 0 {
            if badgeView == nil {
                let size: CGFloat = 12
                let badge = NSView(frame: NSRect(x: button.bounds.width - size - 1, y: button.bounds.height - size - 1, width: size, height: size))
                badge.wantsLayer = true
                badge.layer?.backgroundColor = NSColor.systemRed.cgColor
                badge.layer?.cornerRadius = size / 2

                let textLayer = CATextLayer()
                textLayer.string = "!"
                textLayer.fontSize = 9
                textLayer.font = NSFont.systemFont(ofSize: 9, weight: .bold)
                textLayer.foregroundColor = NSColor.white.cgColor
                textLayer.alignmentMode = .center
                textLayer.contentsScale = NSScreen.main?.backingScaleFactor ?? 2.0
                textLayer.frame = CGRect(x: 0, y: 0, width: size, height: size)
                badge.layer?.addSublayer(textLayer)

                button.addSubview(badge)
                badgeView = badge
            }
        } else {
            badgeView?.removeFromSuperview()
            badgeView = nil
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
