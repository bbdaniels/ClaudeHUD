import Foundation
import os

private let logger = Logger(subsystem: "com.claudehud", category: "ClaudeCLI")

// MARK: - Stream Event Types

/// Events emitted by `claude -p --output-format stream-json --verbose`
enum CLIStreamEvent {
    case system(CLISystemEvent)
    case assistant(CLIAssistantEvent)
    case toolUse(CLIToolUseEvent)
    case toolResult(CLIToolResultEvent)
    case result(CLIResultEvent)
    case unknown(String)
}

struct CLISystemEvent {
    let sessionId: String
    let tools: [String]
    let mcpServers: [CLIMCPServerStatus]
    let model: String
}

struct CLIMCPServerStatus {
    let name: String
    let status: String  // "connected", "failed", "needs-auth"
}

struct CLIAssistantEvent {
    let text: String?
    let isThinking: Bool
}

struct CLIToolUseEvent {
    let toolName: String
    let toolId: String
    let input: String  // JSON string of arguments
}

struct CLIToolResultEvent {
    let toolId: String
    let content: String
}

struct CLIResultEvent {
    let sessionId: String
    let result: String
    let isError: Bool
    let durationMs: Int
    let costUSD: Double
    let inputTokens: Int
    let outputTokens: Int
    let stopReason: String?
}

// MARK: - CLI Client

@MainActor
class ClaudeCLIClient: ObservableObject {
    @Published var isProcessing = false
    @Published var currentSessionId: String?
    @Published var mcpServers: [CLIMCPServerStatus] = []

    private var currentProcess: Process?

    /// Path to the claude CLI
    private var claudePath: String {
        // Check common locations
        let paths = [
            "\(NSHomeDirectory())/.local/bin/claude",
            "/usr/local/bin/claude",
            "/opt/homebrew/bin/claude",
            "\(NSHomeDirectory())/.npm-global/bin/claude",
            "\(NSHomeDirectory())/.claude/local/claude"
        ]
        for path in paths {
            if FileManager.default.isExecutableFile(atPath: path) {
                return path
            }
        }
        // Fall back to PATH lookup
        return "claude"
    }

