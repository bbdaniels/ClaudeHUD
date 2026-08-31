import Foundation

// MARK: - Tab Model

struct ConversationTab: Identifiable {
    let id = UUID()
    var title: String
    var subtitle: String? = nil
}

// MARK: - Tab Manager

/// Owns the HUD's terminal tab strip. Tabs are created by "Resume in HUD" in
/// Session History; the strip is empty when none are open.
@MainActor
class TabManager: ObservableObject {
    @Published var tabs: [ConversationTab] = []
    @Published var selectedTabId = UUID()

    private var terminals: [UUID: TerminalSession] = [:]

    var currentTab: ConversationTab? {
        tabs.first { $0.id == selectedTabId }
    }

    /// Adds a terminal tab that runs `command` in `directory`. Surface
    /// creation is deferred until the tab is first rendered, so this is cheap
    /// to call from launcher-style code paths.
    ///
    /// `backgroundColor` is accepted for API symmetry with the external
    /// launcher, but per-surface background tinting is not yet wired in the
    /// embedded path — libghostty's SurfaceConfiguration has no background
    /// field and wrapping the command with an OSC-11 prefix conflicts with
    /// Ghostty's `exec -l` shell wrapping. Colors come from the global
    /// Ghostty config until phase 1.
    @discardableResult
    func addTerminalTab(title: String, command: String?, workingDirectory: String?, backgroundColor: String? = nil, subtitle: String? = nil) -> UUID {
        _ = backgroundColor
        let tab = ConversationTab(title: title, subtitle: subtitle)
        tabs.append(tab)
        terminals[tab.id] = TerminalSession(
            title: title,
            command: command,
            workingDirectory: workingDirectory
        )
        selectedTabId = tab.id
        return tab.id
    }

    func terminalSession(for id: UUID) -> TerminalSession? {
        terminals[id]
    }

    func closeTab(_ id: UUID) {
        terminals[id]?.teardown()
        terminals.removeValue(forKey: id)
        tabs.removeAll { $0.id == id }
        if selectedTabId == id, let last = tabs.last {
            selectedTabId = last.id
        }
    }

    func cancelAll() {
        // Tear down any terminal sessions — the underlying Ghostty.Surface
        // releases the C surface in its deinit, which sends SIGHUP to the PTY
        // child. Drop the tabs too so reopen doesn't show orphan entries.
        for terminal in terminals.values {
            terminal.teardown()
        }
        terminals.removeAll()
        tabs.removeAll()
    }
}
