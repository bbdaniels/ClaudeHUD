// Stubs for Ghostty feature-layer types that vendored sources reference but we
// don't need to implement for phase-0 embedding. Minimize here; add more only
// when the compiler demands it. None of these stubs is reached at runtime
// because our workspace doesn't emit the libghostty actions that trigger them.

import AppKit
import OSLog
import SwiftUI

// isRunningInXcode comes from vendored Helpers/AppInfo.swift.

// MARK: - Terminal controller/window stand-ins

class BaseTerminalController: NSWindowController {
    @objc func changeTabTitle(_ sender: Any? = nil) {}
    @objc func promptTabTitle(_ sender: Any? = nil) {}
    @objc func toggleBackgroundOpacity(_ sender: Any? = nil) {}
    var surfaceTree: SurfaceTreeStub {
        get { SurfaceTreeStub() }
        set { }
    }
    var focusedSurface: Ghostty.SurfaceView? { nil }
    var titleOverride: String? {
        get { nil }
        set { }
    }
    var commandPaletteIsShowing: Bool { false }
    var focusFollowsMouse: Bool { false }
}

class TerminalWindow: NSWindow {
    func isTabBar(_ child: Any?) -> Bool { false }
}

class HiddenTitlebarTerminalWindow: TerminalWindow {}

// MARK: - Restore error

enum TerminalRestoreError: Error {
    case delegateInvalid
    case surfaceNotFound
    case restorationFailed
}

struct SurfaceTreeStub {
    var isSplit: Bool { false }
    var root: SurfaceTreeRoot? { nil }
    func focusTarget(for direction: SplitTree<Ghostty.SurfaceView>.FocusDirection, from node: SurfaceTreeNode) -> SurfaceTreeNode? { nil }
}

struct SurfaceTreeRoot {
    func node(view: Ghostty.SurfaceView) -> SurfaceTreeNode? { nil }
}

struct SurfaceTreeNode {}

// MARK: - Split tree placeholder

struct SplitTree<T> {
    enum FocusDirection {
        case previous
        case next
        case spatial(SplitFocusDirection)
    }
}

enum SplitFocusDirection {
    case up, down, left, right

    static func from(direction: some Any) -> SplitFocusDirection? { nil }

    func toSplitTreeFocusDirection() -> SplitTree<Ghostty.SurfaceView>.FocusDirection {
        .spatial(self)
    }
}

// MARK: - Secure input

final class SecureInput: ObservableObject {
    static let shared = SecureInput()
    @Published var enabled: Bool = false
    func setScoped(_ id: ObjectIdentifier, focused: Bool) {}
    func removeScoped(_ id: ObjectIdentifier) {}
}

struct SecureInputOverlay: View {
    var body: some View { EmptyView() }
}

// FullscreenMode comes from vendored Helpers/Fullscreen.swift.

// MARK: - Quick Terminal placeholders

enum QuickTerminalPosition: String {
    case top, bottom, left, right, center
}

enum QuickTerminalScreen {
    case main
    init?(fromGhosttyConfig: String) { return nil }
}

enum QuickTerminalSpaceBehavior {
    case move
    init?(fromGhosttyConfig: String) { return nil }
}

struct QuickTerminalSize {
    init() {}
    init(primary: Any? = nil, secondary: Any? = nil) {}
    init(from: Any) {}
}

// MARK: - Auto update

enum AutoUpdateChannel: String {
    case stable
    case tip
}

// MARK: - AppDelegate bridge

/// Methods/properties the vendored Ghostty.App.swift expects on
/// `NSApp.delegate as? AppDelegate`. ClaudeHUD's AppDelegate is main-actor; we
/// expose these as `nonisolated` no-ops because Ghostty calls them from
/// nonisolated C-callback contexts. None are invoked in phase 0.
extension AppDelegate {
    nonisolated var ghostty: Ghostty.App {
        MainActor.assumeIsolated { appState.ghosttyApp }
    }

    nonisolated func checkForUpdates(_ sender: Any?) {}
    nonisolated func closeAllWindows(_ sender: Any?) {}
    nonisolated func setSecureInput(_ mode: Any?) {}
    nonisolated func syncFloatOnTopMenu(_ window: NSWindow?) {}
    nonisolated func toggleQuickTerminal(_ sender: Any?) {}
    nonisolated func toggleVisibility(_ sender: Any?) {}
    nonisolated func performGhosttyBindingMenuKeyEquivalent(with event: NSEvent) -> Bool { false }

    nonisolated var undoManager: UndoManager? { nil }

    nonisolated static var logger: Logger {
        Logger(subsystem: "com.claudehud.app", category: "ghostty-vendored")
    }
}
