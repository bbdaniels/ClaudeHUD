import Foundation

// MARK: - Client Status

enum MCPClientStatus: Sendable {
    case disconnected
    case connecting
    case ready
    case error(String)
}

// MARK: - Tool Descriptor

struct MCPTool: @unchecked Sendable {
    let name: String
    let description: String
    let inputSchema: [String: Any]

    /// Create from the JSON value returned by `tools/list`.
    init(name: String, description: String, inputSchema: [String: Any]) {
        self.name = name
        self.description = description
        self.inputSchema = inputSchema
    }
}

// MARK: - Tool Call Result

struct MCPToolResult: Sendable {
    let content: String
    let isError: Bool
}

// MARK: - Protocol

@MainActor
protocol MCPClientProtocol: AnyObject {
    var serverName: String { get }
    var status: MCPClientStatus { get }
    var tools: [MCPTool] { get }

    func connect() async throws
    func disconnect()
    func listTools() async throws -> [MCPTool]
    func callTool(name: String, arguments: [String: Any]) async throws -> MCPToolResult
}
