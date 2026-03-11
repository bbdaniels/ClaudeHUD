import Foundation
import os

private let logger = Logger(subsystem: "com.claudehud", category: "MCPManager")

@MainActor
class MCPServerManager: ObservableObject {
    @Published var clients: [String: any MCPClientProtocol] = [:]
    @Published var allTools: [MCPTool] = []
    @Published var isReady = false

    /// Maps a prefixed tool name (`mcp__server__tool`) to the server name.
    private var toolToServer: [String: String] = [:]

    // MARK: Lifecycle

    /// Load config, create clients, connect all servers in parallel.
    func loadAndStart() async {
        let configs = MCPConfigLoader.load()

        guard !configs.isEmpty else {
            logger.info("No MCP servers configured")
            isReady = true
            return
        }

        // Create client instances.
        for (name, config) in configs {
            let client: any MCPClientProtocol
            if config.isSSE, let urlString = config.url, let url = URL(string: urlString) {
                client = SSEMCPClient(name: name, url: url)
            } else if let command = config.command {
                client = StdioMCPClient(
                    name: name,
                    command: command,
                    args: config.args ?? [],
                    env: config.env
                )
            } else {
                logger.warning("Skipping MCP server '\(name)': no command or SSE URL configured")
                continue
            }
            clients[name] = client
        }

        // Connect all in parallel.
        await withTaskGroup(of: Void.self) { group in
            for (name, client) in clients {
                group.addTask { @MainActor in
                    do {
                        try await client.connect()
                        logger.info("MCP server '\(name)' connected with \(client.tools.count) tool(s)")
                    } catch {
                        logger.error("MCP server '\(name)' failed to connect: \(error)")
                    }
                }
            }
        }

        // Build the unified tool list.
        await refreshTools()
        isReady = true
        logger.info("MCPServerManager ready: \(self.allTools.count) total tool(s) across \(self.clients.count) server(s)")
    }

    /// Disconnect all clients.
    func stopAll() {
        for (_, client) in clients {
            client.disconnect()
        }
        clients.removeAll()
        allTools.removeAll()
        toolToServer.removeAll()
        isReady = false
    }

    // MARK: Tool Invocation

    /// Call a tool by its prefixed name (e.g. `mcp__obsidian__obsidian_search`).
    func callTool(name: String, arguments: [String: Any]) async throws -> MCPToolResult {
        guard let serverName = toolToServer[name] else {
            throw MCPError.serverError("No server found for tool '\(name)'")
        }
        guard let client = clients[serverName] else {
            throw MCPError.notConnected
        }

        // Strip the `mcp__servername__` prefix to get the original tool name.
        let prefix = "mcp__\(serverName)__"
        let originalName: String
        if name.hasPrefix(prefix) {
            originalName = String(name.dropFirst(prefix.count))
        } else {
            originalName = name
        }

        return try await client.callTool(name: originalName, arguments: arguments)
    }

    // MARK: Tool Refresh

    /// Rebuild the unified `allTools` list and routing table from all connected clients.
    func refreshTools() async {
        var tools: [MCPTool] = []
        var routing: [String: String] = [:]

        for (serverName, client) in clients {
            // Re-fetch if the client is ready.
            var serverTools = client.tools
            if case .ready = client.status, serverTools.isEmpty {
                do {
                    serverTools = try await client.listTools()
                } catch {
                    logger.warning("Failed to refresh tools for '\(serverName)': \(error)")
                    continue
                }
            }

            for tool in serverTools {
                let prefixed = "mcp__\(serverName)__\(tool.name)"
                let aliased = MCPTool(
                    name: prefixed,
                    description: "[\(serverName)] \(tool.description)",
                    inputSchema: tool.inputSchema
                )
                tools.append(aliased)
                routing[prefixed] = serverName
            }
        }

        allTools = tools
        toolToServer = routing
    }
}