    /// Send a message and stream back events via the callback.
    /// Returns the final CLIResultEvent when complete.
    func send(
        message: String,
        model: String = "sonnet",
        permissionMode: String = "dangerously-skip",
        systemPrompt: String? = nil,
        sessionId: String? = nil,
        onEvent: @escaping (CLIStreamEvent) -> Void
    ) async throws -> CLIResultEvent {
        isProcessing = true
        defer { isProcessing = false }

        // HUD cannot display interactive permission dialogs (non-interactive subprocess),
        // so we always use dangerously-skip-permissions and control safety via disallowed tools.
        //   Plan:   read-only, no file edits or commands
        //   Safe:   file edits allowed, Bash blocked
        //   Unsafe: everything allowed
        var disallowedTools: [String] = []
        switch permissionMode {
        case "plan":
            disallowedTools = ["Edit", "Write", "NotebookEdit", "Bash"]
        case "default":
            disallowedTools = ["Bash"]
        case "dangerously-skip":
            break // allow everything
        default:
            disallowedTools = ["Edit", "Write", "NotebookEdit", "Bash"]
        }

        var args = [
            "-p",
            "--output-format", "stream-json",
            "--verbose",
            "--model", model,
            "--dangerously-skip-permissions",
        ]

        if !disallowedTools.isEmpty {
            args += ["--disallowed-tools", disallowedTools.joined(separator: ",")]
        }

        if let systemPrompt {
            args += ["--append-system-prompt", systemPrompt]
        }

        // Resume previous session for multi-turn
        let resumeId = sessionId ?? currentSessionId
        if let resumeId {
            args += ["--resume", resumeId]
        }

        args.append(message)

        // Use script(1) to force line-buffered output via a PTY,
        // otherwise pipe buffering delays streaming until process exits.
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/script")
        process.arguments = ["-q", "/dev/null", claudePath] + args
        process.currentDirectoryURL = URL(fileURLWithPath: NSHomeDirectory())

        // Must unset CLAUDECODE to avoid nested session detection
        var env = ProcessInfo.processInfo.environment
        env.removeValue(forKey: "CLAUDECODE")
        process.environment = env

        let stdout = Pipe()
        let stderr = Pipe()
        process.standardOutput = stdout
        process.standardError = stderr

        currentProcess = process

        return try await withCheckedThrowingContinuation { continuation in
            var finalResult: CLIResultEvent?
            var errorOutput = ""

            // Read stderr for error messages
            stderr.fileHandleForReading.readabilityHandler = { handle in
                let data = handle.availableData
                if !data.isEmpty, let str = String(data: data, encoding: .utf8) {
                    errorOutput += str
                    logger.warning("CLI stderr: \(str)")
                }
            }

            // Read stdout line by line for stream events
            let stdoutHandle = stdout.fileHandleForReading
            var buffer = Data()

            stdoutHandle.readabilityHandler = { [weak self] handle in
                let data = handle.availableData
                guard !data.isEmpty else { return }
                buffer.append(data)

                // Process complete lines
                while let newlineRange = buffer.range(of: Data([0x0A])) {
                    let lineData = buffer.subdata(in: buffer.startIndex..<newlineRange.lowerBound)
                    buffer.removeSubrange(buffer.startIndex...newlineRange.lowerBound)

                    guard var line = String(data: lineData, encoding: .utf8),
                          !line.trimmingCharacters(in: .whitespaces).isEmpty else { continue }

                    // Strip carriage returns injected by script(1) PTY
                    line = line.replacingOccurrences(of: "\r", with: "")
                    // Strip ANSI escape sequences (e.g. cursor/color codes from PTY)
                    if let ansiRegex = try? NSRegularExpression(pattern: "\u{1B}\\[[0-9;]*[A-Za-z]") {
                        let range = NSRange(line.startIndex..., in: line)
                        line = ansiRegex.stringByReplacingMatches(in: line, range: range, withTemplate: "")
                    }

                    let event = Self.parseStreamEvent(line)

                    // Capture session ID and MCP status from system init
                    if case .system(let sysEvent) = event {
                        Task { @MainActor in
                            self?.currentSessionId = sysEvent.sessionId
                            self?.mcpServers = sysEvent.mcpServers
                        }
                    }

                    // Capture final result
                    if case .result(let resultEvent) = event {
                        finalResult = resultEvent
                        Task { @MainActor in
                            self?.currentSessionId = resultEvent.sessionId
                        }
                    }

                    Task { @MainActor in
                        onEvent(event)
                    }
                }
            }

            process.terminationHandler = { proc in
                stdoutHandle.readabilityHandler = nil
                stderr.fileHandleForReading.readabilityHandler = nil

                Task { @MainActor in
                    self.currentProcess = nil
                }

                if proc.terminationStatus == 0, let result = finalResult {
                    continuation.resume(returning: result)
                } else if let result = finalResult, result.isError {
                    continuation.resume(returning: result)
                } else {
                    let msg = errorOutput.isEmpty ? "CLI exited with code \(proc.terminationStatus)" : errorOutput
                    continuation.resume(throwing: CLIError.processError(msg))
                }
            }

            do {
                try process.run()
                logger.info("Launched claude CLI with args: \(args.joined(separator: " "))")
            } catch {
                continuation.resume(throwing: CLIError.launchFailed(error.localizedDescription))
            }
        }
    }

