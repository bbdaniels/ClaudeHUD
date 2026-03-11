import Foundation
import os

private let logger = Logger(subsystem: "com.claudehud", category: "Conversation")

// MARK: - UI Models

struct ChatMessage: Identifiable {
    let id = UUID()
    let role: MessageRole
    let content: String
    let timestamp = Date()
    var toolCalls: [ToolCallInfo] = []

    enum MessageRole {
        case user, assistant, system
    }
}

struct ToolCallInfo: Identifiable {
    let id = UUID()
    let toolName: String
    let arguments: String // JSON string of the tool input
    var result: String?
    var isError: Bool = false
    var isComplete: Bool = false
}

// MARK: - Conversation Manager

@MainActor
class ConversationManager: ObservableObject {
    @Published var messages: [ChatMessage] = []
    @Published var isProcessing = false
    @Published var totalTokens = 0

    /// Full conversation history sent to the API.
    private var conversationHistory: [ClaudeMessage] = []

    private let apiClient: ClaudeAPIClient
    private let serverManager: MCPServerManager

    @Published var selectedModel: String = "claude-sonnet-4-20250514"

    var systemPrompt: String {
        """
        You are ClaudeHUD, a personal assistant running as a macOS menu bar app.
        You have access to MCP tools for various services.
        Keep responses concise -- the user is viewing them in a compact floating panel.
        Use tools proactively when the user's request implies a lookup.
        """
    }

    // MARK: - Init

    init(apiClient: ClaudeAPIClient, serverManager: MCPServerManager) {
        self.apiClient = apiClient
        self.serverManager = serverManager
    }

    // MARK: - Public API

    /// Send a user message and run the full conversation loop (including tool calls).
    func send(_ text: String) async {
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }

        isProcessing = true
        defer { isProcessing = false }

        // 1. Add user message to UI and history
        let userMessage = ChatMessage(role: .user, content: text)
        messages.append(userMessage)
        conversationHistory.append(
            ClaudeMessage(role: "user", content: .text(text))
        )

