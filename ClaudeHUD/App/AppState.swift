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

    init() {
        self.tabManager = TabManager(cliClient: cliClient)
        projectService.configure(vault: vaultManager, sessions: sessionHistoryService, calendar: calendarService)
    }

    func setup() async {
        permissionWatcher.start()
        vaultManager.ensureDailyNote(for: Date())
        logger.info("AppState setup complete")
    }
}
