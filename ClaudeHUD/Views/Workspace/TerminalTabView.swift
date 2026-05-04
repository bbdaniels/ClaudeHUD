import AppKit
import SwiftUI

/// Renders a terminal tab's Ghostty surface inside the HUD content area.
/// The `TerminalSession` owns the surface instance so switching tabs keeps
/// the PTY alive.
struct TerminalTabView: View {
    @EnvironmentObject var appState: AppState
    let sessionId: UUID

    var body: some View {
        if let session = appState.tabManager.terminalSession(for: sessionId) {
            TerminalHost(session: session)
                .environmentObject(appState)
        } else {
            VStack {
                Text("Terminal session unavailable")
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }
}

/// NSView that refuses to let mouse drags move the enclosing window. Without
/// this, highlighting text in the Ghostty surface drags the HUD panel because
/// the panel is `isMovableByWindowBackground = true`.
///
/// Also forwards layout-driven size changes to the embedded Ghostty surface.
/// Ghostty's `SurfaceView` does not override `setFrameSize`/`viewDidEndLiveResize`;
/// without this hook the PTY stays at its 800x600 init size and never reflows
/// when the HUD panel resizes. (The official Ghostty integration uses
/// `SurfaceRepresentable`/`SurfaceScrollView`, which we bypass to avoid the
/// scroll wrapper inside the panel — so we forward the size ourselves.)
private final class TerminalContainerView: NSView {
    weak var surface: Ghostty.SurfaceView?
    private var lastForwardedSize: NSSize = .zero

    override var mouseDownCanMoveWindow: Bool { false }

    override func layout() {
        super.layout()
        guard let surface else { return }
        let size = surface.bounds.size
        guard size.width > 0, size.height > 0, size != lastForwardedSize else { return }
        lastForwardedSize = size
        surface.sizeDidChange(size)
    }
}

private struct TerminalHost: NSViewRepresentable {
    let session: TerminalSession
    @EnvironmentObject var appState: AppState

    func makeNSView(context: Context) -> NSView {
        let container = TerminalContainerView()
        container.wantsLayer = true
        container.layer?.backgroundColor = NSColor.textBackgroundColor.cgColor

        if let surface = session.ensureSurface(from: appState.ghosttyApp) {
            surface.translatesAutoresizingMaskIntoConstraints = false
            container.addSubview(surface)
            container.surface = surface
            NSLayoutConstraint.activate([
                surface.topAnchor.constraint(equalTo: container.topAnchor),
                surface.bottomAnchor.constraint(equalTo: container.bottomAnchor),
                surface.leadingAnchor.constraint(equalTo: container.leadingAnchor),
                surface.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            ])
            DispatchQueue.main.async { [weak surface] in
                surface?.window?.makeFirstResponder(surface)
            }
        }
        return container
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        // Ensure focus returns to the surface when the tab becomes visible.
        if let surface = session.surface {
            DispatchQueue.main.async { [weak surface] in
                surface?.window?.makeFirstResponder(surface)
            }
        }
    }
}
