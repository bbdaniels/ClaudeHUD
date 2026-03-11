import Foundation
import os

private let logger = Logger(subsystem: "com.claudehud", category: "Conversation")

// MARK: - UI Models

struct ChatMessage: Identifiable {
    let id = UUID()
    let role: MessageRole
    var content: String
    let timestamp = Date()
    var toolCalls: [ToolCallInfo] = []

    enum MessageRole {
        case user, assistant, system
    }
}

struct ToolCallInfo: Identifiable {
    let id = UUID()
    let toolName: String
    let arguments: String
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
    @Published var selectedModel: String = "opus"
    @Published var permissionMode: String = "dangerously-skip"
    @Published var costUSD: Double = 0

    let cliClient: ClaudeCLIClient

    private let systemPrompt = """
        You are ClaudeHUD, a macOS command center. You can read files, search code, \
        browse the web, and use MCP tools freely. You CANNOT edit files directly — \
        Edit, Write, and NotebookEdit are disabled.

        When the user wants code changes:
        1. Read the relevant files and plan the changes.
        2. Describe the changes clearly.
        3. Offer to open the file in their editor. Use Bash to run:
           - VS Code: code --goto "path/to/file:line"
           - Ghostty/terminal: open -a Ghostty
        4. Ask the user which editor they prefer if you don't know yet. Remember it.

        Session history: All past Claude Code sessions are stored as JSONL files under \
        ~/.claude/projects/. Each project folder is named by its path (dashes for slashes), \
        and contains .jsonl files per session. Each line is a JSON object with fields like \
        type (user/assistant), message.content, timestamp, cwd, gitBranch. You can use \
        Glob and Grep to search across sessions, and Read to inspect specific ones. \
        Use this to help the user find past conversations, decisions, and code changes.

        Keep responses concise — the user is reading in a compact floating panel.
        """

    init(cliClient: ClaudeCLIClient) {
        self.cliClient = cliClient
    }

    // MARK: - Public API

    func send(_ text: String) async {
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }

        isProcessing = true
        defer { isProcessing = false }

        // Add user message to UI
        messages.append(ChatMessage(role: .user, content: text))

        // Track the assistant message we're building up from stream events
        var assistantText = ""
        var pendingToolCalls: [ToolCallInfo] = []
        var assistantMessageIndex: Int?

        do {
            let result = try await cliClient.send(
                message: text,
                model: selectedModel,
                permissionMode: permissionMode,
                systemPrompt: systemPrompt
            ) { [weak self] event in
                guard let self else { return }

                switch event {
                case .system(let sys):
                    logger.info("Session: \(sys.sessionId), MCP servers: \(sys.mcpServers.count)")

                case .assistant(let msg):
                    if let text = msg.text {
                        assistantText = text

                        // Create or update the assistant message
                        if let idx = assistantMessageIndex {
                            self.messages[idx].content = assistantText
                        } else {
                            self.messages.append(ChatMessage(role: .assistant, content: assistantText))
                            assistantMessageIndex = self.messages.count - 1
                        }
                    }

                case .toolUse(let tool):
                    let info = ToolCallInfo(
                        toolName: tool.toolName,
                        arguments: tool.input
                    )
                    pendingToolCalls.append(info)

                    // Ensure we have an assistant message to attach tool calls to
                    if let idx = assistantMessageIndex {
                        self.messages[idx].toolCalls.append(info)
                    } else {
                        var msg = ChatMessage(role: .assistant, content: "")
                        msg.toolCalls.append(info)
                        self.messages.append(msg)
                        assistantMessageIndex = self.messages.count - 1
                    }

                case .toolResult(let toolResult):
                    // Update the matching tool call with its result
                    if let msgIdx = assistantMessageIndex {
                        if let tcIdx = self.messages[msgIdx].toolCalls.lastIndex(where: { $0.toolName != "" && !$0.isComplete }) {
                            self.messages[msgIdx].toolCalls[tcIdx].result = toolResult.content
                            self.messages[msgIdx].toolCalls[tcIdx].isComplete = true
                        }
                    }

                case .result:
                    break // handled below

                case .unknown:
                    break
                }
            }

            // Update totals from the final result
            totalTokens += result.inputTokens + result.outputTokens
            costUSD += result.costUSD

            // If the final result text differs from what we streamed, update
            if let idx = assistantMessageIndex, !result.result.isEmpty {
                messages[idx].content = result.result
            } else if assistantMessageIndex == nil && !result.result.isEmpty {
                messages.append(ChatMessage(role: .assistant, content: result.result))
            }

            if result.isError {
                messages.append(ChatMessage(role: .system, content: "Error: \(result.result)"))
            }

        } catch {
            logger.error("Send failed: \(error.localizedDescription)")
            messages.append(ChatMessage(role: .system, content: "Error: \(error.localizedDescription)"))
        }
    }

    func newConversation() {
        messages = []
        totalTokens = 0
        costUSD = 0
        cliClient.newSession()
    }

    func cancel() {
        cliClient.cancel()
        isProcessing = false
    }

    var costString: String {
        if costUSD >= 0.01 {
            return String(format: "$%.2f", costUSD)
        } else if costUSD > 0 {
            return String(format: "$%.3f", costUSD)
        }
        return ""
    }
}
