import SwiftUI

struct ChatView: View {
    @EnvironmentObject var conversation: ConversationManager
    @EnvironmentObject var tabManager: TabManager
    @Environment(\.fontScale) private var scale
    @State private var inputText = ""
    @State private var isStickyBottom = true
    @FocusState private var isInputFocused: Bool

    // Captures any growth in the last message: text streaming, tool-call
    // insertion, and per-tool completion/result-length changes. Used to
    // keep the viewport pinned to the bottom while the user isn't scrolling.
    private var lastMessageFootprint: String {
        guard let last = conversation.messages.last else { return "" }
        let tools = last.toolCalls
            .map { "\($0.isComplete ? 1 : 0):\($0.result?.count ?? 0)" }
            .joined(separator: ",")
        return "\(last.content.count)|\(last.toolCalls.count)|\(tools)"
    }

    var body: some View {
        VStack(spacing: 0) {
            if conversation.messages.isEmpty && !conversation.isProcessing {
                WelcomeView()
            } else {
                messageList
            }

            Divider()
                .opacity(0.5)

            // Input or stop button
            if conversation.isProcessing {
                HStack {
                    Button(action: { conversation.cancel() }) {
                        HStack(spacing: 6) {
                            Image(systemName: "stop.circle.fill")
                                .font(.smallFont(scale))
                            Text("Stop")
                                .font(.bodyFont(scale))
                        }
                        .foregroundColor(.red)
                    }
                    .buttonStyle(.borderless)
                    Spacer()
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 12)
            } else {
                InputBar(text: $inputText, isFocused: $isInputFocused) {
                    send()
                }
            }
        }
        .onAppear {
            isInputFocused = true
        }
    }

    private var messageList: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(spacing: 2) {
                    ForEach(conversation.messages) { message in
                        MessageBubble(message: message)
                            .id(message.id)
                    }

                    if conversation.isProcessing {
                        HStack(spacing: 6) {
                            ProgressView()
                                .scaleEffect(0.6)
                            Text("Thinking...")
                                .font(.smallFont(scale))
                                .foregroundColor(.secondary)
                            Spacer()
                        }
                        .padding(.horizontal, 16)
                        .padding(.vertical, 8)
                    }

                    // Stable scroll target. A fixed-ID sentinel avoids the layout
                    // thrash that `scrollTo(lastId, anchor: .bottom)` causes on a
                    // LazyVStack whose last item is still growing mid-stream.
                    // onAppear/onDisappear drives `isStickyBottom`: once the user
                    // scrolls the sentinel off-screen, streaming updates stop
                    // yanking the viewport back.
                    Color.clear
                        .frame(height: 1)
                        .id("bottom")
                        .onAppear { isStickyBottom = true }
                        .onDisappear { isStickyBottom = false }
                }
                .padding(.vertical, 8)
            }
            .onChange(of: conversation.messages.count) { _, _ in
                // New turn (user send or new assistant message) — always follow.
                isStickyBottom = true
                scrollToBottom(proxy)
            }
            .onChange(of: lastMessageFootprint) { _, _ in
                // Streaming growth — only follow if user hasn't scrolled up.
                if isStickyBottom {
                    scrollToBottom(proxy)
                }
            }
            .onChange(of: conversation.isProcessing) { _, processing in
                if processing {
                    isStickyBottom = true
                    scrollToBottom(proxy)
                }
            }
        }
    }

    private func scrollToBottom(_ proxy: ScrollViewProxy) {
        proxy.scrollTo("bottom", anchor: .bottom)
    }

    private func send() {
        let text = inputText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        inputText = ""
        Task {
            await tabManager.send(text)
        }
    }
}

struct WelcomeView: View {
    @Environment(\.fontScale) private var scale
    var body: some View {
        VStack(spacing: 12) {
            Spacer()

            Image("ClaudeLogo")
                .resizable()
                .frame(width: 48, height: 48)
                .opacity(0.6)

            Text("What can I do for you today?")
                .font(.bodyMedium(scale))
                .foregroundColor(.secondary)

            Spacer()
        }
        .frame(maxWidth: .infinity)
    }
}
