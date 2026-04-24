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

private struct TerminalHost: NSViewRepresentable {
    let session: TerminalSession
    @EnvironmentObject var appState: AppState

    func makeNSView(context: Context) -> NSView {
        let container = NSView()
        container.wantsLayer = true
        container.layer?.backgroundColor = NSColor.textBackgroundColor.cgColor

        if let surface = session.ensureSurface(from: appState.ghosttyApp) {
            surface.translatesAutoresizingMaskIntoConstraints = false
            container.addSubview(surface)
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
