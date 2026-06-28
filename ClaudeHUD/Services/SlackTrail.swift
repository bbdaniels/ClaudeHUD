import Foundation

// MARK: - Phase 2.1/2.2: semantic activity trail + thinking surfacing
//
// The trail is the in-THREAD work surface (Plan §2.1): one `chat.update`-d
// message per turn that carries SEMANTIC lines ("Editing robustness.do", not
// `Edit(file_path=…)`), grouped read-only noise, and a single collapsed
// thinking line (§2.2). It NEVER carries raw token streaming and NEVER puts raw
// tool I/O or reasoning into the channel root — the bytes live behind a
// "Show details" / "Show reasoning" affordance and only render on demand.
//
// The granularity ladder (Plan §2.1):
//   - channel root (elsewhere): terse status only.
//   - thread (here): semantic events. Write/exec/network/subagent tools render
//     prominently as their own status line; pure local reads (Read/Grep/Glob/…)
//     collapse into one subtle grouped count line.
//   - on-demand (here): full tool input/output behind "Show details" (a modal),
//     full reasoning behind "Show reasoning" (inline expand, or a modal if long).
//
// One message, not N: status verbs transform in place rather than spamming the
// thread. `toolResult` closes each line by `tool_use_id`.

enum TrailStatus {
    case running
    case done
    case error

    var glyph: String {
        switch self {
        case .running: return "⟳"
        case .done:    return "✓"
        case .error:   return "✗"
        }
    }
}

/// Live, mutable state of one turn's activity trail. Reference type so the
/// stream-event closure and the debounced renderer mutate the same record.
/// MainActor-confined (only ever touched from `SlackService`'s MainActor).
@MainActor
final class TurnTrail {
    let channelId: String
    /// The turn's root ts — the trail is posted as a reply in this thread and is
    /// also the key the Show-details / Show-reasoning buttons carry.
    let rootTs: String
    /// ts of the single trail message once posted (then `chat.update`-d in place).
    var threadTs: String?

    // Debounce / reentrancy bookkeeping (Plan §2.1: ~1 update / 2s, well within
    // chat.update's 1-per-3s ceiling).
    var rendering = false
    var dirty = false
    var flushScheduled = false
    var lastRenderedAt: Date = .distantPast
    /// Turn reached a terminal render; running entries flip to done.
    var finished = false
    /// Reasoning is currently expanded inline (toggled by Show/Hide reasoning).
    var thinkingExpanded = false

    struct Entry {
        let toolId: String
        let tool: String
        let semantic: String
        /// Pure local read (Read/Grep/Glob/LS/NotebookRead): rendered subtly,
        /// grouped into a single count line rather than its own status line.
        let subtle: Bool
        /// Non-nil ⇒ this action was issued inside a spawned subagent (depth-1).
        let parentToolUseId: String?
        var status: TrailStatus
        /// Size-capped, secret-redacted raw I/O for the Show-details modal only.
        let rawInput: String
        var rawOutput: String?
    }

    private(set) var entries: [Entry] = []
    private var indexById: [String: Int] = [:]
    /// Collapsed reasoning summaries (one per `thinking` block), joined on expand.
    private(set) var thinking: [String] = []
    /// Distinct Task spawns seen this turn (drives the "N subagents" header).
    private(set) var subagentSpawns = 0

    init(channelId: String, rootTs: String) {
        self.channelId = channelId
        self.rootTs = rootTs
    }

    // MARK: - Mutation

    func addToolUse(_ t: CLIToolUseEvent) {
        if t.toolName == "Task" { subagentSpawns += 1 }
        let subtle = Self.subtleTools.contains(t.toolName)
        let entry = Entry(
            toolId: t.toolId,
            tool: t.toolName,
            semantic: Self.semantic(tool: t.toolName, inputJSON: t.input),
            subtle: subtle,
            parentToolUseId: t.parentToolUseId,
            status: .running,
            rawInput: Self.redactAndCap(t.input, cap: 1800),
            rawOutput: nil
        )
        indexById[t.toolId] = entries.count
        entries.append(entry)
    }

