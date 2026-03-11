import Foundation
import os

private let logger = Logger(subsystem: "com.claudehud", category: "SSEMCP")

// MARK: - SSE Transport Actor

/// Manages an SSE connection and routes JSON-RPC over HTTP POST.
///
/// MCP SSE protocol:
/// 1. Open a GET request to the SSE endpoint.
/// 2. The server sends an `endpoint` event whose data is the URL to POST requests to.
/// 3. POST JSON-RPC requests to that URL.
/// 4. Responses arrive as SSE `data:` lines on the GET stream, each containing a full JSON-RPC response.
actor SSETransport {
    private let baseURL: URL
    private var postEndpoint: URL?
    private var nextId: Int = 1
    private var continuations: [Int: CheckedContinuation<JSONRPCResponse, Error>] = [:]
    private var sseTask: Task<Void, Never>?
    private var endpointContinuation: CheckedContinuation<URL, Error>?
    private let session: URLSession

    init(url: URL) {
        self.baseURL = url
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 300 // Long-lived SSE
        config.timeoutIntervalForResource = 600
        self.session = URLSession(configuration: config)
    }

    func start() async throws {
        // Open the SSE stream and wait for the endpoint event.
        let endpointURL: URL = try await withCheckedThrowingContinuation { continuation in
            self.endpointContinuation = continuation
            self.sseTask = Task { [weak self] in
                await self?.runSSEStream()
            }
        }

        self.postEndpoint = endpointURL
        logger.info("SSE endpoint resolved: \(endpointURL.absoluteString)")
    }

    func stop() {
        sseTask?.cancel()
        sseTask = nil
        postEndpoint = nil

        let pending = continuations
        continuations.removeAll()
        for (_, continuation) in pending {
            continuation.resume(throwing: CancellationError())
        }

        if let ec = endpointContinuation {
            endpointContinuation = nil
            ec.resume(throwing: CancellationError())
        }
    }

    /// Send a JSON-RPC request via HTTP POST and wait for the response on the SSE stream.
    func send(method: String, params: JSONValue?) async throws -> JSONRPCResponse {
        guard let postEndpoint else {
            throw MCPError.notConnected
        }

        let id = nextId
        nextId += 1

        let request = JSONRPCRequest(id: id, method: method, params: params)
        let data = try JSONEncoder().encode(request)

        var urlRequest = URLRequest(url: postEndpoint)
        urlRequest.httpMethod = "POST"
        urlRequest.setValue("application/json", forHTTPHeaderField: "Content-Type")
        urlRequest.httpBody = data

        // Fire the POST (response comes via SSE, but the POST itself may return 200/202).
        let (_, httpResponse) = try await session.data(for: urlRequest)
        if let http = httpResponse as? HTTPURLResponse, http.statusCode >= 400 {
            throw MCPError.serverError("POST returned HTTP \(http.statusCode)")
        }

        return try await withCheckedThrowingContinuation { continuation in
            self.continuations[id] = continuation

            Task { [weak self] in
                try? await Task.sleep(for: .seconds(30))
                await self?.timeoutRequest(id: id)
            }
        }
    }

    /// Send a notification via HTTP POST (no response expected).
    func notify(method: String, params: JSONValue?) async throws {
        guard let postEndpoint else {
            throw MCPError.notConnected
        }

        let request = JSONRPCRequest(id: nil, method: method, params: params)
        let data = try JSONEncoder().encode(request)

        var urlRequest = URLRequest(url: postEndpoint)
        urlRequest.httpMethod = "POST"
        urlRequest.setValue("application/json", forHTTPHeaderField: "Content-Type")
        urlRequest.httpBody = data

        let (_, httpResponse) = try await session.data(for: urlRequest)
        if let http = httpResponse as? HTTPURLResponse, http.statusCode >= 400 {
            logger.warning("Notification POST returned HTTP \(http.statusCode)")
        }
    }

    // MARK: Private

    private func runSSEStream() async {
        var urlRequest = URLRequest(url: baseURL)
        urlRequest.setValue("text/event-stream", forHTTPHeaderField: "Accept")

        do {
            let (bytes, response) = try await session.bytes(for: urlRequest)
            if let http = response as? HTTPURLResponse, http.statusCode >= 400 {
                endpointContinuation?.resume(throwing: MCPError.serverError("SSE GET returned HTTP \(http.statusCode)"))
                endpointContinuation = nil
                return
            }

            var currentEvent: String?
            var currentData: String = ""

            for try await line in bytes.lines {
                if Task.isCancelled { break }

                if line.hasPrefix("event:") {
                    currentEvent = line.dropFirst(6).trimmingCharacters(in: .whitespaces)
                } else if line.hasPrefix("data:") {
                    let data = String(line.dropFirst(5)).trimmingCharacters(in: .whitespaces)
                    currentData += data
                } else if line.isEmpty {
                    // End of event -- dispatch.
                    await handleSSEEvent(event: currentEvent, data: currentData)
                    currentEvent = nil
                    currentData = ""
                }
            }
        } catch {
            if !Task.isCancelled {
                logger.error("SSE stream error: \(error)")
                endpointContinuation?.resume(throwing: error)
                endpointContinuation = nil
            }
        }
    }

    private func handleSSEEvent(event: String?, data: String) {
        // The `endpoint` event provides the URL to POST to.
        if event == "endpoint" {
            let urlString = data.trimmingCharacters(in: .whitespacesAndNewlines)
            // The endpoint may be relative or absolute.
            let resolved: URL?
            if urlString.hasPrefix("http://") || urlString.hasPrefix("https://") {
                resolved = URL(string: urlString)
            } else {
                // Resolve relative to baseURL's origin.
                var components = URLComponents(url: baseURL, resolvingAgainstBaseURL: false)
                components?.path = urlString
                components?.query = nil
                resolved = components?.url
            }

            if let url = resolved {
                endpointContinuation?.resume(returning: url)
                endpointContinuation = nil
            } else {
                endpointContinuation?.resume(throwing: MCPError.initializationFailed("Invalid endpoint URL: \(urlString)"))
                endpointContinuation = nil
            }
            return
        }

        // Otherwise treat as a JSON-RPC response.
        guard let jsonData = data.data(using: .utf8) else { return }
        do {
            let response = try JSONDecoder().decode(JSONRPCResponse.self, from: jsonData)
            if let id = response.id, let continuation = continuations.removeValue(forKey: id) {
                continuation.resume(returning: response)
            } else {
                logger.debug("Received SSE message with no matching request id")
            }
        } catch {
            logger.debug("Unparseable SSE data line: \(data)")
        }
    }

    private func timeoutRequest(id: Int) {
        if let continuation = continuations.removeValue(forKey: id) {
            continuation.resume(throwing: MCPError.timeout)
        }
    }
}

// MARK: - SSE MCP Client

@MainActor
class SSEMCPClient: MCPClientProtocol {
    let serverName: String
    private(set) var status: MCPClientStatus = .disconnected
    private(set) var tools: [MCPTool] = []

    private let url: URL
    private let transport: SSETransport

    init(name: String, url: URL) {
        self.serverName = name
        self.url = url
        self.transport = SSETransport(url: url)
    }

    func connect() async throws {
        status = .connecting
        logger.info("Connecting to MCP server '\(self.serverName)' via SSE at \(self.url.absoluteString)")

        do {
            try await transport.start()

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

            logger.info("MCP server '\(self.serverName)' initialized")

            // Send initialized notification
            try await transport.notify(method: "notifications/initialized", params: nil)

            status = .ready
            logger.info("MCP server '\(self.serverName)' is ready")

            // Pre-fetch tools
            tools = try await listTools()
        } catch {
            status = .error(error.localizedDescription)
            logger.error("Failed to connect to SSE MCP server '\(self.serverName)': \(error)")
            throw error
        }
    }

    func disconnect() {
        Task {
            await transport.stop()
        }
        status = .disconnected
        tools = []
        logger.info("Disconnected from SSE MCP server '\(self.serverName)'")
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
