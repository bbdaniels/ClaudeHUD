import SwiftUI

struct MessageBubble: View {
    let message: ChatMessage
    @Environment(\.fontScale) private var scale

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
                .font(.smallFont(scale))
                .foregroundColor(.orange)
            Text(message.content)
                .font(.smallFont(scale))
                .foregroundColor(.orange)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 6)
    }

    private var chatMessage: some View {
        let isUser = message.role == .user
        let alignment: HorizontalAlignment = isUser ? .trailing : .leading

        return VStack(alignment: alignment, spacing: 0) {
            HStack(spacing: 4) {
                if !isUser {
                    Image("ClaudeLogo")
                        .resizable()
                        .frame(width: 12, height: 12)
                }
                Text(isUser ? "you" : "claude")
                    .font(.smallMedium(scale))
                    .foregroundColor(isUser ? .secondary : .orange)
            }
            .padding(.top, 10)
            .padding(.bottom, 4)

            if !message.content.isEmpty {
                if isUser {
                    Text(message.content)
                        .font(.bodyFont(scale))
                        .textSelection(.enabled)
                        .lineSpacing(3)
                        .padding(.bottom, 10)
                } else {
                    MarkdownContentView(content: message.content)
                        .padding(.bottom, message.toolCalls.isEmpty ? 10 : 6)
                }
            }

            ForEach(message.toolCalls) { toolCall in
                ToolCallView(toolCall: toolCall)
                    .padding(.bottom, 6)
            }
        }
        .padding(.horizontal, 16)
        .frame(maxWidth: .infinity, alignment: isUser ? .trailing : .leading)
        .background(isUser ? Color.accentColor.opacity(0.04) : Color.clear)
    }
}

// MARK: - Markdown Content (with table support)

struct MarkdownContentView: View {
    let content: String
    let cachedBlocks: [ContentBlock]
    @Environment(\.fontScale) private var scale

