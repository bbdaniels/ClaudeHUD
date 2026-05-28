import SwiftUI
import os

private let logger = Logger(subsystem: "com.claudehud", category: "AppState")

@MainActor
class AppState: ObservableObject {
    let cliClient = ClaudeCLIClient()
    let serverManager = MCPServerManager()
    let tabManager: TabManager
    let hotkeyService = HotkeyService()
    let pushManager = PushNotificationManager()
    let terminalService = TerminalService()
    let sessionHistoryService = SessionHistoryService()
    let permissionWatcher = PermissionWatcherService()
    let vaultManager = VaultManager()
    let calendarService = CalendarService()
    let briefingService = BriefingService()
    let projectService = ProjectService()
    let projectBriefingService = ProjectBriefingService()
    let contactService = ContactService()
    let remindersService = RemindersService()
    let substackService = SubstackService()
    let usageService = UsageService()
    let skillsService = SkillsService()
    let agentsService = AgentsService()
    let vaultScriptInstaller = VaultScriptInstaller()
    let vaultIngestService = VaultIngestService()
    let vaultProjectService = VaultProjectService()
    lazy var libraryService = LibraryService(skillsService: skillsService)

    /// Lazy-initialized Ghostty application. Only created the first time the
    /// workspace window is opened, so users who never touch the workspace pay
    /// zero libghostty cost.
    lazy var ghosttyApp: Ghostty.App = .init()

    init() {
        self.tabManager = TabManager(cliClient: cliClient)
        projectService.configure(vault: vaultManager, sessions: sessionHistoryService, calendar: calendarService)
    }

    func setup() async {
        // Notification subsystems (push + permission watcher) are superseded
        // by the daemon agent's handler. Force them off and tear down any
        // Claude-hook registrations they previously wrote into
        // ~/.claude/settings.json, so they neither fire nor compete with the
        // daemon. Service code is intentionally kept for easy re-enable.
        if pushManager.isEnabled { await pushManager.setEnabled(false) }
        permissionWatcher.setEnabled(false)
        permissionWatcher.setup()   // disabled-branch: idempotent hook cleanup

        vaultManager.ensureDailyNote(for: Date())

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

        // Today tab pre-warm + state-change refresh. Hard rule: no LLM
        // call on tab open (Documents/Obsidian/ClaudeHUD/Tasks.md
        // §Today tab). `startAutoRefresh` subscribes to CalendarService
        // and RemindersService publishers; the CombineLatest first
        // emission acts as the launch pre-warm, subsequent emissions
        // cover mid-day state drift. The Today tab itself reads only
        // the cached `daySummary` / `briefings` outputs.
        briefingService.startAutoRefresh(
            calendarService: calendarService,
            remindersService: remindersService,
            vaultManager: vaultManager,
            projectService: projectService
        )

        // Unlock secrets vault — single Touch ID prompt for the whole session.
        // Services were initialized before secrets were available, so notify
        // them to re-read now.
        await SecretsVault.shared.unlock()
        substackService.cookieDidChange()
        usageService.cookieDidChange()

        logger.info("AppState setup complete")
    }
}
