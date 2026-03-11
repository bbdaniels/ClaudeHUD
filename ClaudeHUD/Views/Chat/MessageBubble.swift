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

            if !message.content.isEmpty {
                MarkdownContentView(content: message.content)
                    .padding(.horizontal, 16)
                    .padding(.bottom, message.toolCalls.isEmpty ? 10 : 6)
            }

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

// MARK: - Markdown Content (with table support)

struct MarkdownContentView: View {
    let content: String

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ForEach(Array(parseBlocks().enumerated()), id: \.offset) { _, block in
                switch block {
                case .text(let text):
                    Text(LocalizedStringKey(text))
                        .font(.system(size: 13))
                        .textSelection(.enabled)
                        .lineSpacing(3)
                case .table(let table):
                    MarkdownTableView(table: table)
                case .code(let code):
                    CodeBlockView(code: code)
                }
            }
        }
    }

    private func parseBlocks() -> [ContentBlock] {
        var blocks: [ContentBlock] = []
        var currentText = ""
        let lines = content.components(separatedBy: "\n")
        var i = 0

        while i < lines.count {
            let line = lines[i]

            // Detect fenced code block: line starts with ```
            if line.trimmingCharacters(in: .whitespaces).hasPrefix("```") {
                // Flush pending text
                if !currentText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    blocks.append(.text(currentText.trimmingCharacters(in: .whitespacesAndNewlines)))
                    currentText = ""
                }

                // Skip the opening fence line, collect body until closing ```
                i += 1
                var codeLines: [String] = []
                while i < lines.count {
                    let cl = lines[i]
                    if cl.trimmingCharacters(in: .whitespaces).hasPrefix("```") {
                        i += 1 // consume closing fence
                        break
                    }
                    codeLines.append(cl)
                    i += 1
                }
                blocks.append(.code(codeLines.joined(separator: "\n")))

            // Detect table: line starts with | and contains at least one more |
            } else if line.trimmingCharacters(in: .whitespaces).hasPrefix("|") &&
               line.filter({ $0 == "|" }).count >= 2 {
                // Flush pending text
                if !currentText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    blocks.append(.text(currentText.trimmingCharacters(in: .whitespacesAndNewlines)))
                    currentText = ""
                }

                // Collect all table lines
                var tableLines: [String] = []
                while i < lines.count {
                    let tl = lines[i].trimmingCharacters(in: .whitespaces)
                    if tl.hasPrefix("|") && tl.filter({ $0 == "|" }).count >= 2 {
                        tableLines.append(tl)
                        i += 1
                    } else {
                        break
                    }
                }

                if let table = parseTable(tableLines) {
                    blocks.append(.table(table))
                }
            } else {
                currentText += (currentText.isEmpty ? "" : "\n") + line
                i += 1
            }
        }

        if !currentText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            blocks.append(.text(currentText.trimmingCharacters(in: .whitespacesAndNewlines)))
        }

        return blocks
    }

    private func parseTable(_ lines: [String]) -> ParsedTable? {
        guard lines.count >= 2 else { return nil }

        func parseCells(_ line: String) -> [String] {
            line.split(separator: "|", omittingEmptySubsequences: false)
                .map { $0.trimmingCharacters(in: .whitespaces) }
                .filter { !$0.isEmpty }
        }

        let headers = parseCells(lines[0])

        // Skip separator line (the |---|---| line)
        let dataStart = lines.count > 1 && lines[1].contains("-") ? 2 : 1

        var rows: [[String]] = []
        for line in lines[dataStart...] {
            let cells = parseCells(line)
            // Skip separator lines
            if cells.allSatisfy({ $0.allSatisfy({ $0 == "-" || $0 == ":" || $0 == " " }) }) {
                continue
            }
            rows.append(cells)
        }

        return ParsedTable(headers: headers, rows: rows)
    }

    enum ContentBlock {
        case text(String)
        case table(ParsedTable)
        case code(String)
    }
}

struct CodeBlockView: View {
    let code: String

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            Text(code)
                .font(.system(size: 12, design: .monospaced))
                .textSelection(.enabled)
                .padding(10)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .background(Color(NSColor.windowBackgroundColor).opacity(0.6))
        .overlay(
            RoundedRectangle(cornerRadius: 6)
                .stroke(Color.secondary.opacity(0.2), lineWidth: 0.5)
        )
        .clipShape(RoundedRectangle(cornerRadius: 6))
    }
}

struct ParsedTable {
    let headers: [String]
    let rows: [[String]]
}

struct MarkdownTableView: View {
    let table: ParsedTable

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Header row
            HStack(spacing: 0) {
                ForEach(Array(table.headers.enumerated()), id: \.offset) { _, header in
                    Text(LocalizedStringKey(header))
                        .font(.system(size: 12, weight: .semibold))
                        .lineLimit(2)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 5)
                }
            }
            .background(Color.secondary.opacity(0.12))

            // Data rows
            ForEach(Array(table.rows.enumerated()), id: \.offset) { rowIdx, row in
                HStack(spacing: 0) {
                    ForEach(Array(row.enumerated()), id: \.offset) { _, cell in
                        Text(LocalizedStringKey(cell))
                            .font(.system(size: 12))
                            .lineLimit(3)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.horizontal, 8)
                            .padding(.vertical, 4)
                    }
                }
                .background(rowIdx % 2 == 0 ? Color.clear : Color.secondary.opacity(0.05))
            }
        }
        .overlay(
            RoundedRectangle(cornerRadius: 6)
                .stroke(Color.secondary.opacity(0.2), lineWidth: 0.5)
        )
        .clipShape(RoundedRectangle(cornerRadius: 6))
        .textSelection(.enabled)
    }
}
