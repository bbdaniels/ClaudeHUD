import SwiftUI

struct InputBar: View {
    @Binding var text: String
    @FocusState.Binding var isFocused: Bool
    let onSend: () -> Void

    @EnvironmentObject var conversation: ConversationManager

    var body: some View {
        TextField("Ask anything...", text: $text)
            .font(.system(size: 13))
            .textFieldStyle(.plain)
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
            .background(
                RoundedRectangle(cornerRadius: 10)
                    .fill(Color(.textBackgroundColor))
                    .overlay(
                        RoundedRectangle(cornerRadius: 10)
                            .stroke(Color.secondary.opacity(0.15), lineWidth: 1)
                    )
            )
            .focused($isFocused)
            .disabled(conversation.isProcessing)
            .onSubmit {
                onSend()
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
    }
}
