import SwiftUI
import AppKit

/// One row in the Library tab — uniform across all categories.
/// Layout: title + summary on the left, three small action buttons on the right
/// (Reveal in Finder, Open in VS Code, Open with Claude). Mirrors the action
/// stack on the History tab's ProjectRow so the muscle memory is the same.
struct LibraryRow: View {
    let item: LibraryItem
    @EnvironmentObject var library: LibraryService
    @EnvironmentObject var terminalService: TerminalService
    @Environment(\.fontScale) private var scale
    @State private var feedback: String?

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text(item.displayName)
                        .font(.smallMedium(scale))
                        .foregroundColor(.primary)
                        .lineLimit(1)
                    if item.category == .skills && item.frontmatter["family"] == nil {
                        Text("untagged")
                            .font(.system(size: 9 * scale))
                            .foregroundColor(.orange)
                            .padding(.horizontal, 4)
                            .padding(.vertical, 1)
                            .background(
                                RoundedRectangle(cornerRadius: 3)
                                    .fill(Color.orange.opacity(0.12))
                            )
                    }
                    if let group = item.group, item.category == .hooks {
                        Text(group)
                            .font(.system(size: 9 * scale))
                            .foregroundColor(.secondary)
                            .padding(.horizontal, 4)
                            .padding(.vertical, 1)
                            .background(
                                RoundedRectangle(cornerRadius: 3)
                                    .fill(Color.secondary.opacity(0.12))
                            )
                    }
                }
                if !item.summary.isEmpty {
                    Text(item.summary)
                        .font(.captionFont(scale))
                        .foregroundColor(.secondary)
                        .lineLimit(2)
                        .fixedSize(horizontal: false, vertical: true)
                } else {
                    Text("(no description)")
                        .font(.captionFont(scale))
                        .foregroundColor(.secondary.opacity(0.5))
                        .italic()
                }
            }

            Spacer()

            if let feedback {
                Text(feedback)
                    .font(.custom("Fira Sans", size: 11 * scale))
                    .foregroundColor(.green)
            } else {
                // Same icon stack pattern as History's ProjectRow: small SF
                // Symbols in white, optional launcher buttons in Fira Code.
                Button(action: revealInFinder) {
                    Image(systemName: "folder")
                        .font(.system(size: 11 * scale, weight: .semibold))
                        .foregroundColor(.white)
                }
                .buttonStyle(.borderless)
                .hudTip("Reveal in Finder")

                Button(action: openInVSCode) {
                    Text("VS")
                        .font(.custom("Fira Code", size: 10 * scale).weight(.semibold))
                        .foregroundColor(.white)
                }
                .buttonStyle(.borderless)
                .hudTip("Open in VS Code")

                Button(action: openWithClaude) {
                    Image(systemName: "wand.and.stars")
                        .font(.system(size: 11 * scale, weight: .semibold))
                        .foregroundColor(.white)
                }
                .buttonStyle(.borderless)
                .hudTip("Open with Claude")
            }
        }
        .padding(.horizontal, 4)
        .padding(.vertical, 6)
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(Rectangle())
    }

    // MARK: - Actions

    private func revealInFinder() {
        library.revealInFinder(item)
    }

    private func openInVSCode() {
        terminalService.openInVSCode(item.path)
    }

    private func openWithClaude() {
        let prompt = item.category.openPrompt(for: item)
        let dir: String
        if item.isDirectory {
            dir = item.path.path
        } else {
            dir = item.path.deletingLastPathComponent().path
        }
        let command = "claude --dangerously-skip-permissions --effort high \"\(Self.shellQuote(prompt))\""
        let ghostty = "/Applications/Ghostty.app"
        let app = FileManager.default.fileExists(atPath: ghostty) ? ghostty : nil
        let auto = terminalService.launchWithCommand(command, inDirectory: dir, usingApp: app)
        feedback = auto ? "Opened!" : "Cmd+V"
        DispatchQueue.main.asyncAfter(deadline: .now() + 3) { feedback = nil }
    }

    /// Escape characters with special meaning inside shell double-quotes.
    private static func shellQuote(_ s: String) -> String {
        s
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "$", with: "\\$")
            .replacingOccurrences(of: "`", with: "\\`")
            .replacingOccurrences(of: "\"", with: "\\\"")
    }
}
