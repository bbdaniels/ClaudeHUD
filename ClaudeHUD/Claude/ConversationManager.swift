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

// MARK: - Tab Model

enum TabKind: Equatable {
    case chat
    case terminal
}

struct ConversationTab: Identifiable {
    let id = UUID()
    var title: String = "Chat"
    var kind: TabKind = .chat
}

// MARK: - Tab Manager

@MainActor
class TabManager: ObservableObject {
    @Published var tabs: [ConversationTab]
    @Published var selectedTabId: UUID
    @Published var selectedModel: String = UserDefaults.standard.string(forKey: "selectedModel") ?? "opus" {
        didSet { UserDefaults.standard.set(selectedModel, forKey: "selectedModel") }
    }
    @Published var permissionMode: String = UserDefaults.standard.string(forKey: "permissionMode") ?? "plan" {
        didSet { UserDefaults.standard.set(permissionMode, forKey: "permissionMode") }
    }

    private var conversations: [UUID: ConversationManager] = [:]
    private var terminals: [UUID: TerminalSession] = [:]
    private let cliClient: ClaudeCLIClient

    private let systemPrompt = """
        You are ClaudeHUD, a macOS command center. Be proactive — when the user asks \
        you to do something, DO it using your tools. Don't just suggest steps; execute them. \
        Run Bash commands, read files, search code, use MCP tools, and browse the web freely. \
        You CANNOT edit files directly (Edit, Write, NotebookEdit are disabled).

        When the user wants code changes:
        1. Read the relevant files and plan the changes.
        2. Describe the changes clearly.
        3. Offer to open the file in their editor. Use Bash to run:
           - VS Code: code --goto "path/to/file:line"
           - Ghostty/terminal: open -a Ghostty
        4. Ask the user which editor they prefer if you don't know yet. Remember it.

        When the user asks for information you can get via a command (weather, system info, \
        git status, disk usage, network, etc.), just run it. Don't say "I can't" when you \
        have Bash available.

        Session history: All past Claude Code sessions are stored as JSONL files under \
        ~/.claude/projects/. Each project folder is named by its path (dashes for slashes), \
        and contains .jsonl files per session. You can use Glob/Grep/Read to search them.

        Keep responses concise — the user is reading in a compact floating panel. \
        Markdown tables and lists are supported and render well — use them for structured data.
        """

    init(cliClient: ClaudeCLIClient) {
        let firstTab = ConversationTab()
        self.cliClient = cliClient
        self.tabs = [firstTab]
        self.selectedTabId = firstTab.id
        self.conversations[firstTab.id] = ConversationManager(cliClient: cliClient)
    }

    var currentConversation: ConversationManager {
        if let conv = conversations[selectedTabId] {
            return conv
        }
        let conv = ConversationManager(cliClient: cliClient)
        conversations[selectedTabId] = conv
        return conv
    }

    var currentTab: ConversationTab? {
        tabs.first { $0.id == selectedTabId }
    }

    func addTab() {
        let tab = ConversationTab()
        tabs.append(tab)
        conversations[tab.id] = ConversationManager(cliClient: cliClient)
        selectedTabId = tab.id
    }

    /// Adds a terminal tab that runs `command` in `directory`. Surface
    /// creation is deferred until the tab is first rendered, so this is cheap
    /// to call from launcher-style code paths.
    ///
    /// `backgroundColor` is accepted for API symmetry with the external
    /// launcher, but per-surface background tinting is not yet wired in the
    /// embedded path — libghostty's SurfaceConfiguration has no background
    /// field and wrapping the command with an OSC-11 prefix conflicts with
    /// Ghostty's `exec -l` shell wrapping. Colors come from the global
    /// Ghostty config until phase 1.
    @discardableResult
    func addTerminalTab(title: String, command: String?, workingDirectory: String?, backgroundColor: String? = nil) -> UUID {
        _ = backgroundColor
        var tab = ConversationTab(title: title, kind: .terminal)
        tab.title = title
        tabs.append(tab)
        terminals[tab.id] = TerminalSession(
            title: title,
            command: command,
            workingDirectory: workingDirectory
        )
        selectedTabId = tab.id
        return tab.id
    }

    func terminalSession(for id: UUID) -> TerminalSession? {
        terminals[id]
    }

    func closeTab(_ id: UUID) {
        conversations[id]?.cancel()
        conversations.removeValue(forKey: id)
        terminals[id]?.teardown()
        terminals.removeValue(forKey: id)
        tabs.removeAll { $0.id == id }

        // Always keep at least one tab
        if tabs.isEmpty {
            let tab = ConversationTab()
            tabs.append(tab)
            conversations[tab.id] = ConversationManager(cliClient: cliClient)
            selectedTabId = tab.id
        } else if selectedTabId == id {
            selectedTabId = tabs.last!.id
        }
    }

