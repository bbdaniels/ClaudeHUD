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
    let subtype: String       // "init", etc.
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
    /// Plain-text summary carried by a `thinking` content block. Kept separate
    /// from `text` so a consumer that renders `text` as the answer never leaks
    /// reasoning into the final reply. `redacted_thinking` blocks are dropped
    /// entirely and never reach a consumer.
    let thinkingText: String?
    /// Subagent attribution: the `tool_use_id` of the parent Task, when this
    /// assistant message was produced inside a spawned subagent.
    let parentToolUseId: String?

    init(text: String?, isThinking: Bool, thinkingText: String? = nil, parentToolUseId: String? = nil) {
        self.text = text
        self.isThinking = isThinking
        self.thinkingText = thinkingText
        self.parentToolUseId = parentToolUseId
    }
}

struct CLIToolUseEvent {
    let toolName: String
    let toolId: String
    let input: String  // JSON string of arguments
    /// Non-nil when this tool call was issued by a subagent (its parent Task's id).
    let parentToolUseId: String?

    init(toolName: String, toolId: String, input: String, parentToolUseId: String? = nil) {
        self.toolName = toolName
        self.toolId = toolId
        self.input = input
        self.parentToolUseId = parentToolUseId
    }
}

struct CLIToolResultEvent {
    let toolId: String       // matches the originating tool_use id
    let content: String
    let isError: Bool
    /// Non-nil when this result belongs to a subagent's tool call.
    let parentToolUseId: String?

    init(toolId: String, content: String, isError: Bool = false, parentToolUseId: String? = nil) {
        self.toolId = toolId
        self.content = content
        self.isError = isError
        self.parentToolUseId = parentToolUseId
    }
}

struct CLIResultEvent {
    let sessionId: String
    let result: String
    let isError: Bool
    /// "success", or an error subtype: error_max_turns, error_during_execution,
    /// error_max_budget_usd (budget cap), etc. Drives the terminal-state copy.
    let subtype: String?
    let durationMs: Int
    let costUSD: Double
    let inputTokens: Int
    let outputTokens: Int
    let numTurns: Int
    let stopReason: String?
    /// Count of tool calls denied by the permission layer this turn.
    let permissionDenials: Int
    /// True when the turn ended because the operator hit Stop (synthesized,
    /// never present in CLI JSON). Lets the lifecycle render Stopped-by-you
    /// distinct from Failed. Phase 1 wires the synthesis path.
    let interrupted: Bool

    init(sessionId: String, result: String, isError: Bool, subtype: String? = nil,
         durationMs: Int = 0, costUSD: Double = 0, inputTokens: Int = 0,
         outputTokens: Int = 0, numTurns: Int = 0, stopReason: String? = nil,
         permissionDenials: Int = 0, interrupted: Bool = false) {
        self.sessionId = sessionId
        self.result = result
        self.isError = isError
        self.subtype = subtype
        self.durationMs = durationMs
        self.costUSD = costUSD
        self.inputTokens = inputTokens
        self.outputTokens = outputTokens
        self.numTurns = numTurns
        self.stopReason = stopReason
        self.permissionDenials = permissionDenials
        self.interrupted = interrupted
    }
}

// MARK: - Cancel signalling

/// A tiny thread-safe boolean shared between the MainActor `cancel()` call and
/// the `Process` termination handler (which fires on an arbitrary background
/// thread). When the operator taps Stop we set this; the termination handler
/// reads it to decide whether a non-zero exit is a deliberate Stop (synthesize
/// an `interrupted` result + keep partial work) or a genuine Failure (throw).
final class CancelFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var value = false
    var isSet: Bool {
        get { lock.lock(); defer { lock.unlock() }; return value }
        set { lock.lock(); defer { lock.unlock() }; value = newValue }
    }
}

// MARK: - CLI Client

@MainActor
class ClaudeCLIClient: ObservableObject {
    @Published var isProcessing = false
    @Published var currentSessionId: String?
    @Published var mcpServers: [CLIMCPServerStatus] = []

    private var currentProcess: Process?

    /// The OS pid of the live turn's root process (the `script(1)` wrapper).
    /// Exposed so the Slack durable in-flight registry (1.6) can persist it and
    /// check liveness after an app crash. Nil when no turn is running.
    private(set) var currentPid: Int32?

    /// The process GROUP id to signal on Stop, set only when the child was
    /// successfully placed in its own group (so `killpg` can never hit the app's
    /// own group). Nil ⇒ fall back to a plain `terminate()` of the parent pid.
    private(set) var currentPgid: Int32?

