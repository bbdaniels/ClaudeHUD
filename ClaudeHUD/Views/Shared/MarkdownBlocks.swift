import SwiftUI

// Shared markdown block renderers and the LaTeX/KaTeX stack. Consumed by
// ObsidianMarkdownView (Today, Projects, VaultManager); split out of the
// deleted chat surface, which was their original home.

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

extension LaTeXConverter {
    /// Replace inline $...$ math with code style for display.
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
}
