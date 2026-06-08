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
            // No .hudWindow: HUD-style panels suppress AppKit tooltips
            // (NSView.toolTip / SwiftUI .help) entirely. The titlebar is
            // already hidden via titleVisibility/titlebarAppearsTransparent
            // and the SwiftUI content draws its own translucent background,
            // so dropping .hudWindow is visually ~identical but restores
            // tooltips.
            styleMask: [.titled, .closable, .resizable],
            backing: .buffered,
            defer: false
        )

        panel.level = .normal
        panel.isFloatingPanel = false
        panel.hidesOnDeactivate = false
        // THE tooltip fix. This is an .accessory (menubar agent) app whose
        // panel is shown from a status-item click, so the app is usually NOT
        // the active app while the user mouses over the panel. macOS suppresses
        // NSView.toolTip (which SwiftUI `.help()` uses) for windows of an
        // inactive app unless this is set — which is why NO tooltip ever
        // appeared, regardless of the host view or .hudWindow.
        panel.allowsToolTipsWhenApplicationIsInactive = true
        panel.isReleasedWhenClosed = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.isOpaque = true
        panel.backgroundColor = NSColor.windowBackgroundColor
        panel.titlebarAppearsTransparent = true
        panel.titleVisibility = .hidden
        // Was true ("drag anywhere to move the window"), but AppKit's
        // move-by-background tracking consumes mouse-drag sequences over the
        // SwiftUI content before any in-content gesture or system drag sees them
        // — clicks still land (tab switching works) but NO drag does (tab
        // reordering, etc.). Off here; the window is still movable by its
        // (hidden, transparent) title-bar strip at the very top. See
        // HUDContentView.TabBar drag-to-reorder.
        panel.isMovableByWindowBackground = false
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
            .environmentObject(appState.usageService)
            .environmentObject(appState.skillsService)

        // Host SwiftUI via an NSHostingController set as contentViewController,
        // NOT a bare NSHostingView assigned to contentView. SwiftUI `.help()`
        // tooltips are delivered through the hosting *controller*'s
        // participation in the responder chain; with a raw NSHostingView there
        // is no controller, so every `.help(...)` in the app silently no-ops
        // and no tooltip ever appears.
        panel.contentViewController = NSHostingController(rootView: contentView)

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