    /// Shared Stop flag for the live turn. Set by `cancel()`, read by the
    /// termination handler to render Stopped-by-you rather than Failed (1.4).
    private var activeCancelFlag: CancelFlag?

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
    /// Valid `--effort` levels the CLI accepts (2.3). An out-of-set value is
    /// dropped so the flag never fails a turn (the CLI also warns+defaults, but
    /// we guard here to avoid passing junk through the argv array at all).
    static let effortLevels: Set<String> = ["low", "medium", "high", "xhigh", "max"]

    func send(
        message: String,
        model: String = "sonnet",
        permissionMode: String = "dangerously-skip",
        effort: String = "medium",
        systemPrompt: String? = nil,
        sessionId: String? = nil,
        workingDirectory: String? = nil,
        supervisedMcpConfig: String? = nil,
        maxTurns: Int? = nil,
        onSpawn: (@MainActor (Int32, Int32?) -> Void)? = nil,
        onEvent: @escaping (CLIStreamEvent) -> Void
    ) async throws -> CLIResultEvent {
        isProcessing = true
        defer { isProcessing = false }

        // SUPERVISED MODE (Phase 3): when a mcp-config path is supplied, drop
        // --dangerously-skip-permissions and route every gated tool through the
        // bundled MCP server's permission-prompt-tool + risk policy. The MCP server
        // auto-approves reads/in-repo edits as fast local returns, hard-denies the
        // floor, and parks the consequential on Slack. `permissionMode` becomes the
        // CEILING (plan → real plan mode), not a blanket disallowed-tools list.
        let supervised = supervisedMcpConfig != nil

        // LEGACY (non-supervised) path: HUD cannot display interactive permission
        // dialogs, so it uses dangerously-skip and emulates modes via disallowed
        // tools. Preserved for the chat tab and any caller without an mcp-config.
        var disallowedTools: [String] = []
        if !supervised {
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
        }

        var args = [
            "-p",
            "--output-format", "stream-json",
            "--verbose",
            "--model", model,
        ]

        if supervised, let cfg = supervisedMcpConfig {
            // The supervisory seam: gate via the MCP tool instead of skipping.
            args += [
                "--mcp-config", cfg,
                "--permission-prompt-tool", "mcp__hud__approve",
                // Let the model call the question tool without it being gated.
                "--allowed-tools", "mcp__hud__ask_human",
            ]
            // permissionMode is the ceiling: plan → real plan mode (model plans and
            // calls ExitPlanMode, which the approve handler gates); otherwise default
            // (the prompt tool gates consequential actions).
            args += ["--permission-mode", permissionMode == "plan" ? "plan" : "default"]
        } else {
            args.append("--dangerously-skip-permissions")
        }

        // Reasoning-effort dial (2.3): the per-channel level the operator set,
        // passed straight to the engine. Only a known level is forwarded.
        if Self.effortLevels.contains(effort) {
            args += ["--effort", effort]
        }

        if !disallowedTools.isEmpty {
            args += ["--disallowed-tools", disallowedTools.joined(separator: ",")]
        }

        // Turn guardrail (3.5, ON by default, NO dollars): cap the number of
        // agentic turns the engine will take before it stops and returns a
        // `result` with `subtype == "error_max_turns"`. The Slack layer maps that
        // subtype to a Continue/Stop decision card rather than a silent Failure —
        // the cost equivalent of "never orphan a spinner" for a walk-away turn.
        if let maxTurns, maxTurns > 0 {
            args += ["--max-turns", String(maxTurns)]
        }

        if let systemPrompt {
            args += ["--append-system-prompt", systemPrompt]
        }

        // Resume previous session for multi-turn
        let resumeId = sessionId ?? currentSessionId
        if let resumeId {
            args += ["--resume", resumeId]
        }

        // Terminate option parsing before the prompt: the variadic
        // --disallowed-tools otherwise swallows the message as a tool name
        // on fresh turns (no --resume in between), failing with exit 1.
        args.append("--")
        args.append(message)

        // Use script(1) to force line-buffered output via a PTY,
        // otherwise pipe buffering delays streaming until process exits.
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/script")
        process.arguments = ["-q", "/dev/null", claudePath] + args
        process.currentDirectoryURL = URL(fileURLWithPath: workingDirectory ?? NSHomeDirectory())

        // Must unset CLAUDECODE to avoid nested session detection
        var env = ProcessInfo.processInfo.environment
        env.removeValue(forKey: "CLAUDECODE")
        process.environment = env

        let stdout = Pipe()
        let stderr = Pipe()
        process.standardOutput = stdout
        process.standardError = stderr

        currentProcess = process
        let cancelFlag = CancelFlag()
        activeCancelFlag = cancelFlag
        let startedAt = Date()

        return try await withCheckedThrowingContinuation { continuation in
            var finalResult: CLIResultEvent?
            var errorOutput = ""
            // The most recent session id seen on the stream (from the `system`
            // init or `result` event). Captured so a Stop can synthesize a
            // result that still carries the resumable session id (1.4).
            var sessionIdSeen = sessionId ?? ""

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

                    // A single JSON line (an `assistant`/`user` message) can carry
                    // several content blocks, so the parser fans out into one
                    // event per block. Emit them all, in order.
                    let events = Self.parseStreamEvents(line)

                    for event in events {
                        // Capture session ID and MCP status from system init
                        if case .system(let sysEvent) = event {
                            if !sysEvent.sessionId.isEmpty { sessionIdSeen = sysEvent.sessionId }
                            SlackFileLog.log("cli init: session=\(sysEvent.sessionId.prefix(8)) model=\(sysEvent.model) tools=\(sysEvent.tools.count) mcp=\(sysEvent.mcpServers.count)")
                            Task { @MainActor in
                                if !sysEvent.sessionId.isEmpty { self?.currentSessionId = sysEvent.sessionId }
                                if !sysEvent.mcpServers.isEmpty { self?.mcpServers = sysEvent.mcpServers }
                            }
                        }

                        // Capture final result
                        if case .result(let resultEvent) = event {
                            finalResult = resultEvent
                            if !resultEvent.sessionId.isEmpty { sessionIdSeen = resultEvent.sessionId }
                            SlackFileLog.log("cli result: subtype=\(resultEvent.subtype ?? "nil") isError=\(resultEvent.isError) turns=\(resultEvent.numTurns) denials=\(resultEvent.permissionDenials) cost=\(resultEvent.costUSD)")
                            if !resultEvent.sessionId.isEmpty {
                                Task { @MainActor in
                                    self?.currentSessionId = resultEvent.sessionId
                                }
                            }
                        }

                        Task { @MainActor in
                            onEvent(event)
                        }
                    }
                }
            }

