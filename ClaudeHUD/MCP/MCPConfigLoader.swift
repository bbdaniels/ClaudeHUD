import Foundation
import os

private let logger = Logger(subsystem: "com.claudehud", category: "MCPConfig")

// MARK: - Server Configuration

struct MCPServerConfig: Codable {
    let command: String?
    let args: [String]?
    let env: [String: String]?
    let type: String?
    let url: String?

    /// True when this server uses SSE transport instead of stdio.
    var isSSE: Bool { type == "sse" }
}

// MARK: - Config File Shape

private struct MCPSettingsFile: Codable {
    let mcpServers: [String: MCPServerConfig]
}

// MARK: - Loader

struct MCPConfigLoader {
    /// Default path: `~/.claude/mcp_settings.json`
    static let defaultPath: URL = {
        let home = FileManager.default.homeDirectoryForCurrentUser
        return home.appendingPathComponent(".claude/mcp_settings.json")
    }()

    /// Load MCP server configurations from disk.
    ///
    /// - Parameter path: The file URL to read. Defaults to `~/.claude/mcp_settings.json`.
    /// - Returns: Dictionary of server name to config. Returns empty dict if the file is missing.
    static func load(from path: URL = defaultPath) -> [String: MCPServerConfig] {
        guard FileManager.default.fileExists(atPath: path.path) else {
            logger.info("MCP settings file not found at \(path.path)")
            return [:]
        }

        do {
            let data = try Data(contentsOf: path)
            let settings = try JSONDecoder().decode(MCPSettingsFile.self, from: data)
            logger.info("Loaded \(settings.mcpServers.count) MCP server config(s) from \(path.path)")
            return settings.mcpServers
        } catch {
            logger.error("Failed to parse MCP settings: \(error)")
            return [:]
        }
    }
}