        // 2. Run the conversation loop
        await conversationLoop()
    }

    /// Clear conversation history and start fresh.
    func newConversation() {
        messages = []
        conversationHistory = []
        totalTokens = 0
    }

    // MARK: - Conversation Loop

    /// Repeatedly call the API until Claude stops requesting tool calls.
    private func conversationLoop() {
        // We use a Task here so we can loop with async/await.
        // The caller already awaits send(), so this runs inline.
        Task { @MainActor in
            var continueLoop = true

            while continueLoop {
                do {
                    let response = try await callAPI()

                    // Accumulate token usage
                    totalTokens += response.usage.inputTokens + response.usage.outputTokens

                    // Parse the response content blocks
                    let (textParts, toolUseParts) = parseResponse(response)

                    // Display assistant text (if any)
                    if !textParts.isEmpty {
                        let combinedText = textParts.joined(separator: "\n")
                        messages.append(
                            ChatMessage(role: .assistant, content: combinedText)
                        )
                    }

                    // Add the assistant's full response to history
                    let assistantBlocks = response.content
                    conversationHistory.append(
                        ClaudeMessage(role: "assistant", content: .blocks(assistantBlocks))
                    )

                    // If there are tool calls, execute them
                    if !toolUseParts.isEmpty {
                        let toolResultBlocks = await executeToolCalls(toolUseParts)

                        // Add tool results to history as a user message
                        conversationHistory.append(
                            ClaudeMessage(role: "user", content: .blocks(toolResultBlocks))
                        )

                        // Continue the loop so Claude can process tool results
                        continueLoop = true
                    } else {
                        // No tool calls -- conversation turn is complete
                        continueLoop = false
                    }

                } catch {
                    logger.error("Conversation loop error: \(error.localizedDescription)")
                    messages.append(
                        ChatMessage(role: .system, content: "Error: \(error.localizedDescription)")
                    )
                    continueLoop = false
                }
            }
        }
    }

    // MARK: - API Call

    private func callAPI() async throws -> ClaudeResponse {
        // Build the tools array from all connected MCP servers
        let tools = buildToolsArray()

        let request = ClaudeRequest(
            model: selectedModel,
            maxTokens: 4096,
            system: systemPrompt,
            tools: tools.isEmpty ? nil : tools,
            messages: conversationHistory
        )

        return try await apiClient.sendMessage(request: request)
    }

    // MARK: - Tool Handling

    /// Convert all MCP tools into the Claude API tool format.
    private func buildToolsArray() -> [ClaudeTool] {
        return serverManager.allTools.map { mcpTool in
            ClaudeTool(
                name: mcpTool.name,
                description: mcpTool.description,
                inputSchema: JSONValue.from(mcpTool.inputSchema)
            )
        }
    }

    /// Extract text and tool_use blocks from a response.
    private func parseResponse(_ response: ClaudeResponse) -> (texts: [String], toolUses: [ToolUseBlock]) {
        var texts: [String] = []
        var toolUses: [ToolUseBlock] = []

        for block in response.content {
            switch block {
            case .text(let textBlock):
                texts.append(textBlock.text)
            case .toolUse(let toolUseBlock):
                toolUses.append(toolUseBlock)
            case .toolResult:
                // Should not appear in assistant responses, but handle gracefully
                break
            }
        }

        return (texts, toolUses)
    }

    /// Execute tool calls and return content blocks with the results.
    private func executeToolCalls(_ toolUses: [ToolUseBlock]) async -> [ContentBlock] {
        var resultBlocks: [ContentBlock] = []

        for toolUse in toolUses {
            // Convert input JSONValue to [String: Any] for the MCP call
            let arguments: [String: Any]
            if case .object(let dict) = toolUse.input {
                arguments = dict.mapValues { $0.toAny() }
            } else {
                arguments = [:]
            }

            // Format arguments as JSON string for UI display
            let argsString: String
            if let data = try? JSONSerialization.data(
                withJSONObject: arguments,
                options: [.prettyPrinted, .sortedKeys]
            ), let s = String(data: data, encoding: .utf8) {
                argsString = s
            } else {
                argsString = "{}"
            }

            // Create a tool call info for the UI
            var toolCallInfo = ToolCallInfo(
                toolName: toolUse.name,
                arguments: argsString
            )

            logger.info("Calling tool: \(toolUse.name)")

            do {
                let result = try await serverManager.callTool(
                    name: toolUse.name,
                    arguments: arguments
                )

                toolCallInfo.result = result.content
                toolCallInfo.isError = result.isError
                toolCallInfo.isComplete = true

                resultBlocks.append(
                    .toolResult(ToolResultBlock(
                        toolUseId: toolUse.id,
                        content: result.content,
                        isError: result.isError ? true : nil
                    ))
                )

                logger.info("Tool \(toolUse.name) completed (error=\(result.isError))")

            } catch {
                let errorMessage = "Tool execution failed: \(error.localizedDescription)"
                toolCallInfo.result = errorMessage
                toolCallInfo.isError = true
                toolCallInfo.isComplete = true

                resultBlocks.append(
                    .toolResult(ToolResultBlock(
                        toolUseId: toolUse.id,
                        content: errorMessage,
                        isError: true
                    ))
                )

                logger.error("Tool \(toolUse.name) failed: \(error.localizedDescription)")
            }

            // Append tool call info to the most recent assistant message in the UI
            if let lastIndex = messages.indices.last,
               messages[lastIndex].role == .assistant {
                messages[lastIndex].toolCalls.append(toolCallInfo)
            } else {
                // If no assistant message yet, create a placeholder
                var msg = ChatMessage(role: .assistant, content: "")
                msg.toolCalls.append(toolCallInfo)
                messages.append(msg)
            }
        }

        return resultBlocks
    }
}