    init(content: String) {
        self.content = content
        self.cachedBlocks = Self.parseBlocks(from: content)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ForEach(Array(cachedBlocks.enumerated()), id: \.offset) { _, block in
                switch block {
                case .text(let text):
                    HighlightedMarkdownText(Self.processInlineMath(text), font: .bodyFont(scale))
                case .table(let table):
                    MarkdownTableView(table: table)
                case .code(let code):
                    CodeBlockView(code: code)
                case .list(let items):
                    ListBlockView(items: items)
                case .math(let expr):
                    MathBlockView(expression: expr)
                case .blockquote(let text):
                    BlockquoteView(text: text)
                case .horizontalRule:
                    Divider().opacity(0.5)
                case .heading(let text, let level):
                    HeadingView(text: text, level: level)
                }
            }
        }
    }

    /// Replace inline $...$ math with code style for display
    static func processInlineMath(_ text: String) -> String {
        let result = text
        // Match $...$ but not $$...$$ — use a simple scan approach
        var output = ""
        var idx = result.startIndex
        while idx < result.endIndex {
            if result[idx] == "$" {
                let next = result.index(after: idx)
                // Skip $$ (display math handled separately)
                if next < result.endIndex && result[next] == "$" {
                    output.append(result[idx])
                    idx = next
                    output.append(result[idx])
                    idx = result.index(after: idx)
                    continue
                }
                // Find closing $
                if let closeIdx = result[next...].firstIndex(of: "$") {
                    let math = String(result[next..<closeIdx])
                    let converted = LaTeXConverter.convert(math)
                    output.append(contentsOf: "`\(converted)`")
                    idx = result.index(after: closeIdx)
                    continue
                }
            }
            output.append(result[idx])
            idx = result.index(after: idx)
        }
        return output
    }

    private static let listPattern = try! NSRegularExpression(pattern: #"^(\s*)([-*•]|\d+[.)]) (\[[ xX]\] )?"#)

    private static func isListLine(_ line: String) -> Bool {
        let range = NSRange(line.startIndex..., in: line)
        return listPattern.firstMatch(in: line, range: range) != nil
    }

    private static func parseListItem(_ line: String) -> ListItem {
        let trimmed = line.replacingOccurrences(of: "^\t", with: "    ", options: .regularExpression)
        let stripped = trimmed.drop(while: { $0 == " " })
        let indent = trimmed.count - stripped.count
        let level = indent / 2

        // Remove the bullet/number prefix and detect task checkboxes
        var text = String(stripped)
        if let range = text.range(of: #"^([-*•]|\d+[.)]) "#, options: .regularExpression) {
            let prefix = text[range]
            let isOrdered = prefix.first?.isNumber == true
            text = String(text[range.upperBound...])

            // Check for task list checkbox: [ ] or [x] or [X]
            var checkState: Bool? = nil
            if let checkRange = text.range(of: #"^\[[ xX]\] "#, options: .regularExpression) {
                let checkMark = text[checkRange]
                checkState = checkMark.contains("x") || checkMark.contains("X")
                text = String(text[checkRange.upperBound...])
            }

            return ListItem(text: text, level: level, isOrdered: isOrdered, checkState: checkState)
        }
        return ListItem(text: text, level: level, isOrdered: false, checkState: nil)
    }

    private static func parseBlocks(from content: String) -> [ContentBlock] {
        var blocks: [ContentBlock] = []
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

            // Detect fenced code block: line starts with ```
            if trimmed.hasPrefix("```") {
                flushText()
                i += 1
                var codeLines: [String] = []
                while i < lines.count {
                    let cl = lines[i]
                    if cl.trimmingCharacters(in: .whitespaces).hasPrefix("```") {
                        i += 1
                        break
                    }
                    codeLines.append(cl)
                    i += 1
                }
                blocks.append(.code(codeLines.joined(separator: "\n")))

            // Detect display math: $$
            } else if trimmed.hasPrefix("$$") {
                flushText()
                if trimmed.count > 2 && trimmed.hasSuffix("$$") && trimmed.count > 4 {
                    // Single-line $$...$$
                    let math = String(trimmed.dropFirst(2).dropLast(2))
                    blocks.append(.math(math))
                    i += 1
                } else {
                    i += 1
                    var mathLines: [String] = []
                    while i < lines.count {
                        let ml = lines[i].trimmingCharacters(in: .whitespaces)
                        if ml.hasSuffix("$$") {
                            if ml != "$$" {
                                mathLines.append(String(ml.dropLast(2)))
                            }
                            i += 1
                            break
                        }
                        mathLines.append(lines[i])
                        i += 1
                    }
                    blocks.append(.math(mathLines.joined(separator: "\n")))
                }

            // Detect table
            } else if trimmed.hasPrefix("|") && trimmed.filter({ $0 == "|" }).count >= 2 {
                flushText()
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

            // Detect horizontal rule: ---, ***, ___
            } else if trimmed.count >= 3 && (
                trimmed.allSatisfy({ $0 == "-" || $0 == " " }) && trimmed.filter({ $0 == "-" }).count >= 3 ||
                trimmed.allSatisfy({ $0 == "*" || $0 == " " }) && trimmed.filter({ $0 == "*" }).count >= 3 ||
                trimmed.allSatisfy({ $0 == "_" || $0 == " " }) && trimmed.filter({ $0 == "_" }).count >= 3
            ) {
                flushText()
                blocks.append(.horizontalRule)
                i += 1

            // Detect blockquote: > text
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
                    } else {
                        break
                    }
                }
                blocks.append(.blockquote(quoteLines.joined(separator: "\n")))

            // Detect headings: # through ######
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

            // Detect list items
            } else if Self.isListLine(line) {
                flushText()
                var items: [ListItem] = []
                while i < lines.count && Self.isListLine(lines[i]) {
                    items.append(Self.parseListItem(lines[i]))
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

    private static func parseTable(_ lines: [String]) -> ParsedTable? {
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
        case list([ListItem])
        case math(String)
        case blockquote(String)
        case horizontalRule
        case heading(String, Int) // text, level 1-6
    }
}

struct ListItem {
    let text: String
    let level: Int
    let isOrdered: Bool
    let checkState: Bool? // nil = normal, false = unchecked, true = checked
}

struct ListBlockView: View {
    let items: [ListItem]
    @Environment(\.fontScale) private var scale

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            ForEach(Array(items.enumerated()), id: \.offset) { idx, item in
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    if let checked = item.checkState {
                        Image(systemName: checked ? "checkmark.square.fill" : "square")
                            .font(.bodyFont(scale))
                            .foregroundColor(checked ? .green : .secondary)
                            .frame(minWidth: 14, alignment: .trailing)
                    } else {
                        Text(item.isOrdered ? "\(ordinalNumber(idx, item))." : "•")
                            .font(.bodyFont(scale))
                            .foregroundColor(.secondary)
                            .frame(minWidth: 14, alignment: .trailing)
                    }

                    HighlightedMarkdownText(item.text, font: .bodyFont(scale))
                        .strikethrough(item.checkState == true, color: .secondary)
                }
                .padding(.leading, CGFloat(item.level) * 16)
            }
        }
    }

    // Compute the ordinal number within consecutive ordered items at the same level
    private func ordinalNumber(_ index: Int, _ item: ListItem) -> Int {
        var n = 1
        var i = index - 1
        while i >= 0 && items[i].isOrdered && items[i].level == item.level {
            n += 1
            i -= 1
        }
        return n
    }
}

