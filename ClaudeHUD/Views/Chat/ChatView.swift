import SwiftUI

struct ChatView: View {
    @EnvironmentObject var conversation: ConversationManager
    @State private var inputText = ""
    @FocusState private var isInputFocused: Bool

    var body: some View {
        VStack(spacing: 0) {
            // Messages scroll view
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 8) {
                        ForEach(conversation.messages) { message in
                            MessageBubble(message: message)
                                .id(message.id)
                        }

                        if conversation.isProcessing {
                            HStack {
                                ProgressView()
                                    .scaleEffect(0.7)
                                Text("Thinking...")
                                    .font(.caption)
                                    .foregroundColor(.secondary)
                            }
                            .padding(.horizontal)
                            .id("loading")
                        }
                    }
                    .padding(.vertical, 8)
                }
                .onChange(of: conversation.messages.count) { _, _ in
                    withAnimation {
                        if let lastId = conversation.messages.last?.id {
                            proxy.scrollTo(lastId, anchor: .bottom)
                        }
                    }
                }
            }

            Divider()

            // Input bar
            InputBar(text: $inputText, isFocused: $isInputFocused) {
                send()
            }

            // Status bar
            StatusBar()
        }
        .onAppear {
            isInputFocused = true
        }
    }

    private func send() {
        let text = inputText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        inputText = ""
        Task {
            await conversation.send(text)
        }
    }
}

struct StatusBar: View {
    @EnvironmentObject var conversation: ConversationManager

    var body: some View {
        HStack {
            Button(action: { conversation.newConversation() }) {
                Image(systemName: "plus.circle")
            }
            .buttonStyle(.borderless)
            .help("New conversation")

            Spacer()

            if conversation.totalTokens > 0 {
                Text("\(conversation.totalTokens) tokens")
                    .font(.caption2)
                    .foregroundColor(.secondary)
            }

            // Model indicator
            Text(conversation.selectedModel.contains("haiku") ? "Haiku" : "Sonnet")
                .font(.caption2)
                .padding(.horizontal, 6)
                .padding(.vertical, 2)
                .background(Color.orange.opacity(0.2))
                .cornerRadius(4)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 4)
    }
}
