import SwiftUI

struct InputBar: View {
    @Binding var text: String
    @FocusState.Binding var isFocused: Bool
    let onSend: () -> Void

    @EnvironmentObject var conversation: ConversationManager

    var body: some View {
        HStack(alignment: .bottom, spacing: 8) {
            // Multi-line text editor
            TextEditor(text: $text)
                .font(.body)
                .frame(minHeight: 36, maxHeight: 100)
                .scrollContentBackground(.hidden)
                .padding(4)
                .background(
                    RoundedRectangle(cornerRadius: 8)
                        .fill(Color(.textBackgroundColor))
                )
                .focused($isFocused)

            // Send button
            Button(action: onSend) {
                Image(systemName: "arrow.up.circle.fill")
                    .font(.title2)
                    .foregroundColor(text.isEmpty || conversation.isProcessing ? .secondary : .orange)
            }
            .buttonStyle(.borderless)
            .disabled(text.isEmpty || conversation.isProcessing)
            .keyboardShortcut(.return, modifiers: .command)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }
}
