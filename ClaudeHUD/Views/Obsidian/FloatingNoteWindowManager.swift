import SwiftUI
import AppKit

@MainActor
class FloatingNoteWindowManager: ObservableObject {
    static let shared = FloatingNoteWindowManager()

    private var openWindows: [UUID: NSWindow] = [:]
    private var windowFilePaths: [UUID: String] = [:]

    private init() {}

    func openWindow(for file: NoteFile) {
        // Reuse existing window for this file
        if let existingID = windowFilePaths.first(where: { $0.value == file.path })?.key,
           let existingWindow = openWindows[existingID] {
            existingWindow.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }

        let windowID = UUID()

        let contentView = NoteContentView(file: file, windowID: windowID) { [weak self] id in
            self?.closeWindow(id: id)
        }

        let hostingView = NSHostingView(rootView: contentView)

        let window = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 500, height: 600),
            styleMask: [.titled, .closable, .resizable, .nonactivatingPanel, .hudWindow],
            backing: .buffered,
            defer: false
        )

        window.contentView = hostingView
        window.title = file.name.replacingOccurrences(of: ".md", with: "")
        window.center()
        window.setFrameAutosaveName("ObsidianNote-\(file.path.hashValue)")
        window.isReleasedWhenClosed = false
        window.minSize = NSSize(width: 300, height: 200)
        window.level = .floating
        window.isFloatingPanel = true
        window.hidesOnDeactivate = false
        window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        window.isOpaque = false
        window.backgroundColor = NSColor.windowBackgroundColor.withAlphaComponent(0.95)
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        window.isMovableByWindowBackground = true

        NotificationCenter.default.addObserver(
            forName: NSWindow.willCloseNotification,
            object: window,
            queue: .main
        ) { [weak self] notification in
            if let closingWindow = notification.object as? NSWindow,
               let id = self?.openWindows.first(where: { $0.value === closingWindow })?.key {
                self?.openWindows.removeValue(forKey: id)
                self?.windowFilePaths.removeValue(forKey: id)
            }
        }

        openWindows[windowID] = window
        windowFilePaths[windowID] = file.path
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    func closeWindow(id: UUID) {
        if let window = openWindows[id] {
            window.close()
            openWindows.removeValue(forKey: id)
            windowFilePaths.removeValue(forKey: id)
        }
    }
}
