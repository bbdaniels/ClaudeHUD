import SwiftUI
import AppKit

/// Extended markdown view for Obsidian notes.
/// Reuses the same parsing approach as MarkdownContentView but adds:
/// - Interactive checkboxes (write back to file)
/// - Image rendering (vault-relative paths)
/// - Wikilinks ([[note]]) as clickable links
/// - Strikethrough (~~text~~) support
struct ObsidianMarkdownView: View {
    let content: String
    let filePath: String
    var onContentChanged: ((String) -> Void)?

    @Environment(\.fontScale) private var scale

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ForEach(Array(parseBlocks().enumerated()), id: \.offset) { _, block in
                switch block {
                case .text(let text):
                    Text(LocalizedStringKey(processInlineForObsidian(text)))
                        .font(.bodyFont(scale))
                        .textSelection(.enabled)
                        .lineSpacing(3)
                case .table(let table):
                    MarkdownTableView(table: table)
                case .code(let code):
                    CodeBlockView(code: code)
                case .list(let items):
                    ObsidianListBlockView(
                        items: items,
                        filePath: filePath,
                        rawContent: content,
                        onContentChanged: onContentChanged
                    )
                case .math(let expr):
                    MathBlockView(expression: expr)
                case .blockquote(let text):
                    BlockquoteView(text: processInlineForObsidian(text))
                case .horizontalRule:
                    Divider().opacity(0.5)
                case .heading(let text, let level):
                    HeadingView(text: processInlineForObsidian(text), level: level)
                case .image(let alt, let resolvedPath):
                    ObsidianImageView(alt: alt, path: resolvedPath)
                }
            }
        }
    }

    // MARK: - Inline Processing

    /// Process inline elements for Obsidian: wikilinks, inline math, strikethrough
    private func processInlineForObsidian(_ text: String) -> String {
        var result = text

        // Convert wikilinks [[note]] or [[note|display]] to markdown links
        result = processWikilinks(result)

        // Convert strikethrough ~~text~~ (SwiftUI's LocalizedStringKey supports this)
        // Already handled by SwiftUI markdown — no conversion needed

        // Process inline math $...$
        result = MarkdownContentView.processInlineMath(result)

        return result
    }

    /// Convert [[note]] and [[note|display]] to standard markdown links
    private func processWikilinks(_ text: String) -> String {
        var output = ""
        var i = text.startIndex

        while i < text.endIndex {
            // Check for [[ start
            if text[i] == "[",
               text.index(after: i) < text.endIndex,
               text[text.index(after: i)] == "[" {
                let contentStart = text.index(i, offsetBy: 2)
                // Find closing ]]
                if let closeRange = text.range(of: "]]", range: contentStart..<text.endIndex) {
                    let inner = String(text[contentStart..<closeRange.lowerBound])
                    let parts = inner.split(separator: "|", maxSplits: 1)
                    let noteName = String(parts[0])
                    let display = parts.count > 1 ? String(parts[1]) : noteName

                    // Convert to markdown link with obsidian:// URI
                    if let encoded = noteName.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) {
                        output += "[\(display)](obsidian://open?file=\(encoded))"
                    } else {
                        output += display
                    }
                    i = closeRange.upperBound
                    continue
                }
            }
            output.append(text[i])
            i = text.index(after: i)
        }
        return output
    }

    // MARK: - Block Parsing (extended from MarkdownContentView)

    enum ObsidianBlock {
        case text(String)
        case table(ParsedTable)
        case code(String)
        case list([ObsidianListItem])
        case math(String)
        case blockquote(String)
        case horizontalRule
        case heading(String, Int)
        case image(alt: String, path: String)
    }

    static let listPattern = try! NSRegularExpression(pattern: #"^(\s*)([-*•]|\d+[.)]) (\[[ xX]\] )?"#)

    static func isListLine(_ line: String) -> Bool {
        let range = NSRange(line.startIndex..., in: line)
        return listPattern.firstMatch(in: line, range: range) != nil
    }

    static func parseListItem(_ line: String, lineNumber: Int) -> ObsidianListItem {
        let trimmed = line.replacingOccurrences(of: "^\t", with: "    ", options: .regularExpression)
        let stripped = trimmed.drop(while: { $0 == " " })
        let indent = trimmed.count - stripped.count
        let level = indent / 2

        var text = String(stripped)
        if let range = text.range(of: #"^([-*•]|\d+[.)]) "#, options: .regularExpression) {
            let prefix = text[range]
            let isOrdered = prefix.first?.isNumber == true
            text = String(text[range.upperBound...])

            var checkState: Bool? = nil
            if let checkRange = text.range(of: #"^\[[ xX]\] "#, options: .regularExpression) {
                let checkMark = text[checkRange]
                checkState = checkMark.contains("x") || checkMark.contains("X")
                text = String(text[checkRange.upperBound...])
            }

            return ObsidianListItem(text: text, level: level, isOrdered: isOrdered,
                                     checkState: checkState, lineNumber: lineNumber)
        }
        return ObsidianListItem(text: text, level: level, isOrdered: false,
                                 checkState: nil, lineNumber: lineNumber)
    }

    private func parseBlocks() -> [ObsidianBlock] {
        var blocks: [ObsidianBlock] = []
        var currentText = ""
        let lines = content.components(separatedBy: "\n")
        var i = 0

        func flushText() {
            let t = currentText.trimmingCharacters(in: .whitespacesAndNewlines)
            if !t.isEmpty { blocks.append(.text(t)) }
            currentText = ""
        }

        while i < lines.count {
            let line = lines[i]
            let trimmed = line.trimmingCharacters(in: .whitespaces)

            // Fenced code block
            if trimmed.hasPrefix("```") {
                flushText()
                i += 1
                var codeLines: [String] = []
                while i < lines.count {
                    if lines[i].trimmingCharacters(in: .whitespaces).hasPrefix("```") {
                        i += 1; break
                    }
                    codeLines.append(lines[i])
                    i += 1
                }
                blocks.append(.code(codeLines.joined(separator: "\n")))

            // Display math $$
            } else if trimmed.hasPrefix("$$") {
                flushText()
                if trimmed.count > 4 && trimmed.hasSuffix("$$") {
                    blocks.append(.math(String(trimmed.dropFirst(2).dropLast(2))))
                    i += 1
                } else {
                    i += 1
                    var mathLines: [String] = []
                    while i < lines.count {
                        let ml = lines[i].trimmingCharacters(in: .whitespaces)
                        if ml.hasSuffix("$$") {
                            if ml != "$$" { mathLines.append(String(ml.dropLast(2))) }
                            i += 1; break
                        }
                        mathLines.append(lines[i])
                        i += 1
                    }
                    blocks.append(.math(mathLines.joined(separator: "\n")))
                }

            // Image: ![alt](path) or ![[image.png]]
            } else if trimmed.hasPrefix("![") {
                flushText()
                if let img = parseImageLine(trimmed) {
                    blocks.append(.image(alt: img.alt, path: img.path))
                } else {
                    currentText += (currentText.isEmpty ? "" : "\n") + line
                }
                i += 1

            // Table
            } else if trimmed.hasPrefix("|") && trimmed.filter({ $0 == "|" }).count >= 2 {
                flushText()
                var tableLines: [String] = []
                while i < lines.count {
                    let tl = lines[i].trimmingCharacters(in: .whitespaces)
                    if tl.hasPrefix("|") && tl.filter({ $0 == "|" }).count >= 2 {
                        tableLines.append(tl)
                        i += 1
                    } else { break }
                }
                if let table = parseTable(tableLines) { blocks.append(.table(table)) }

            // Horizontal rule
            } else if trimmed.count >= 3 && (
                trimmed.allSatisfy({ $0 == "-" || $0 == " " }) && trimmed.filter({ $0 == "-" }).count >= 3 ||
                trimmed.allSatisfy({ $0 == "*" || $0 == " " }) && trimmed.filter({ $0 == "*" }).count >= 3 ||
                trimmed.allSatisfy({ $0 == "_" || $0 == " " }) && trimmed.filter({ $0 == "_" }).count >= 3
            ) {
                flushText()
                blocks.append(.horizontalRule)
                i += 1

            // Blockquote
            } else if trimmed.hasPrefix("> ") || trimmed == ">" {
                flushText()
                var quoteLines: [String] = []
                while i < lines.count {
                    let ql = lines[i].trimmingCharacters(in: .whitespaces)
                    if ql.hasPrefix("> ") {
                        quoteLines.append(String(ql.dropFirst(2)))
                        i += 1
                    } else if ql == ">" {
                        quoteLines.append("")
                        i += 1
                    } else { break }
                }
                blocks.append(.blockquote(quoteLines.joined(separator: "\n")))

            // Heading
            } else if trimmed.hasPrefix("#") && !trimmed.hasPrefix("#!") {
                let hashes = trimmed.prefix(while: { $0 == "#" })
                let level = min(hashes.count, 6)
                let rest = trimmed.dropFirst(level).trimmingCharacters(in: .whitespaces)
                if !rest.isEmpty && level >= 1 {
                    flushText()
                    blocks.append(.heading(rest, level))
                    i += 1
                } else {
                    currentText += (currentText.isEmpty ? "" : "\n") + line
                    i += 1
                }

            // List items
            } else if Self.isListLine(line) {
                flushText()
                var items: [ObsidianListItem] = []
                while i < lines.count && Self.isListLine(lines[i]) {
                    items.append(Self.parseListItem(lines[i], lineNumber: i))
                    i += 1
                }
                blocks.append(.list(items))

            } else {
                currentText += (currentText.isEmpty ? "" : "\n") + line
                i += 1
            }
        }

        flushText()
        return blocks
    }

    // MARK: - Image Parsing

    private struct ImageRef {
        let alt: String
        let path: String
    }

    private func parseImageLine(_ line: String) -> ImageRef? {
        // Standard: ![alt](path)
        if let match = line.range(of: #"^!\[([^\]]*)\]\(([^)]+)\)"#, options: .regularExpression) {
            let content = String(line[match])
            // Extract alt and path
            if let altEnd = content.firstIndex(of: "]"),
               let pathStart = content.range(of: "]("),
               let pathEnd = content.lastIndex(of: ")") {
                let alt = String(content[content.index(content.startIndex, offsetBy: 2)..<altEnd])
                let rawPath = String(content[pathStart.upperBound..<pathEnd])
                return ImageRef(alt: alt, path: resolveImagePath(rawPath))
            }
        }

        // Wiki-style: ![[image.png]]
        if let match = line.range(of: #"^!\[\[([^\]]+)\]\]"#, options: .regularExpression) {
            let content = String(line[match])
            let inner = String(content.dropFirst(3).dropLast(2))
            return ImageRef(alt: inner, path: resolveImagePath(inner))
        }

        return nil
    }

    private func resolveImagePath(_ rawPath: String) -> String {
        // Already absolute
        if rawPath.hasPrefix("/") { return rawPath }
        // URL
        if rawPath.contains("://") { return rawPath }

        // Try relative to the note's directory first
        let noteDir = (filePath as NSString).deletingLastPathComponent
        let relative = (noteDir as NSString).appendingPathComponent(rawPath)
        if FileManager.default.fileExists(atPath: relative) { return relative }

        // Try relative to vault root
        if let vaultPath = VaultSettings.loadFromDefaults().first(where: { filePath.hasPrefix($0.path) })?.path {
            let vaultRelative = (vaultPath as NSString).appendingPathComponent(rawPath)
            if FileManager.default.fileExists(atPath: vaultRelative) { return vaultRelative }
        }

        return relative
    }

    // MARK: - Table Parsing (same as MarkdownContentView)

    private func parseTable(_ lines: [String]) -> ParsedTable? {
        guard lines.count >= 2 else { return nil }

        func parseCells(_ line: String) -> [String] {
            line.split(separator: "|", omittingEmptySubsequences: false)
                .map { $0.trimmingCharacters(in: .whitespaces) }
                .filter { !$0.isEmpty }
        }

        let headers = parseCells(lines[0])
        let dataStart = lines.count > 1 && lines[1].contains("-") ? 2 : 1

        var rows: [[String]] = []
        for line in lines[dataStart...] {
            let cells = parseCells(line)
            if cells.allSatisfy({ $0.allSatisfy({ $0 == "-" || $0 == ":" || $0 == " " }) }) { continue }
            rows.append(cells)
        }

        return ParsedTable(headers: headers, rows: rows)
    }
}