    /// Close the matching open line when its tool_result arrives (keyed by id).
    func closeResult(_ r: CLIToolResultEvent) {
        guard let i = indexById[r.toolId] else { return }
        entries[i].status = r.isError ? .error : .done
        entries[i].rawOutput = Self.redactAndCap(r.content, cap: 1800)
    }

    func addThinking(_ text: String) {
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty else { return }
        thinking.append(t)
    }

    /// Flip any still-open line to done — the turn ended (clean finish).
    func markRunningDone() {
        for i in entries.indices where entries[i].status == .running {
            entries[i].status = .done
        }
    }

    var isEmpty: Bool { entries.isEmpty && thinking.isEmpty }
    var hasThinking: Bool { !thinking.isEmpty }

    /// Full reasoning text (joined), used by Show reasoning.
    var reasoningText: String { thinking.joined(separator: "\n\n") }

    // MARK: - Rendering

    /// Build the trail message's Block Kit blocks. Single message; verbs
    /// transform in place. The control row (Show details / Show reasoning) is the
    /// only path to the bytes.
    func blocks() -> [[String: Any]] {
        var blocks: [[String: Any]] = []

        // Header: a faint provenance/summary line — the root owns the real status.
        let prominent = entries.filter { !$0.subtle }
        let actionCount = entries.count
        var headParts: [String] = []
        headParts.append(finished ? ":memo: *Activity*" : ":gear: *Working*")
        if actionCount > 0 { headParts.append("\(actionCount) action\(actionCount == 1 ? "" : "s")") }
        if subagentSpawns > 0 { headParts.append("\(subagentSpawns) subagent\(subagentSpawns == 1 ? "" : "s")") }
        blocks.append(SlackBlocks.context(headParts.joined(separator: "  ·  ")))

        // Collapsed thinking line (§2.2): never expanded by default, never in the
        // root. Inline-expands into a context block when toggled.
        if hasThinking {
            if thinkingExpanded {
                let r = TurnTrail.redactPlain(reasoningText)
                blocks.append(SlackBlocks.context(":brain: *Reasoning*\n\(SlackBlocks.truncate(r, 2800))"))
            } else {
                blocks.append(SlackBlocks.context(":brain: _Thinking…_  ·  reasoning hidden"))
            }
        }

        // Prominent write/exec/network/subagent lines, each a semantic status row.
        // Cap to the most recent N so the message stays under Slack's block limit.
        if !prominent.isEmpty {
            let maxLines = 14
            let shown = prominent.suffix(maxLines)
            let hidden = prominent.count - shown.count
            var lines: [String] = []
            if hidden > 0 { lines.append("_+\(hidden) earlier action\(hidden == 1 ? "" : "s")_") }
            for e in shown {
                let prefix = e.parentToolUseId != nil ? "↳ " : ""
                lines.append("\(e.status.glyph) \(prefix)\(e.semantic)")
            }
            blocks.append(SlackBlocks.section(lines.joined(separator: "\n")))
        }

        // Subtle reads, grouped into one count line ("Read ×4 · Grep ×2").
        let subtle = entries.filter { $0.subtle }
        if !subtle.isEmpty {
            var counts: [String: Int] = [:]
            for e in subtle { counts[e.tool, default: 0] += 1 }
            let parts = counts.sorted { $0.key < $1.key }
                .map { $0.value > 1 ? "\($0.key) ×\($0.value)" : $0.key }
            blocks.append(SlackBlocks.context(":mag: \(parts.joined(separator: " · "))"))
        }

        // Control row: the only affordance to the bytes / the reasoning.
        var buttons: [[String: Any]] = []
        if entries.contains(where: { $0.rawOutput != nil || !$0.rawInput.isEmpty }) {
            buttons.append(SlackBlocks.button(text: ":file_folder: Show details",
                                              actionId: SlackAction.showDetails, value: rootTs))
        }
        if hasThinking {
            let label = thinkingExpanded ? ":arrow_up_small: Hide reasoning" : ":brain: Show reasoning"
            buttons.append(SlackBlocks.button(text: label,
                                              actionId: SlackAction.showReasoning, value: rootTs))
        }
        if !buttons.isEmpty { blocks.append(SlackBlocks.actions(buttons)) }

        return blocks
    }