// MARK: - LaTeX to Unicode Converter

enum LaTeXConverter {
    private static let symbols: [String: String] = [
        // Greek lowercase
        "\\alpha": "α", "\\beta": "β", "\\gamma": "γ", "\\delta": "δ",
        "\\epsilon": "ε", "\\varepsilon": "ε", "\\zeta": "ζ", "\\eta": "η",
        "\\theta": "θ", "\\vartheta": "ϑ", "\\iota": "ι", "\\kappa": "κ",
        "\\lambda": "λ", "\\mu": "μ", "\\nu": "ν", "\\xi": "ξ",
        "\\pi": "π", "\\varpi": "ϖ", "\\rho": "ρ", "\\varrho": "ϱ",
        "\\sigma": "σ", "\\varsigma": "ς", "\\tau": "τ", "\\upsilon": "υ",
        "\\phi": "φ", "\\varphi": "φ", "\\chi": "χ", "\\psi": "ψ", "\\omega": "ω",
        // Greek uppercase
        "\\Gamma": "Γ", "\\Delta": "Δ", "\\Theta": "Θ", "\\Lambda": "Λ",
        "\\Xi": "Ξ", "\\Pi": "Π", "\\Sigma": "Σ", "\\Upsilon": "Υ",
        "\\Phi": "Φ", "\\Psi": "Ψ", "\\Omega": "Ω",
        // Operators
        "\\int": "∫", "\\iint": "∬", "\\iiint": "∭", "\\oint": "∮",
        "\\sum": "∑", "\\prod": "∏", "\\coprod": "∐",
        "\\partial": "∂", "\\nabla": "∇", "\\infty": "∞",
        "\\pm": "±", "\\mp": "∓", "\\times": "×", "\\div": "÷", "\\cdot": "·",
        "\\ast": "∗", "\\star": "⋆", "\\circ": "∘", "\\bullet": "•",
        // Relations
        "\\leq": "≤", "\\le": "≤", "\\geq": "≥", "\\ge": "≥",
        "\\neq": "≠", "\\ne": "≠", "\\approx": "≈", "\\equiv": "≡",
        "\\sim": "∼", "\\simeq": "≃", "\\cong": "≅", "\\propto": "∝",
        "\\ll": "≪", "\\gg": "≫", "\\prec": "≺", "\\succ": "≻",
        // Set theory
        "\\in": "∈", "\\notin": "∉", "\\ni": "∋", "\\subset": "⊂",
        "\\supset": "⊃", "\\subseteq": "⊆", "\\supseteq": "⊇",
        "\\cup": "∪", "\\cap": "∩", "\\emptyset": "∅", "\\varnothing": "∅",
        // Logic
        "\\forall": "∀", "\\exists": "∃", "\\nexists": "∄",
        "\\land": "∧", "\\lor": "∨", "\\lnot": "¬", "\\neg": "¬",
        "\\implies": "⟹", "\\iff": "⟺", "\\to": "→", "\\gets": "←",
        "\\Rightarrow": "⇒", "\\Leftarrow": "⇐", "\\Leftrightarrow": "⇔",
        "\\rightarrow": "→", "\\leftarrow": "←", "\\leftrightarrow": "↔",
        "\\mapsto": "↦", "\\longmapsto": "⟼",
        // Misc
        "\\ldots": "…", "\\cdots": "⋯", "\\vdots": "⋮", "\\ddots": "⋱",
        "\\aleph": "ℵ", "\\hbar": "ℏ", "\\ell": "ℓ", "\\wp": "℘",
        "\\Re": "ℜ", "\\Im": "ℑ", "\\angle": "∠", "\\triangle": "△",
        "\\perp": "⊥", "\\parallel": "∥", "\\mid": "∣",
        "\\langle": "⟨", "\\rangle": "⟩",
        "\\lceil": "⌈", "\\rceil": "⌉", "\\lfloor": "⌊", "\\rfloor": "⌋",
        "\\quad": " ", "\\qquad": "  ", "\\,": " ", "\\;": " ", "\\:": " ",
        "\\left": "", "\\right": "", "\\big": "", "\\Big": "", "\\bigg": "", "\\Bigg": "",
        "\\mathrm": "", "\\mathbf": "", "\\mathit": "", "\\mathcal": "", "\\text": "",
    ]