    /// Quick one-shot query (no session, no streaming). Used for lightweight tasks like title generation.
    func quickQuery(_ prompt: String, model: String = "haiku") async throws -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: claudePath)
        process.arguments = [
            "-p",
            "--output-format", "text",
            "--model", model,
            "--dangerously-skip-permissions",
            prompt
        ]
        process.currentDirectoryURL = URL(fileURLWithPath: NSHomeDirectory())

        var env = ProcessInfo.processInfo.environment
        env.removeValue(forKey: "CLAUDECODE")
        process.environment = env

        let stdout = Pipe()
        process.standardOutput = stdout
        process.standardError = Pipe() // discard

        try process.run()

        return await withCheckedContinuation { continuation in
            process.terminationHandler = { _ in
                let data = stdout.fileHandleForReading.readDataToEndOfFile()
                let result = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                continuation.resume(returning: result)
            }
        }
    }

    func cancel() {
        currentProcess?.terminate()
        currentProcess = nil
        isProcessing = false
    }

    func newSession() {
        currentSessionId = nil
    }

    // MARK: - Stream Parsing

    nonisolated private static func parseStreamEvent(_ line: String) -> CLIStreamEvent {
        guard let data = line.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let type = json["type"] as? String else {
            return .unknown(line)
        }

        switch type {
        case "system":
            return .system(parseSystemEvent(json))
        case "assistant":
            return .assistant(parseAssistantEvent(json))
        case "tool_use":
            return .toolUse(parseToolUseEvent(json))
        case "tool_result":
            return .toolResult(parseToolResultEvent(json))
        case "result":
            return .result(parseResultEvent(json))
        default:
            return .unknown(line)
        }
    }

    nonisolated private static func parseSystemEvent(_ json: [String: Any]) -> CLISystemEvent {
        let tools = json["tools"] as? [String] ?? []
        let mcpRaw = json["mcp_servers"] as? [[String: Any]] ?? []
        let servers = mcpRaw.map {
            CLIMCPServerStatus(
                name: $0["name"] as? String ?? "unknown",
                status: $0["status"] as? String ?? "unknown"
            )
        }
        return CLISystemEvent(
            sessionId: json["session_id"] as? String ?? "",
            tools: tools,
            mcpServers: servers,
            model: json["model"] as? String ?? ""
        )
    }

    nonisolated private static func parseAssistantEvent(_ json: [String: Any]) -> CLIAssistantEvent {
        // The message contains content blocks
        guard let message = json["message"] as? [String: Any],
              let content = message["content"] as? [[String: Any]] else {
            return CLIAssistantEvent(text: nil, isThinking: false)
        }

        // Find the latest text or thinking block
        for block in content.reversed() {
            if let blockType = block["type"] as? String {
                if blockType == "text", let text = block["text"] as? String {
                    return CLIAssistantEvent(text: text, isThinking: false)
                }
                if blockType == "thinking" {
                    return CLIAssistantEvent(text: nil, isThinking: true)
                }
            }
        }

        return CLIAssistantEvent(text: nil, isThinking: false)
    }

    nonisolated private static func parseToolUseEvent(_ json: [String: Any]) -> CLIToolUseEvent {
        let tool = json["tool"] as? String ?? ""
        let toolId = json["tool_use_id"] as? String ?? ""
        var inputStr = "{}"
        if let input = json["input"] {
            if let data = try? JSONSerialization.data(withJSONObject: input, options: .prettyPrinted),
               let str = String(data: data, encoding: .utf8) {
                inputStr = str
            }
        }
        return CLIToolUseEvent(toolName: tool, toolId: toolId, input: inputStr)
    }

    nonisolated private static func parseToolResultEvent(_ json: [String: Any]) -> CLIToolResultEvent {
        return CLIToolResultEvent(
            toolId: json["tool_use_id"] as? String ?? "",
            content: json["content"] as? String ?? ""
        )
    }

    nonisolated private static func parseResultEvent(_ json: [String: Any]) -> CLIResultEvent {
        let usage = json["usage"] as? [String: Any] ?? [:]
        return CLIResultEvent(
            sessionId: json["session_id"] as? String ?? "",
            result: json["result"] as? String ?? "",
            isError: json["is_error"] as? Bool ?? false,
            durationMs: json["duration_ms"] as? Int ?? 0,
            costUSD: json["total_cost_usd"] as? Double ?? 0,
            inputTokens: usage["input_tokens"] as? Int ?? 0,
            outputTokens: usage["output_tokens"] as? Int ?? 0,
            stopReason: json["stop_reason"] as? String
        )
    }
}

// MARK: - Errors

enum CLIError: LocalizedError {
    case launchFailed(String)
    case processError(String)
    case notInstalled

    var errorDescription: String? {
        switch self {
        case .launchFailed(let msg): return "Failed to launch claude CLI: \(msg)"
        case .processError(let msg): return "CLI error: \(msg)"
        case .notInstalled: return "claude CLI not found. Install it from https://claude.ai/download"
        }
    }
}
