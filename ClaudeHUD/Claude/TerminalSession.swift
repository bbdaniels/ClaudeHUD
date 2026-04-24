import AppKit
import GhosttyKit

/// Per-tab owner for a Ghostty terminal. Holds the SurfaceView and its PTY
/// configuration so the surface persists across tab switches (SwiftUI
/// rebuilds views on appear, but the stored surface NSView stays alive).
@MainActor
final class TerminalSession {
    let id = UUID()
    let title: String
    let command: String?
    let workingDirectory: String?
    private(set) var surface: Ghostty.SurfaceView?
    private weak var ghosttyApp: Ghostty.App?

    init(title: String, command: String?, workingDirectory: String?) {
        self.title = title
        self.command = command
        self.workingDirectory = workingDirectory
    }

    /// Creates the surface on first access. Returns nil if libghostty is not
    /// ready; caller should retry or fall back.
    func ensureSurface(from app: Ghostty.App) -> Ghostty.SurfaceView? {
        if let surface { return surface }
        ghosttyApp = app
        guard app.readiness == .ready, let ghostty = app.app else {
            return nil
        }

        var config = Ghostty.SurfaceConfiguration()
        config.command = command
        config.workingDirectory = workingDirectory

        let surface = Ghostty.SurfaceView(ghostty, baseConfig: config, uuid: id)
        self.surface = surface
        return surface
    }

    func teardown() {
        surface = nil
    }
}
