import SwiftUI
import os

private let logger = Logger(subsystem: "com.claudehud", category: "AppState")

// MARK: - HUD Mode

enum HUDMode {
    case dashboard
    case chat
}

// MARK: - App State

/// Central state object that owns all managers and coordinates the app lifecycle.
@MainActor
class AppState: ObservableObject {
    @Published var mode: HUDMode = .chat
    @Published var isHUDVisible = false
    @Published var hasAPIKey = false
    @Published var showSettings = false

    let serverManager = MCPServerManager()
    let conversationManager: ConversationManager
    let apiClient = ClaudeAPIClient()
    let hotkeyService = HotkeyService()

    // MARK: - Init

    init() {
        self.conversationManager = ConversationManager(
            apiClient: apiClient,
            serverManager: serverManager
        )

        // Load API key from Keychain on launch
        if let key = KeychainService.load() {
            apiClient.setAPIKey(key)
            hasAPIKey = true
            logger.info("API key loaded from Keychain")
        } else {
            logger.info("No API key found in Keychain")
        }
    }

    // MARK: - Setup

    /// Perform async setup after app launch: register hotkey, start MCP servers.
    func setup() async {
        // Register the global hotkey
        hotkeyService.register { [weak self] in
            self?.toggleHUD()
        }

        // Start MCP servers from configuration
        await serverManager.loadAndStart()

        logger.info("AppState setup complete")
    }

    // MARK: - HUD Visibility

    func toggleHUD() {
        isHUDVisible.toggle()
        logger.debug("HUD visibility toggled to \(self.isHUDVisible)")
    }

    func showHUD() {
        isHUDVisible = true
    }

    func hideHUD() {
        isHUDVisible = false
    }

    // MARK: - API Key Management

    func saveAPIKey(_ key: String) {
        do {
            try KeychainService.save(apiKey: key)
            apiClient.setAPIKey(key)
            hasAPIKey = true
            logger.info("API key saved successfully")
        } catch {
            logger.error("Failed to save API key: \(error.localizedDescription)")
        }
    }

    func clearAPIKey() {
        do {
            try KeychainService.delete()
            hasAPIKey = false
            logger.info("API key cleared")
        } catch {
            logger.error("Failed to clear API key: \(error.localizedDescription)")
        }
    }
}