            process.terminationHandler = { proc in
                stdoutHandle.readabilityHandler = nil
                stderr.fileHandleForReading.readabilityHandler = nil

                Task { @MainActor in
                    self.currentProcess = nil
                    self.currentPid = nil
                    self.currentPgid = nil
                    self.activeCancelFlag = nil
                }

                // OPERATOR STOP (1.4): a user-triggered kill is the one "error"
                // we suppress. Synthesize an `interrupted` result so the turn
                // resolves to Stopped-by-you with whatever partial assistant text
                // and tool calls the stream already delivered — never a Failure.
                if cancelFlag.isSet {
                    let synth = CLIResultEvent(
                        sessionId: sessionIdSeen,
                        result: finalResult?.result ?? "",
                        isError: false,
                        subtype: "interrupted",
                        durationMs: Int(Date().timeIntervalSince(startedAt) * 1000),
                        interrupted: true
                    )
                    SlackFileLog.log("cli stopped by user: session=\(sessionIdSeen.prefix(8)) exit=\(proc.terminationStatus)")
                    continuation.resume(returning: synth)
                    return
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

                // Place the child in its OWN process group so Stop can signal the
                // whole tree (script + claude + any subagents) without ever
                // touching the app's own group (E3 — subagents must not survive a
                // parent kill and keep editing/billing). Parent-side `setpgid`
                // races the child's exec; calling it immediately after run()
                // wins in practice. We only arm `killpg` when the resulting group
                // is verifiably distinct from our own — otherwise fall back to a
                // plain parent `terminate()`.
                let pid = process.processIdentifier
                self.currentPid = pid
                _ = setpgid(pid, pid)
                let childGroup = getpgid(pid)
                let ownGroup = getpgid(0)
                if childGroup > 0, childGroup != ownGroup {
                    self.currentPgid = childGroup
                    SlackFileLog.log("cli spawn: pid=\(pid) pgid=\(childGroup) (own group)")
                } else {
                    self.currentPgid = nil
                    SlackFileLog.log("cli spawn: pid=\(pid) pgid unavailable; will terminate() on stop")
                }
                onSpawn?(pid, self.currentPgid)
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

    /// Operator Stop (1.4): kill the whole turn and keep partial work. Flags the
    /// shared cancel box (so the termination handler synthesizes an `interrupted`
    /// result rather than throwing), then SIGTERMs the child's process GROUP so
    /// any subagents die with it. Escalates to SIGKILL after a short grace window
    /// if the group does not exit (SIGTERM first lets Claude flush its JSONL so
    /// the session stays resumable). Does NOT nil `currentProcess` — the
    /// termination handler does that once the kernel reaps the process.
    func cancel() {
        activeCancelFlag?.isSet = true
        guard let process = currentProcess, let pid = currentPid else {
            currentProcess?.terminate()
            isProcessing = false
            return
        }
        // Re-resolve the group at kill time: `script(1)`/`claude` may have
        // `setsid`'d into a new group after spawn, leaving the stored pgid stale.
        // Prefer the live group, fall back to the one recorded at spawn. Never
        // signal the app's own group.
        let ownGroup = getpgid(0)
        let livePgid = getpgid(pid)
        let pgid: Int32? = (livePgid > 0 && livePgid != ownGroup) ? livePgid : currentPgid
        if let pgid, pgid > 0, pgid != ownGroup {
            currentPgid = pgid
            SlackFileLog.log("stop: killpg(SIGTERM) pgid=\(pgid)")
            killpg(pgid, SIGTERM)
            // Escalate if the group is still alive after the grace window.
            Task { [weak self] in
                try? await Task.sleep(nanoseconds: 2_500_000_000)
                self?.escalateKill(pgid: pgid)
            }
        } else {
            SlackFileLog.log("stop: terminate() (no isolated group)")
            process.terminate()
        }
    }

    /// SIGKILL the process group only if the turn has not already been reaped
    /// (the termination handler nils `currentProcess` on exit). Guards against a
    /// needless signal — and, since we only ever escalate a `pgid` we ourselves
    /// created and are still tracking, never a reused/foreign group.
    private func escalateKill(pgid: Int32) {
        guard currentProcess != nil, currentPgid == pgid else {
            SlackFileLog.log("stop: group exited within grace; no SIGKILL needed")
            return
        }
        SlackFileLog.log("stop: group survived grace; killpg(SIGKILL) pgid=\(pgid)")
        killpg(pgid, SIGKILL)
    }

    func newSession() {
        currentSessionId = nil
    }

    // MARK: - Stream Parsing

    /// Parse one newline-delimited `stream-json` line into zero or more events.
    ///
    /// The CLI never emits top-level `tool_use`/`tool_result` types: tool calls
    /// arrive as content blocks inside an `assistant` message, and tool results
    /// inside a `user` message. A single message line therefore fans out into
    /// one event per content block (text, thinking, tool_use, tool_result),
    /// preserving order. `redacted_thinking` blocks are dropped. A top-level
    /// `error` event is mapped to a failed result so the turn resolves rather
    /// than hanging silently.
    nonisolated static func parseStreamEvents(_ line: String) -> [CLIStreamEvent] {
        guard let data = line.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let type = json["type"] as? String else {
            return [.unknown(line)]
        }

        switch type {
        case "system":
            return [.system(parseSystemEvent(json))]
        case "assistant":
            return parseAssistantBlocks(json)
        case "user":
            return parseUserBlocks(json)
        case "result":
            return [.result(parseResultEvent(json))]
        case "error":
            // Top-level error envelope (e.g. mid-stream API failure). Resolve to
            // a failed result so the turn ends in a clear Failed, not silence.
            return [.result(parseTopLevelError(json))]
        default:
            return [.unknown(line)]
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
            subtype: json["subtype"] as? String ?? "",
            tools: tools,
            mcpServers: servers,
            model: json["model"] as? String ?? ""
        )
    }

    /// Fan an `assistant` message into one event per content block, in order.
    nonisolated private static func parseAssistantBlocks(_ json: [String: Any]) -> [CLIStreamEvent] {
        // Subagent attribution rides on the message envelope, not the block.
        let parentId = json["parent_tool_use_id"] as? String
        guard let message = json["message"] as? [String: Any],
              let content = message["content"] as? [[String: Any]] else {
            return []
        }

        var events: [CLIStreamEvent] = []
        for block in content {
            guard let blockType = block["type"] as? String else { continue }
            switch blockType {
            case "text":
                if let text = block["text"] as? String, !text.isEmpty {
                    events.append(.assistant(CLIAssistantEvent(
                        text: text, isThinking: false, parentToolUseId: parentId)))
                }
            case "thinking":
                // Pass the reasoning summary through on a dedicated field so it
                // is never mistaken for the answer text.
                let thinking = block["thinking"] as? String
                events.append(.assistant(CLIAssistantEvent(
                    text: nil, isThinking: true, thinkingText: thinking, parentToolUseId: parentId)))
            case "redacted_thinking":
                // Encrypted reasoning: never render. Drop it.
                continue
            case "tool_use":
                let name = block["name"] as? String ?? ""
                let id = block["id"] as? String ?? ""
                events.append(.toolUse(CLIToolUseEvent(
                    toolName: name, toolId: id,
                    input: stringifyJSON(block["input"]),
                    parentToolUseId: parentId)))
            default:
                continue
            }
        }
        return events
    }

    /// Fan a `user` message into tool_result events (one per result block).
    nonisolated private static func parseUserBlocks(_ json: [String: Any]) -> [CLIStreamEvent] {
        let parentId = json["parent_tool_use_id"] as? String
        guard let message = json["message"] as? [String: Any] else { return [] }

        // `content` may be a string (rare) or an array of blocks.
        guard let content = message["content"] as? [[String: Any]] else { return [] }

        var events: [CLIStreamEvent] = []
        for block in content {
            guard let blockType = block["type"] as? String, blockType == "tool_result" else { continue }
            events.append(.toolResult(CLIToolResultEvent(
                toolId: block["tool_use_id"] as? String ?? "",
                content: stringifyToolResultContent(block["content"]),
                isError: block["is_error"] as? Bool ?? false,
                parentToolUseId: parentId)))
        }
        return events
    }

    nonisolated private static func parseResultEvent(_ json: [String: Any]) -> CLIResultEvent {
        let usage = json["usage"] as? [String: Any] ?? [:]
        let denials = (json["permission_denials"] as? [[String: Any]])?.count ?? 0
        let subtype = json["subtype"] as? String
        // A non-"success" subtype implies an error even when is_error is absent.
        let isError = (json["is_error"] as? Bool) ?? (subtype != nil && subtype != "success")
        return CLIResultEvent(
            sessionId: json["session_id"] as? String ?? "",
            result: json["result"] as? String ?? "",
            isError: isError,
            subtype: subtype,
            durationMs: json["duration_ms"] as? Int ?? 0,
            costUSD: json["total_cost_usd"] as? Double ?? 0,
            inputTokens: usage["input_tokens"] as? Int ?? 0,
            outputTokens: usage["output_tokens"] as? Int ?? 0,
            numTurns: json["num_turns"] as? Int ?? 0,
            stopReason: json["stop_reason"] as? String,
            permissionDenials: denials,
            interrupted: false
        )
    }

    /// Map a top-level `error` envelope onto a failed result event.
    nonisolated private static func parseTopLevelError(_ json: [String: Any]) -> CLIResultEvent {
        let msg: String
        if let m = json["error"] as? String {
            msg = m
        } else if let e = json["error"] as? [String: Any], let m = e["message"] as? String {
            msg = m
        } else if let m = json["message"] as? String {
            msg = m
        } else {
            msg = "stream error"
        }
        return CLIResultEvent(
            sessionId: json["session_id"] as? String ?? "",
            result: msg,
            isError: true,
            subtype: json["subtype"] as? String ?? "error_during_execution"
        )
    }

    // MARK: - Parse helpers

    /// Serialize an arbitrary JSON value (tool input) to a compact string.
    nonisolated private static func stringifyJSON(_ value: Any?) -> String {
        guard let value else { return "{}" }
        if let str = value as? String { return str }
        if let data = try? JSONSerialization.data(withJSONObject: value, options: [.sortedKeys]),
           let str = String(data: data, encoding: .utf8) {
            return str
        }
        return "{}"
    }

    /// A tool_result `content` may be a plain string or an array of content
    /// blocks (`[{type:"text", text:"…"}, …]`). Flatten either to a string.
    nonisolated private static func stringifyToolResultContent(_ value: Any?) -> String {
        if let str = value as? String { return str }
        if let blocks = value as? [[String: Any]] {
            let parts = blocks.compactMap { block -> String? in
                if let t = block["text"] as? String { return t }
                if (block["type"] as? String) == "image" { return "[image]" }
                return nil
            }
            return parts.joined(separator: "\n")
        }
        return stringifyJSON(value)
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