    /// Build the Show-details modal view: raw (redacted, capped) tool I/O, the
    /// bytes the thread deliberately keeps collapsed.
    func detailsModalView() -> [String: Any] {
        var blocks: [[String: Any]] = [
            SlackBlocks.context("Raw tool input/output for this turn — secret-redacted and size-capped.")
        ]
        // Cap the number of entries rendered so the modal stays within Slack's
        // 100-block / per-section limits.
        let maxEntries = 20
        let detailed = entries.suffix(maxEntries)
        let hidden = entries.count - detailed.count
        if hidden > 0 {
            blocks.append(SlackBlocks.context("_(showing the most recent \(detailed.count) of \(entries.count) actions)_"))
        }
        for e in detailed {
            blocks.append(SlackBlocks.divider())
            blocks.append(SlackBlocks.section("\(e.status.glyph) *\(e.tool)* — \(e.semantic)"))
            if !e.rawInput.isEmpty, e.rawInput != "{}" {
                blocks.append(SlackBlocks.section("_input_\n```\n\(SlackBlocks.truncate(e.rawInput, 2600))\n```"))
            }
            if let out = e.rawOutput, !out.isEmpty {
                blocks.append(SlackBlocks.section("_output_\n```\n\(SlackBlocks.truncate(out, 2600))\n```"))
            }
        }
        return [
            "type": "modal",
            "callback_id": SlackAction.detailsModal,
            "title": ["type": "plain_text", "text": "Tool details"],
            "close": ["type": "plain_text", "text": "Close"],
            "blocks": Array(blocks.prefix(95))   // hard stay under the 100-block ceiling
        ]
    }

    /// Modal carrying the full reasoning when it overruns a section's inline
    /// limit (§2.2: "or a modal if >3000 chars"). Chunked across sections so
    /// nothing is clipped; redacted like every other byte leaving the machine.
    func reasoningModalView() -> [String: Any] {
        let full = TurnTrail.redactPlain(reasoningText)
        var blocks: [[String: Any]] = [SlackBlocks.context(":brain: Claude's reasoning for this turn")]
        var remaining = Substring(full)
        let chunk = 2800
        while !remaining.isEmpty {
            let end = remaining.index(remaining.startIndex, offsetBy: chunk, limitedBy: remaining.endIndex) ?? remaining.endIndex
            blocks.append(SlackBlocks.section(String(remaining[remaining.startIndex..<end])))
            remaining = remaining[end...]
            if blocks.count >= 95 { break }   // stay under the 100-block ceiling
        }
        return [
            "type": "modal",
            "callback_id": SlackAction.detailsModal,
            "title": ["type": "plain_text", "text": "Reasoning"],
            "close": ["type": "plain_text", "text": "Close"],
            "blocks": blocks
        ]
    }

    // MARK: - Semantic mapping

    /// Pure local reads — rendered subtly and grouped. Everything else
    /// (Edit/Write/Bash/Task/WebFetch/…) renders prominently as its own line.
    static let subtleTools: Set<String> = ["Read", "Grep", "Glob", "LS", "NotebookRead"]

