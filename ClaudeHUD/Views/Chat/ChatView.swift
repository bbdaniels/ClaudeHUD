import SwiftUI

struct ChatView: View {
    @EnvironmentObject var conversation: ConversationManager
    @EnvironmentObject var tabManager: TabManager
    @Environment(\.fontScale) private var scale
    @State private var inputText = ""
    @FocusState private var isInputFocused: Bool

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
                        .id("loading")
                    }
                }
                .padding(.vertical, 8)
            }
            .onChange(of: conversation.messages.count) { _, _ in
                scrollToBottom(proxy)
            }
            .onChange(of: conversation.isProcessing) { _, processing in
                if processing {
                    scrollToBottom(proxy)
                }
            }
        }
    }

    private func scrollToBottom(_ proxy: ScrollViewProxy) {
        withAnimation(.easeOut(duration: 0.2)) {
            if conversation.isProcessing {
                proxy.scrollTo("loading", anchor: .bottom)
            } else if let lastId = conversation.messages.last?.id {
                proxy.scrollTo(lastId, anchor: .bottom)
            }
        }
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