    private static let superscripts: [Character: Character] = [
        "0": "⁰", "1": "¹", "2": "²", "3": "³", "4": "⁴",
        "5": "⁵", "6": "⁶", "7": "⁷", "8": "⁸", "9": "⁹",
        "+": "⁺", "-": "⁻", "=": "⁼", "(": "⁽", ")": "⁾",
        "n": "ⁿ", "i": "ⁱ", "a": "ᵃ", "b": "ᵇ", "c": "ᶜ",
        "d": "ᵈ", "e": "ᵉ", "k": "ᵏ", "m": "ᵐ", "p": "ᵖ",
        "t": "ᵗ", "x": "ˣ",
    ]

    private static let subscripts: [Character: Character] = [
        "0": "₀", "1": "₁", "2": "₂", "3": "₃", "4": "₄",
        "5": "₅", "6": "₆", "7": "₇", "8": "₈", "9": "₉",
        "+": "₊", "-": "₋", "=": "₌", "(": "₍", ")": "₎",
        "a": "ₐ", "e": "ₑ", "i": "ᵢ", "j": "ⱼ", "k": "ₖ",
        "n": "ₙ", "o": "ₒ", "p": "ₚ", "r": "ᵣ", "s": "ₛ",
        "t": "ₜ", "u": "ᵤ", "x": "ₓ",
    ]

