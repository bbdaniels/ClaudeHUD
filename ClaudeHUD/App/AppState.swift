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

    init() {
        self.tabManager = TabManager(cliClient: cliClient)
    }

    func setup() async {
        logger.info("AppState setup complete")
    }
}