    func send(_ text: String) async {
        let conv = currentConversation
        let isFirstMessage = conv.messages.isEmpty
        let tabId = selectedTabId

        // Set a temporary preview title while waiting for AI-generated one
        if isFirstMessage, let idx = tabs.firstIndex(where: { $0.id == tabId }) {
            let preview = String(text.prefix(20))
            tabs[idx].title = preview + (text.count > 20 ? "..." : "")
        }

        await conv.send(text, model: selectedModel, permissionMode: permissionMode, systemPrompt: systemPrompt)

        // After first exchange completes, generate a smart title in the background
        if isFirstMessage {
            Task {
                await generateTabTitle(for: tabId, from: text)
            }
        }
    }

    private func generateTabTitle(for tabId: UUID, from message: String) async {
        let prompt = "Generate a 2-4 word title for a conversation that starts with this message. Reply with ONLY the title, no quotes, no punctuation:\n\n\(message)"
        do {
            let title = try await cliClient.quickQuery(prompt)
            if !title.isEmpty, let idx = tabs.firstIndex(where: { $0.id == tabId }) {
                tabs[idx].title = String(title.prefix(30))
            }
        } catch {
            // Keep the preview title on failure
        }
    }

    func cancelAll() {
        for conv in conversations.values {
            conv.cancel()
        }
        // Tear down any terminal sessions — the underlying Ghostty.Surface
        // releases the C surface in its deinit, which sends SIGHUP to the PTY
        // child. Drop the tabs too so reopen doesn't show orphan entries.
        for terminal in terminals.values {
            terminal.teardown()
        }
        terminals.removeAll()
        tabs.removeAll { $0.kind == .terminal }

        if tabs.isEmpty {
            let tab = ConversationTab()
            tabs.append(tab)
            conversations[tab.id] = ConversationManager(cliClient: cliClient)
            selectedTabId = tab.id
        } else if !tabs.contains(where: { $0.id == selectedTabId }) {
            selectedTabId = tabs.last!.id
        }
    }
}

// MARK: - Conversation Manager

@MainActor
class ConversationManager: ObservableObject {
    @Published var messages: [ChatMessage] = []
    @Published var isProcessing = false
    @Published var totalTokens = 0

    private let cliClient: ClaudeCLIClient

    init(cliClient: ClaudeCLIClient) {
        self.cliClient = cliClient
    }

    func send(_ text: String, model: String, permissionMode: String, systemPrompt: String?) async {
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }

        isProcessing = true
        defer { isProcessing = false }

        messages.append(ChatMessage(role: .user, content: text))

        var assistantText = ""
        var pendingToolCalls: [ToolCallInfo] = []
        var assistantMessageIndex: Int?
        // Coalesce streamed text updates: markdown parsing in MessageBubble runs on
        // full running content per invalidation, so unthrottled token writes are
        // O(N²) in final message length and cause beach-balling on long replies.
        var lastFlushAt = Date.distantPast
        let flushInterval: TimeInterval = 0.05

        func applyAssistantText(_ text: String, force: Bool = false) {
            assistantText = text
            let now = Date()
            let shouldFlush = force
                || assistantMessageIndex == nil
                || now.timeIntervalSince(lastFlushAt) >= flushInterval
            guard shouldFlush else { return }
            lastFlushAt = now
            if let idx = assistantMessageIndex {
                self.messages[idx].content = assistantText
            } else {
                self.messages.append(ChatMessage(role: .assistant, content: assistantText))
                assistantMessageIndex = self.messages.count - 1
            }
        }

        do {
            let result = try await cliClient.send(
                message: text,
                model: model,
                permissionMode: permissionMode,
                systemPrompt: systemPrompt
            ) { [weak self] event in
                guard let self else { return }

                switch event {
                case .system(let sys):
                    logger.info("Session: \(sys.sessionId), MCP servers: \(sys.mcpServers.count)")

                case .assistant(let msg):
                    if let text = msg.text {
                        applyAssistantText(text)
                    }

                case .toolUse(let tool):
                    let info = ToolCallInfo(
                        toolName: tool.toolName,
                        arguments: tool.input
                    )
                    pendingToolCalls.append(info)

                    if let idx = assistantMessageIndex {
                        self.messages[idx].toolCalls.append(info)
                    } else {
                        var msg = ChatMessage(role: .assistant, content: "")
                        msg.toolCalls.append(info)
                        self.messages.append(msg)
                        assistantMessageIndex = self.messages.count - 1
                    }

                case .toolResult(let toolResult):
                    if let msgIdx = assistantMessageIndex {
                        if let tcIdx = self.messages[msgIdx].toolCalls.lastIndex(where: { $0.toolName != "" && !$0.isComplete }) {
                            self.messages[msgIdx].toolCalls[tcIdx].result = toolResult.content
                            self.messages[msgIdx].toolCalls[tcIdx].isComplete = true
                        }
                    }

                case .result:
                    break

                case .unknown:
                    break
                }
            }

            totalTokens += result.inputTokens + result.outputTokens

            // Flush any held-back streamed text before applying the final result.
            if !assistantText.isEmpty {
                applyAssistantText(assistantText, force: true)
            }

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

    func cancel() {
        cliClient.cancel()
        isProcessing = false
    }
}
