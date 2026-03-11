import SwiftUI

struct MessageBubble: View {
    let message: ChatMessage

    var body: some View {
        if message.role == .system {
            systemMessage
        } else {
            chatMessage
        }
    }

    private var systemMessage: some View {
        HStack {
            Image(systemName: "exclamationmark.triangle")
                .font(.caption)
                .foregroundColor(.orange)
            Text(message.content)
                .font(.system(size: 12))
                .foregroundColor(.orange)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 6)
    }

    private var chatMessage: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Role label
            HStack(spacing: 4) {
                if message.role == .assistant {
                    Image(systemName: "sparkle")
                        .font(.system(size: 9))
                        .foregroundColor(.orange)
                }
                Text(message.role == .user ? "you" : "claude")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundColor(message.role == .user ? .secondary : .orange)
            }
            .padding(.horizontal, 16)
            .padding(.top, 10)
            .padding(.bottom, 4)

            // Content
            if !message.content.isEmpty {
                Text(LocalizedStringKey(message.content))
                    .font(.system(size: 13))
                    .textSelection(.enabled)
                    .lineSpacing(3)
                    .padding(.horizontal, 16)
                    .padding(.bottom, message.toolCalls.isEmpty ? 10 : 6)
            }

            // Tool calls
            ForEach(message.toolCalls) { toolCall in
                ToolCallView(toolCall: toolCall)
                    .padding(.horizontal, 12)
                    .padding(.bottom, 6)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(message.role == .user ? Color.accentColor.opacity(0.04) : Color.clear)
    }
}
