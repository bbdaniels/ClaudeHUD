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
    let usageService = UsageService()
    let skillsService = SkillsService()
    let agentsService = AgentsService()
    let processMonitor = ClaudeProcessMonitor()
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
    }

    func setup() async {
        vaultManager.ensureDailyNote(for: Date())

        // Reap stale background sessions. The daemon never flushes a terminal
        // state when a worker dies abnormally, so `~/.claude/jobs` fills with
        // sessions frozen at "blocked" that `claude agents` renders as
        // awaiting input forever. Scan and delete run off-main; doing it here
        // rather than only on Agents-tab open is what makes it automatic.
        AgentsService.reapStaleAtLaunch()

        // Background jobs and orphaned workers for the menu-bar menu: a scan
        // every 15 minutes (and on each menu open). Read-only; closing an
        // orphan is always a confirmed click.
        processMonitor.start()

        // Vault scripts: observation-only at launch. Records per-file
        // status in the log; never writes.
        vaultScriptInstaller.audit()

        // Vault session state: poll every 30s for per-project Sessions.md
        // provenance. Read-only; the daily review (personal repo,
        // vault/daily_review) owns the ledger writes.
        let vaultURL = vaultManager.currentVault.map { URL(fileURLWithPath: $0.path) }
        vaultIngestService.start(vaultPath: vaultURL)
        vaultProjectService.start(vaultPath: vaultURL)

        // Session scan at launch, which also brings the transcript search
        // index up to date off-main, so the first History search is warm.
        Task { await sessionHistoryService.refresh() }

        // Unlock secrets vault — single Touch ID prompt for the whole session.
        // Services were initialized before secrets were available, so notify
        // them to re-read now.
        await SecretsVault.shared.unlock()
        usageService.cookieDidChange()

        logger.info("AppState setup complete")
    }
}
