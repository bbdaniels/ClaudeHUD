import Foundation
import os

private let logger = Logger(subsystem: "com.claudehud", category: "StdioMCP")

// MARK: - Stdio Transport Actor

/// Manages the child process and JSON-RPC message routing off the main actor.
actor StdioTransport {
    private var process: Process?
    private var stdinPipe: Pipe?
    private var stdoutPipe: Pipe?
    private var stderrPipe: Pipe?
    private var nextId: Int = 1
    private var continuations: [Int: CheckedContinuation<JSONRPCResponse, Error>] = [:]
    private var readTask: Task<Void, Never>?

    private let requestTimeout: Duration = .seconds(30)

    // MARK: Lifecycle

    func start(command: String, args: [String], env: [String: String]?) throws {
        let proc = Process()
        let stdin = Pipe()
        let stdout = Pipe()
        let stderr = Pipe()

        proc.executableURL = URL(fileURLWithPath: command)
        proc.arguments = args
        proc.standardInput = stdin
        proc.standardOutput = stdout
        proc.standardError = stderr

        // Merge caller-supplied env into the current environment so PATH etc. survive.
        var environment = ProcessInfo.processInfo.environment
        if let env {
            for (key, value) in env {
                environment[key] = value
            }
        }
        proc.environment = environment

        proc.terminationHandler = { process in
            logger.warning("MCP process terminated with status \(process.terminationStatus)")
        }

        try proc.run()
        logger.info("Launched MCP process: \(command) \(args.joined(separator: " "))")

        self.process = proc
        self.stdinPipe = stdin
        self.stdoutPipe = stdout
        self.stderrPipe = stderr

        startReading(stdout: stdout)
        startStderrDrain(stderr: stderr)
    }

    func stop() {
        readTask?.cancel()
        readTask = nil

        if let process, process.isRunning {
            process.terminate()
        }
        process = nil

        // Cancel any outstanding continuations.
        let pending = continuations
        continuations.removeAll()
        for (_, continuation) in pending {
            continuation.resume(throwing: CancellationError())
        }

        stdinPipe = nil
        stdoutPipe = nil
        stderrPipe = nil
    }

    // MARK: Sending

    /// Send a request (with id) and wait for the matching response.
    func send(method: String, params: JSONValue?) async throws -> JSONRPCResponse {
        let id = nextId
        nextId += 1

        let request = JSONRPCRequest(id: id, method: method, params: params)
        try writeRequest(request)

        return try await withCheckedThrowingContinuation { continuation in
            // We're inside the actor, so this is safe.
            self.continuations[id] = continuation

            // Schedule a timeout.
            Task { [weak self] in
                try? await Task.sleep(for: .seconds(30))
                await self?.timeoutRequest(id: id)
            }
        }
    }

    /// Send a notification (no id, no response expected).
    func notify(method: String, params: JSONValue?) throws {
        let request = JSONRPCRequest(id: nil, method: method, params: params)
        try writeRequest(request)
    }

    var isRunning: Bool {
        process?.isRunning ?? false
    }

    // MARK: Private Helpers

    private func writeRequest(_ request: JSONRPCRequest) throws {
        guard let stdinPipe else {
            throw MCPError.notConnected
        }
        let encoder = JSONEncoder()
        let data = try encoder.encode(request)
        // Newline-delimited JSON
        var payload = data
        payload.append(contentsOf: [UInt8(ascii: "\n")])
        stdinPipe.fileHandleForWriting.write(payload)
    }

    private func startReading(stdout: Pipe) {
        readTask = Task { [weak self] in
            let handle = stdout.fileHandleForReading
            var buffer = Data()

            while !Task.isCancelled {
                let chunk: Data
                do {
                    chunk = try await self?.readAvailable(from: handle) ?? Data()
                } catch {
                    break
                }
                if chunk.isEmpty {
                    // EOF -- process likely exited.
                    break
                }

                buffer.append(chunk)

                // Process complete lines.
                while let newlineIndex = buffer.firstIndex(of: UInt8(ascii: "\n")) {
                    let lineData = buffer[buffer.startIndex..<newlineIndex]
                    buffer = Data(buffer[buffer.index(after: newlineIndex)...])

                    guard !lineData.isEmpty else { continue }

                    do {
                        let response = try JSONDecoder().decode(JSONRPCResponse.self, from: lineData)
                        await self?.handleResponse(response)
                    } catch {
                        // Could be a notification or malformed line; log and skip.
                        if let line = String(data: lineData, encoding: .utf8) {
                            logger.debug("Non-response line from MCP: \(line)")
                        }
                    }
                }
            }

            logger.info("MCP stdout reader exited")
        }
    }

    private func startStderrDrain(stderr: Pipe) {
        Task.detached {
            let handle = stderr.fileHandleForReading
            while true {
                let data = handle.availableData
                if data.isEmpty { break }
                if let text = String(data: data, encoding: .utf8) {
                    logger.warning("MCP stderr: \(text)")
                }
            }
        }
    }

    /// Read available data from a file handle on a background thread.
    private nonisolated func readAvailable(from handle: FileHandle) async throws -> Data {
        try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global(qos: .utility).async {
                let data = handle.availableData
                continuation.resume(returning: data)
            }
        }
    }

    private func handleResponse(_ response: JSONRPCResponse) {
        guard let id = response.id else {
            // Server-initiated notification; ignore for now.
            logger.debug("Received server notification (no id)")
            return
        }
        if let continuation = continuations.removeValue(forKey: id) {
            continuation.resume(returning: response)
        } else {
            logger.warning("No pending request for response id \(id)")
        }
    }

    private func timeoutRequest(id: Int) {
        if let continuation = continuations.removeValue(forKey: id) {
            continuation.resume(throwing: MCPError.timeout)
        }
    }
}

