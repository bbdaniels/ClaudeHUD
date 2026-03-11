import SwiftUI

struct ToolCallView: View {
    let toolCall: ToolCallInfo
    @State private var isExpanded = false

    // Strip mcp__servername__ prefix for display
    private var displayName: String {
        // mcp__servername__toolname -> extract last part after double underscore
        if toolCall.toolName.hasPrefix("mcp__") {
            let withoutPrefix = toolCall.toolName.dropFirst(5)  // drop "mcp__"
            if let range = withoutPrefix.range(of: "__") {
                return String(withoutPrefix[range.upperBound...])
            }
        }
        return toolCall.toolName
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            // Header: tool name + status
            Button(action: { withAnimation { isExpanded.toggle() } }) {
                HStack(spacing: 6) {
                    Image(systemName: isExpanded ? "chevron.down" : "chevron.right")
                        .font(.caption2)

                    Image(systemName: "wrench")
                        .font(.caption)

                    Text(displayName)
                        .font(.caption)
                        .fontWeight(.medium)

                    Spacer()

                    if !toolCall.isComplete {
                        ProgressView()
                            .scaleEffect(0.5)
                    } else if toolCall.isError {
                        Image(systemName: "exclamationmark.triangle")
                            .foregroundColor(.red)
                            .font(.caption)
                    } else {
                        Image(systemName: "checkmark.circle")
                            .foregroundColor(.green)
                            .font(.caption)
                    }
                }
            }
            .buttonStyle(.plain)

            // Expanded content
            if isExpanded {
                VStack(alignment: .leading, spacing: 4) {
                    // Arguments
                    Text("Arguments:")
                        .font(.caption2)
                        .foregroundColor(.secondary)
                    Text(toolCall.arguments)
                        .font(.system(size: 11, design: .monospaced))
                        .textSelection(.enabled)
                        .lineLimit(5)

                    // Result
                    if let result = toolCall.result {
                        Text("Result:")
                            .font(.caption2)
                            .foregroundColor(.secondary)
                        Text(result)
                            .font(.system(size: 11, design: .monospaced))
                            .textSelection(.enabled)
                            .lineLimit(10)
                            .foregroundColor(toolCall.isError ? .red : .primary)
                    }
                }
                .padding(8)
                .background(
                    RoundedRectangle(cornerRadius: 6)
                        .fill(Color(.controlBackgroundColor).opacity(0.5))
                )
            }
        }
        .padding(8)
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill(Color(.controlBackgroundColor).opacity(0.3))
                .overlay(
                    RoundedRectangle(cornerRadius: 8)
                        .stroke(Color.secondary.opacity(0.2), lineWidth: 0.5)
                )
        )
    }
}
