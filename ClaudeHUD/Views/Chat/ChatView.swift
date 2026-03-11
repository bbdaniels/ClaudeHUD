import SwiftUI

struct ChatView: View {
    @EnvironmentObject var conversation: ConversationManager
    @State private var inputText = ""
    @FocusState private var isInputFocused: Bool

    var body: some View {
        VStack(spacing: 0) {
            if conversation.messages.isEmpty {
                WelcomeView()
            } else {
                messageList
            }

            Divider()
                .opacity(0.5)

            InputBar(text: $inputText, isFocused: $isInputFocused) {
                send()
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
                                .font(.system(size: 12))
                                .foregroundColor(.secondary)
                            Spacer()
                        }
                        .padding(.horizontal, 16)
                        .padding(.vertical, 8)
                        .id("loading")
                    }
                }
                .padding(.vertical, 8)
            }
            .onChange(of: conversation.messages.count) { _, _ in
                withAnimation(.easeOut(duration: 0.2)) {
                    if let lastId = conversation.messages.last?.id {
                        proxy.scrollTo(lastId, anchor: .bottom)
                    }
                }
            }
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

struct WelcomeView: View {
    var body: some View {
        VStack(spacing: 12) {
            Spacer()

            Image(systemName: "sparkle")
                .font(.system(size: 32))
                .foregroundColor(.orange.opacity(0.6))

            Text("What can I do for you today?")
                .font(.system(size: 15, weight: .medium))
                .foregroundColor(.secondary)

            Spacer()
        }
        .frame(maxWidth: .infinity)
    }
}