    /// Map a tool name + its JSON input string to a single human-readable verb
    /// phrase. Dynamic substrings (paths, patterns, commands) are redacted so a
    /// secret in an argument never lands in the trail.
    static func semantic(tool: String, inputJSON: String) -> String {
        let input = (try? JSONSerialization.jsonObject(with: Data(inputJSON.utf8))) as? [String: Any] ?? [:]
        func s(_ key: String) -> String? { (input[key] as? String).map(redactPlain) }
        switch tool {
        case "Read":
            return "Reading \(baseName(s("file_path")))"
        case "Edit", "MultiEdit":
            return "Editing \(baseName(s("file_path")))"
        case "Write":
            return "Writing \(baseName(s("file_path")))"
        case "NotebookEdit":
            return "Editing \(baseName(s("notebook_path")))"
        case "Grep":
            return "Grep \(quoted(shorten(s("pattern"), 50)))"
        case "Glob":
            return "Glob \(shorten(s("pattern"), 50))"
        case "LS":
            return "Listing \(baseName(s("path")))"
        case "Bash":
            return "Running \(quoted(shorten(s("command"), 60)))"
        case "Task":
            let d = s("description") ?? s("subagent_type") ?? "subagent"
            return "Spawning subagent: \(shorten(d, 60))"
        case "WebFetch":
            return "Fetching \(host(s("url")))"
        case "WebSearch":
            return "Searching \(quoted(shorten(s("query"), 50)))"
        case "TodoWrite":
            return "Updating todo list"
        default:
            return tool
        }
    }

    private static func baseName(_ path: String?) -> String {
        guard let path, !path.isEmpty else { return "a file" }
        return (path as NSString).lastPathComponent
    }

    private static func host(_ url: String?) -> String {
        guard let url, let u = URL(string: url), let h = u.host else { return shorten(url, 40) }
        return h
    }

    private static func quoted(_ s: String) -> String {
        s.isEmpty ? "" : "`\(s)`"
    }

    private static func shorten(_ s: String?, _ max: Int) -> String {
        guard let s, !s.isEmpty else { return "" }
        let oneLine = s.replacingOccurrences(of: "\n", with: " ")
        return oneLine.count <= max ? oneLine : String(oneLine.prefix(max - 1)) + "…"
    }

    // MARK: - Secret redaction (lightweight; full Security S3 pass lands later)

    /// Redact common credential shapes before any byte leaves the machine into
    /// Slack's cloud. This is the trail's first-line filter; the comprehensive
    /// Security S3 redactor (which also covers diffs / file uploads) is a later
    /// phase. The bot token and ANTHROPIC_API_KEY must never echo into Slack.
    private static let secretPatterns: [NSRegularExpression] = {
        let raws = [
            "xox[baprs]-[A-Za-z0-9-]{10,}",          // Slack tokens
            "sk-[A-Za-z0-9_-]{16,}",                  // OpenAI/Anthropic-style keys
            "ghp_[A-Za-z0-9]{20,}",                   // GitHub PAT
            "gho_[A-Za-z0-9]{20,}",
            "AKIA[0-9A-Z]{12,}",                      // AWS access key id
            "(?i)bearer\\s+[A-Za-z0-9._-]{12,}",      // bearer tokens
            "(?i)(api[_-]?key|secret|password|token)\\s*[:=]\\s*['\"]?[A-Za-z0-9._/+-]{12,}",
            "eyJ[A-Za-z0-9_-]{10,}\\.[A-Za-z0-9_-]{10,}\\.[A-Za-z0-9_-]{6,}"  // JWT
        ]
        return raws.compactMap { try? NSRegularExpression(pattern: $0) }
    }()

    /// Redact secrets from a plain dynamic string (semantic args).
    static func redactPlain(_ s: String) -> String {
        var out = s
        for re in secretPatterns {
            let range = NSRange(out.startIndex..., in: out)
            out = re.stringByReplacingMatches(in: out, range: range, withTemplate: "⟨redacted⟩")
        }
        return out
    }

    /// Redact + hard size-cap a raw I/O blob for the Show-details modal.
    static func redactAndCap(_ s: String, cap: Int) -> String {
        let redacted = redactPlain(s)
        if redacted.count <= cap { return redacted }
        return String(redacted.prefix(cap - 1)) + "…"
    }
}