// MARK: - Obsidian List Item (with line number tracking)

struct ObsidianListItem {
    let text: String
    let level: Int
    let isOrdered: Bool
    let checkState: Bool?
    let lineNumber: Int
}

// MARK: - Interactive List Block

struct ObsidianListBlockView: View {
    let items: [ObsidianListItem]
    let filePath: String
    let rawContent: String
    var onContentChanged: ((String) -> Void)?
    @Environment(\.fontScale) private var scale

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            ForEach(Array(items.enumerated()), id: \.offset) { idx, item in
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    if let checked = item.checkState {
                        Button(action: { toggleCheckbox(item) }) {
                            Image(systemName: checked ? "checkmark.square.fill" : "square")
                                .font(.bodyFont(scale))
                                .foregroundColor(checked ? .green : .secondary)
                        }
                        .buttonStyle(.borderless)
                        .frame(minWidth: 14, alignment: .trailing)
                    } else {
                        Text(item.isOrdered ? "\(ordinalNumber(idx, item))." : "•")
                            .font(.bodyFont(scale))
                            .foregroundColor(.secondary)
                            .frame(minWidth: 14, alignment: .trailing)
                    }

                    Text(LocalizedStringKey(item.text))
                        .font(.bodyFont(scale))
                        .textSelection(.enabled)
                        .lineSpacing(3)
                        .strikethrough(item.checkState == true, color: .secondary)
                }
                .padding(.leading, CGFloat(item.level) * 16)
            }
        }
    }

    private func ordinalNumber(_ index: Int, _ item: ObsidianListItem) -> Int {
        var n = 1
        var i = index - 1
        while i >= 0 && items[i].isOrdered && items[i].level == item.level {
            n += 1; i -= 1
        }
        return n
    }

    private func toggleCheckbox(_ item: ObsidianListItem) {
        var lines = rawContent.components(separatedBy: "\n")
        guard item.lineNumber < lines.count else { return }

        let line = lines[item.lineNumber]
        let newLine: String
        if item.checkState == true {
            newLine = line.replacingOccurrences(of: "[x] ", with: "[ ] ")
                .replacingOccurrences(of: "[X] ", with: "[ ] ")
        } else {
            newLine = line.replacingOccurrences(of: "[ ] ", with: "[x] ")
        }
        lines[item.lineNumber] = newLine

        let newContent = lines.joined(separator: "\n")

        // Write to file
        let url = URL(fileURLWithPath: filePath)
        try? newContent.write(to: url, atomically: true, encoding: .utf8)

        onContentChanged?(newContent)
    }
}

// MARK: - Image View

struct ObsidianImageView: View {
    let alt: String
    let path: String

    var body: some View {
        if path.contains("://") {
            // Remote image — show placeholder
            HStack {
                Image(systemName: "photo")
                    .foregroundColor(.secondary)
                Text(alt.isEmpty ? path : alt)
                    .foregroundColor(.secondary)
                    .font(.caption)
            }
        } else if let nsImage = NSImage(contentsOfFile: path) {
            Image(nsImage: nsImage)
                .resizable()
                .aspectRatio(contentMode: .fit)
                .frame(maxWidth: .infinity)
                .cornerRadius(6)
                .accessibilityLabel(alt)
        } else {
            HStack {
                Image(systemName: "photo.badge.exclamationmark")
                    .foregroundColor(.secondary)
                Text(alt.isEmpty ? "Image not found" : alt)
                    .foregroundColor(.secondary)
                    .font(.caption)
            }
        }
    }
}
