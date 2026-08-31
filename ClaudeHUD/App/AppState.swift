import SwiftUI
import os

private let logger = Logger(subsystem: "com.claudehud", category: "AppState")

@MainActor
class AppState: ObservableObject {
    let serverManager = MCPServerManager()
    let tabManager = TabManager()
    let hotkeyService = HotkeyService()
    let terminalService = TerminalService()
    let sessionHistoryService = SessionHistoryService()
    let vaultManager = VaultManager()
    let projectService = ProjectService()
    let usageService = UsageService()
    let skillsService = SkillsService()
    let agentsService = AgentsService()
    let vaultScriptInstaller = VaultScriptInstaller()
    let vaultIngestService = VaultIngestService()
    let vaultProjectService = VaultProjectService()
    let screenCoverService: ScreenCoverService
    lazy var libraryService = LibraryService(skillsService: skillsService)

    /// Lazy-initialized Ghostty application. Only created the first time the
    /// workspace window is opened, so users who never touch the workspace pay
    /// zero libghostty cost.
    lazy var ghosttyApp: Ghostty.App = .init()

    init() {
        self.screenCoverService = ScreenCoverService(agents: agentsService)
        projectService.configure(vault: vaultManager, sessions: sessionHistoryService)
    }

    func setup() async {
        vaultManager.ensureDailyNote(for: Date())

        // Reap stale background sessions. The daemon never flushes a terminal
        // state when a worker dies abnormally, so `~/.claude/jobs` fills with
        // sessions frozen at "blocked" that `claude agents` renders as
        // awaiting input forever. Scan and delete run off-main; doing it here
        // rather than only on Agents-tab open is what makes it automatic.
        AgentsService.reapStaleAtLaunch()

        // Vault scripts: observation-only at launch (Phase 1 of the vault
        // tooling consolidation; see Documents/Obsidian/ClaudeHUD/Technical
        // Notes.md §Vault tooling architecture). Records per-file status so
        // the upcoming cockpit UI can surface conflicts; never writes.
        vaultScriptInstaller.audit()

        // Vault ingest state: poll every 30s for .done/.failed markers,
        // per-project Sessions.md provenance, sync log status. Feeds the
        // Vault cockpit (Phase 5) and Session-History badges (Phase 4).
        // Read-only; workers (SessionEnd hook, launchd sync) own writes.
        let vaultURL = vaultManager.currentVault.map { URL(fileURLWithPath: $0.path) }
        vaultIngestService.start(vaultPath: vaultURL)
        vaultProjectService.start(vaultPath: vaultURL)

        // Unlock secrets vault — single Touch ID prompt for the whole session.
        // Services were initialized before secrets were available, so notify
        // them to re-read now.
        await SecretsVault.shared.unlock()
        usageService.cookieDidChange()

        logger.info("AppState setup complete")
    }
}
