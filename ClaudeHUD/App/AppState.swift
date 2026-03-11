import SwiftUI
import os

private let logger = Logger(subsystem: "com.claudehud", category: "AppState")

@MainActor
class AppState: ObservableObject {
    @Published var showSettings = false

    let cliClient = ClaudeCLIClient()
    let serverManager = MCPServerManager()
    let conversationManager: ConversationManager
    let hotkeyService = HotkeyService()

    init() {
        self.conversationManager = ConversationManager(cliClient: cliClient)
    }

    func setup() async {
        logger.info("AppState setup complete")
    }
}