    static func convert(_ latex: String) -> String {
        var s = latex.trimmingCharacters(in: .whitespacesAndNewlines)

        // Handle \sqrt{...}
        s = s.replacingOccurrences(
            of: #"\\sqrt\{([^}]*)\}"#, with: "√($1)", options: .regularExpression)
        s = s.replacingOccurrences(
            of: #"\\sqrt\b"#, with: "√", options: .regularExpression)

        // Handle \frac{a}{b} -> a/b
        s = s.replacingOccurrences(
            of: #"\\frac\{([^}]*)\}\{([^}]*)\}"#, with: "($1)/($2)", options: .regularExpression)

        // Handle \overline{x} -> x̄
        s = s.replacingOccurrences(
            of: #"\\overline\{([^}]*)\}"#, with: "$1\u{0305}", options: .regularExpression)
        s = s.replacingOccurrences(
            of: #"\\bar\{([^}]*)\}"#, with: "$1\u{0305}", options: .regularExpression)
        s = s.replacingOccurrences(
            of: #"\\hat\{([^}]*)\}"#, with: "$1\u{0302}", options: .regularExpression)
        s = s.replacingOccurrences(
            of: #"\\tilde\{([^}]*)\}"#, with: "$1\u{0303}", options: .regularExpression)

        // Replace known symbols (longest first to avoid partial matches)
        let sorted = symbols.keys.sorted { $0.count > $1.count }
        for cmd in sorted {
            s = s.replacingOccurrences(of: cmd, with: symbols[cmd]!)
        }

        // Handle superscripts and subscripts (supports nesting)
        s = processSuperSub(s, marker: "^", map: superscripts)
        s = processSuperSub(s, marker: "_", map: subscripts)

        // Clean up leftover braces from commands like \mathrm{text}
        s = s.replacingOccurrences(of: "{", with: "")
        s = s.replacingOccurrences(of: "}", with: "")

        // Clean up extra spaces
        s = s.replacingOccurrences(
            of: #" {2,}"#, with: " ", options: .regularExpression)

        return s.trimmingCharacters(in: .whitespaces)
    }

    /// Extract a brace-balanced group starting at index (which should point to '{').
    /// Returns the content between braces and the index after the closing '}'.
    private static func extractBraceGroup(_ input: String, from start: String.Index) -> (String, String.Index)? {
        guard start < input.endIndex, input[start] == "{" else { return nil }
        var depth = 1
        var i = input.index(after: start)
        while i < input.endIndex {
            if input[i] == "{" { depth += 1 }
            else if input[i] == "}" {
                depth -= 1
                if depth == 0 {
                    let content = String(input[input.index(after: start)..<i])
                    return (content, input.index(after: i))
                }
            }
            i = input.index(after: i)
        }
        return nil
    }

    // Characters already in Unicode super/subscript form — count as "mapped"
    private static let alreadySuper: Set<Character> = Set("⁰¹²³⁴⁵⁶⁷⁸⁹⁺⁻⁼⁽⁾ⁿⁱᵃᵇᶜᵈᵉᵏᵐᵖᵗˣ")
    private static let alreadySub: Set<Character> = Set("₀₁₂₃₄₅₆₇₈₉₊₋₌₍₎ₐₑᵢⱼₖₙₒₚᵣₛₜᵤₓ")

    /// Check if every character can be mapped (or is already mapped) to super/subscript
    private static func canFullyMap(_ content: String, map: [Character: Character], already: Set<Character>) -> Bool {
        content.allSatisfy { map[$0] != nil || already.contains($0) }
    }

    /// Convert a string using the super/subscript character map.
    private static func mapChars(_ content: String, map: [Character: Character]) -> String {
        String(content.map { map[$0] ?? $0 })
    }

    private static func processSuperSub(_ input: String, marker: String, map: [Character: Character]) -> String {
        let markerChar = Character(marker)
        let already = marker == "^" ? alreadySuper : alreadySub
        var result = ""
        var i = input.startIndex
        while i < input.endIndex {
            if input[i] == markerChar {
                let next = input.index(after: i)
                guard next < input.endIndex else {
                    result.append(input[i])
                    i = next
                    continue
                }
                if input[next] == "{" {
                    if let (content, afterClose) = extractBraceGroup(input, from: next) {
                        // Recursively process nested ^/_ inside the group
                        let processed = processSuperSub(content, marker: marker, map: map)
                        if canFullyMap(processed, map: map, already: already) {
                            // All chars mappable — clean Unicode
                            result.append(contentsOf: mapChars(processed, map: map))
                        } else {
                            // Has unmappable chars — use marker + parens
                            result.append(contentsOf: "\(marker)(\(processed))")
                        }
                        i = afterClose
                        continue
                    }
                } else {
                    // Single character after marker
                    let ch = input[next]
                    if let mapped = map[ch] {
                        result.append(mapped)
                    } else {
                        result.append(markerChar)
                        result.append(ch)
                    }
                    i = input.index(after: next)
                    continue
                }
            }
            result.append(input[i])
            i = input.index(after: i)
        }
        return result
    }
}

struct MathBlockView: View {
    let expression: String
    @Environment(\.fontScale) private var scale
    @Environment(\.colorScheme) private var colorScheme
    @State private var contentHeight: CGFloat = 44

    var body: some View {
        KaTeXView(expression: expression, fontSize: 18 * scale,
                  colorScheme: colorScheme, measuredHeight: $contentHeight)
            .frame(height: contentHeight)
            .frame(maxWidth: .infinity)
            .background(Color(NSColor.windowBackgroundColor).opacity(0.4))
            .overlay(
                RoundedRectangle(cornerRadius: 6)
                    .stroke(Color.secondary.opacity(0.15), lineWidth: 0.5)
            )
            .clipShape(RoundedRectangle(cornerRadius: 6))
    }
}

import WebKit

struct KaTeXView: NSViewRepresentable {
    let expression: String
    let fontSize: CGFloat
    let colorScheme: ColorScheme
    @Binding var measuredHeight: CGFloat

    func makeNSView(context: Context) -> WKWebView {
        let config = WKWebViewConfiguration()
        let handler = context.coordinator
        config.userContentController.add(handler, name: "sizeChange")
        let webView = WKWebView(frame: NSRect(x: 0, y: 0, width: 400, height: 1), configuration: config)
        webView.navigationDelegate = handler
        webView.setValue(false, forKey: "drawsBackground")
        handler.heightBinding = $measuredHeight
        loadKaTeX(webView)
        return webView
    }

    func updateNSView(_ webView: WKWebView, context: Context) {
        let prev = context.coordinator
        if prev.lastExpression != expression || prev.lastFontSize != fontSize || prev.lastColorScheme != colorScheme {
            prev.lastExpression = expression
            prev.lastFontSize = fontSize
            prev.lastColorScheme = colorScheme
            loadKaTeX(webView)
        }
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    private func loadKaTeX(_ webView: WKWebView) {
        let escaped = expression
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "'", with: "\\'")
            .replacingOccurrences(of: "\n", with: "\\n")
        let textColor = colorScheme == .dark ? "#e0e0e0" : "#1a1a1a"

        let html = """
        <!DOCTYPE html>
        <html>
        <head>
        <meta charset="utf-8">
        <link rel="stylesheet" href="https://cdn.jsdelivr.net/npm/katex@0.16.11/dist/katex.min.css">
        <script src="https://cdn.jsdelivr.net/npm/katex@0.16.11/dist/katex.min.js"></script>
        <style>
            body {
                margin: 0; padding: 8px 10px;
                background: transparent;
                color: \(textColor);
                display: inline-block;
            }
            .katex { font-size: \(fontSize)px; }
        </style>
        </head>
        <body>
        <div id="math"></div>
        <script>
            try {
                katex.render('\(escaped)', document.getElementById('math'), {
                    displayMode: true,
                    throwOnError: false,
                    output: 'html'
                });
            } catch(e) {
                document.getElementById('math').textContent = '\(escaped)';
            }
            function reportSize() {
                var h = document.body.scrollHeight;
                if (h > 0) {
                    window.webkit.messageHandlers.sizeChange.postMessage(String(h));
                }
            }
            reportSize();
            new ResizeObserver(reportSize).observe(document.body);
            // Also report after fonts load
            document.fonts.ready.then(reportSize);
        </script>
        </body>
        </html>
        """
        webView.loadHTMLString(html, baseURL: nil)
    }

    class Coordinator: NSObject, WKNavigationDelegate, WKScriptMessageHandler {
        var lastExpression = ""
        var lastFontSize: CGFloat = 0
        var lastColorScheme: ColorScheme = .dark
        var heightBinding: Binding<CGFloat>?

        func userContentController(_ userContentController: WKUserContentController,
                                   didReceive message: WKScriptMessage) {
            if let str = message.body as? String, let h = Double(str), h > 0 {
                DispatchQueue.main.async {
                    self.heightBinding?.wrappedValue = CGFloat(h)
                }
            }
        }

        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            // Fallback: measure via JS after page loads
            webView.evaluateJavaScript("document.body.scrollHeight") { result, _ in
                if let h = result as? CGFloat, h > 0 {
                    DispatchQueue.main.async {
                        self.heightBinding?.wrappedValue = h
                    }
                }
            }
        }
    }
}

struct HeadingView: View {
    let text: String
    let level: Int
    @Environment(\.fontScale) private var scale

    private var size: CGFloat {
        switch level {
        case 1: return 24
        case 2: return 21
        case 3: return 18
        default: return 16
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(LocalizedStringKey(text))
                .font(.custom("Fira Sans", size: size * scale).weight(level <= 2 ? .bold : .semibold))
                .textSelection(.enabled)
            if level <= 2 {
                Divider().opacity(0.3)
            }
        }
    }
}

struct BlockquoteView: View {
    let text: String
    @Environment(\.fontScale) private var scale

    var body: some View {
        HStack(spacing: 0) {
            RoundedRectangle(cornerRadius: 1)
                .fill(Color.secondary.opacity(0.4))
                .frame(width: 3)

            HighlightedMarkdownText(text, font: .bodyFont(scale))
                .italic()
                .foregroundColor(.secondary)
                .padding(.leading, 10)
        }
    }
}

struct CodeBlockView: View {
    let code: String
    @Environment(\.fontScale) private var scale

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            Text(code)
                .font(.codeFont(scale))
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
    @Environment(\.fontScale) private var scale

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Header row
            HStack(spacing: 0) {
                ForEach(Array(table.headers.enumerated()), id: \.offset) { _, header in
                    Text(LocalizedStringKey(header))
                        .font(.bodySemibold(scale))
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
                            .font(.smallFont(scale))
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
