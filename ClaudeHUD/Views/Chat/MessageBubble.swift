import SwiftUI

struct MessageBubble: View {
    let message: ChatMessage

    var body: some View {
        VStack(alignment: message.role == .user ? .trailing : .leading, spacing: 4) {
            // Role label
            Text(message.role == .user ? "You" : "Claude")
                .font(.caption2)
                .foregroundColor(.secondary)

            // Content
            Text(LocalizedStringKey(message.content))  // supports markdown
                .textSelection(.enabled)
                .padding(10)
                .background(
                    RoundedRectangle(cornerRadius: 12)
                        .fill(message.role == .user ? Color.accentColor.opacity(0.15) : Color(.controlBackgroundColor))
                )

            // Tool calls
            ForEach(message.toolCalls) { toolCall in
                ToolCallView(toolCall: toolCall)
            }
        }
        .frame(maxWidth: .infinity, alignment: message.role == .user ? .trailing : .leading)
        .padding(.horizontal, 12)
    }
}
