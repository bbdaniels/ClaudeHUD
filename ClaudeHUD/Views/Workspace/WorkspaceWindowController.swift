import AppKit
import SwiftUI

/// Owns the workspace NSWindow — a standard titled window separate from the
/// floating HUD panel. Phase 0 mounts a single Ghostty terminal surface as
/// the content view; splits/tabs/launcher-driven tabs ride in later phases.
@MainActor
final class WorkspaceWindowController {
    private var window: NSWindow?
    private let appState: AppState
    private var hostedSurface: Ghostty.SurfaceView?

    init(appState: AppState) {
        self.appState = appState
    }

    func toggle() {
        if let window, window.isVisible {
            window.orderOut(nil)
        } else {
            show()
        }
    }

    func show() {
        if window == nil { createWindow() }
        guard let window else { return }

        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
        if let surface = hostedSurface {
            window.makeFirstResponder(surface)
        }
    }

    private func createWindow() {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 900, height: 600),
            styleMask: [.titled, .closable, .resizable, .miniaturizable],
            backing: .buffered,
            defer: false
        )
        window.title = "ClaudeHUD Workspace"
        window.setFrameAutosaveName("ClaudeHUDWorkspace")
        window.isReleasedWhenClosed = false
        window.minSize = NSSize(width: 600, height: 400)
        window.collectionBehavior = [.fullScreenPrimary]

        if window.frame.origin == .zero, let screen = NSScreen.main {
            let x = screen.visibleFrame.midX - 450
            let y = screen.visibleFrame.midY - 300
            window.setFrameOrigin(NSPoint(x: x, y: y))
        }

        window.contentView = makeContentView()
        self.window = window
    }

    private func makeContentView() -> NSView {
        let container = NSStackView()
        container.orientation = .vertical
        container.spacing = 0
        container.distribution = .fill
        container.translatesAutoresizingMaskIntoConstraints = false

        let toolbarHost = NSHostingView(rootView: WorkspaceToolbarView().environmentObject(appState))
        toolbarHost.translatesAutoresizingMaskIntoConstraints = false
        toolbarHost.setContentHuggingPriority(.defaultHigh, for: .vertical)

        let surfaceContainer = NSView()
        surfaceContainer.translatesAutoresizingMaskIntoConstraints = false

        if let surface = makeSurface() {
            hostedSurface = surface
            surface.translatesAutoresizingMaskIntoConstraints = false
            surfaceContainer.addSubview(surface)
            NSLayoutConstraint.activate([
                surface.topAnchor.constraint(equalTo: surfaceContainer.topAnchor),
                surface.bottomAnchor.constraint(equalTo: surfaceContainer.bottomAnchor),
                surface.leadingAnchor.constraint(equalTo: surfaceContainer.leadingAnchor),
                surface.trailingAnchor.constraint(equalTo: surfaceContainer.trailingAnchor),
            ])
        } else {
            let placeholder = NSHostingView(rootView: WorkspaceFallbackView())
            placeholder.translatesAutoresizingMaskIntoConstraints = false
            surfaceContainer.addSubview(placeholder)
            NSLayoutConstraint.activate([
                placeholder.topAnchor.constraint(equalTo: surfaceContainer.topAnchor),
                placeholder.bottomAnchor.constraint(equalTo: surfaceContainer.bottomAnchor),
                placeholder.leadingAnchor.constraint(equalTo: surfaceContainer.leadingAnchor),
                placeholder.trailingAnchor.constraint(equalTo: surfaceContainer.trailingAnchor),
            ])
        }

        container.addArrangedSubview(toolbarHost)
        container.addArrangedSubview(surfaceContainer)
        return container
    }

    private func makeSurface() -> Ghostty.SurfaceView? {
        let app = appState.ghosttyApp
        guard app.readiness == .ready, let ghostty = app.app else {
            return nil
        }
        return Ghostty.SurfaceView(ghostty, baseConfig: nil, uuid: nil)
    }
}

private struct WorkspaceToolbarView: View {
    @EnvironmentObject var appState: AppState

    var body: some View {
        HStack(spacing: 8) {
            Button { } label: { Label("+ Terminal", systemImage: "plus.square") }
            Button { } label: { Label("Split H", systemImage: "rectangle.split.2x1") }
            Button { } label: { Label("Split V", systemImage: "rectangle.split.1x2") }
            Button { } label: { Label("Close Leaf", systemImage: "xmark.square") }
            Spacer()
            Text("Phase 0")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .buttonStyle(.borderless)
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(.regularMaterial)
        .disabled(true)
    }
}

private struct WorkspaceFallbackView: View {
    var body: some View {
        VStack(spacing: 12) {
            Image(systemName: "terminal")
                .font(.system(size: 48))
                .foregroundStyle(.secondary)
            Text("libghostty not ready.")
                .font(.title3)
            Text("Check console for Ghostty.App initialization errors.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(nsColor: .textBackgroundColor))
    }
}