// MARK: - MCP Errors

enum MCPError: Error, LocalizedError {
    case notConnected
    case timeout
    case serverError(String)
    case processExited(Int32)
    case initializationFailed(String)

    var errorDescription: String? {
        switch self {
        case .notConnected:
            return "MCP client is not connected"
        case .timeout:
            return "MCP request timed out after 30 seconds"
        case .serverError(let msg):
            return "MCP server error: \(msg)"
        case .processExited(let code):
            return "MCP process exited with code \(code)"
        case .initializationFailed(let msg):
            return "MCP initialization failed: \(msg)"
        }
    }
}

// MARK: - Stdio MCP Client

@MainActor
class StdioMCPClient: MCPClientProtocol {
    let serverName: String
    private(set) var status: MCPClientStatus = .disconnected
    private(set) var tools: [MCPTool] = []

    private let command: String
    private let args: [String]
    private let env: [String: String]?
    private let transport = StdioTransport()

    init(name: String, command: String, args: [String], env: [String: String]? = nil) {
        self.serverName = name
        self.command = command
        self.args = args
        self.env = env
    }

    func connect() async throws {
        status = .connecting
        logger.info("Connecting to MCP server '\(self.serverName)' via stdio")

        do {
            try await transport.start(command: command, args: args, env: env)

            // MCP initialization handshake
            let initParams: JSONValue = .object([
                "protocolVersion": .string("2024-11-05"),
                "capabilities": .object([:]),
                "clientInfo": .object([
                    "name": .string("ClaudeHUD"),
                    "version": .string("1.0")
                ])
            ])

            let initResponse = try await transport.send(method: "initialize", params: initParams)

            if let error = initResponse.error {
                throw MCPError.initializationFailed(error.message)
            }

            logger.info("MCP server '\(self.serverName)' initialized: \(String(describing: initResponse.result))")

            // Send initialized notification
            try await transport.notify(method: "notifications/initialized", params: nil)

            status = .ready
            logger.info("MCP server '\(self.serverName)' is ready")

            // Pre-fetch tools
            tools = try await listTools()
        } catch {
            status = .error(error.localizedDescription)
            logger.error("Failed to connect to MCP server '\(self.serverName)': \(error)")
            throw error
        }
    }

    func disconnect() {
        Task {
            await transport.stop()
        }
        status = .disconnected
        tools = []
        logger.info("Disconnected from MCP server '\(self.serverName)'")
    }

    func listTools() async throws -> [MCPTool] {
        let response = try await transport.send(method: "tools/list", params: nil)

        if let error = response.error {
            throw MCPError.serverError(error.message)
        }

        guard let result = response.result,
              case .object(let resultDict) = result,
              case .array(let toolValues) = resultDict["tools"] else {
            return []
        }

        let parsed = toolValues.compactMap { parseTool(from: $0) }
        tools = parsed
        return parsed
    }

    func callTool(name: String, arguments: [String: Any]) async throws -> MCPToolResult {
        let argsValue = JSONValue.from(arguments)
        let params: JSONValue = .object([
            "name": .string(name),
            "arguments": argsValue
        ])

        let response = try await transport.send(method: "tools/call", params: params)

        if let error = response.error {
            throw MCPError.serverError(error.message)
        }

        return parseToolResult(from: response.result)
    }

    // MARK: Private

    private func parseTool(from value: JSONValue) -> MCPTool? {
        guard case .object(let dict) = value,
              case .string(let name) = dict["name"] else {
            return nil
        }

        let description: String
        if case .string(let desc) = dict["description"] {
            description = desc
        } else {
            description = ""
        }

        let inputSchema: [String: Any]
        if let schema = dict["inputSchema"] {
            inputSchema = schema.toAny() as? [String: Any] ?? [:]
        } else {
            inputSchema = [:]
        }

        return MCPTool(name: name, description: description, inputSchema: inputSchema)
    }

    private func parseToolResult(from result: JSONValue?) -> MCPToolResult {
        guard let result,
              case .object(let dict) = result else {
            return MCPToolResult(content: "", isError: false)
        }

        var isError = false
        if case .bool(let flag) = dict["isError"] {
            isError = flag
        }

        // Content is typically an array of content blocks.
        var textParts: [String] = []
        if case .array(let contentArray) = dict["content"] {
            for item in contentArray {
                if case .object(let block) = item,
                   case .string(let text) = block["text"] {
                    textParts.append(text)
                }
            }
        }

        return MCPToolResult(content: textParts.joined(separator: "\n"), isError: isError)
    }
}
