import Cocoa
import SwiftUI

class HUDPanelController {
    private var panel: NSPanel?
    private let appState: AppState

    init(appState: AppState) {
        self.appState = appState
    }

    func createPanel() {
        let panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 420, height: 600),
            styleMask: [.titled, .closable, .resizable, .hudWindow],
            backing: .buffered,
            defer: false
        )

        panel.level = .normal
        panel.isFloatingPanel = false
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.isOpaque = false
        panel.backgroundColor = NSColor.windowBackgroundColor.withAlphaComponent(0.95)
        panel.titlebarAppearsTransparent = true
        panel.titleVisibility = .hidden
        panel.isMovableByWindowBackground = true
        panel.minSize = NSSize(width: 380, height: 420)
        panel.setFrameAutosaveName("ClaudeHUDPanel")

        if panel.frame.origin == .zero {
            if let screen = NSScreen.main {
                let x = screen.visibleFrame.maxX - 440
                let y = screen.visibleFrame.maxY - 620
                panel.setFrameOrigin(NSPoint(x: x, y: y))
            }
        }

        let contentView = HUDContentView()
            .environmentObject(appState)
            .environmentObject(appState.tabManager)
            .environmentObject(appState.cliClient)
            .environmentObject(appState.pushManager)
            .environmentObject(appState.terminalService)
            .environmentObject(appState.sessionHistoryService)
            .environmentObject(appState.permissionWatcher)
            .environmentObject(appState.vaultManager)
            .environmentObject(appState.calendarService)
            .environmentObject(appState.briefingService)
            .environmentObject(appState.projectService)
            .environmentObject(appState.contactService)
            .environmentObject(appState.substackService)
            .environmentObject(appState.usageService)

        panel.contentView = NSHostingView(rootView: contentView)

        // Cancel running requests when window closes
        NotificationCenter.default.addObserver(
            forName: NSWindow.willCloseNotification,
            object: panel,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                self?.appState.tabManager.cancelAll()
            }
        }

        self.panel = panel
    }

    func show() {
        if panel == nil { createPanel() }
        panel?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    func hide() {
        panel?.orderOut(nil)
    }

    func toggle() {
        if panel?.isVisible == true {
            hide()
        } else {
            show()
        }
    }
}
