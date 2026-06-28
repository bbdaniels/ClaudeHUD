import Foundation

// MARK: - Phase 3 (ASK-YOU spine) — relay request model + Block Kit cards
//
// The supervisory spine parks a live `claude -p` turn on a Slack round-trip. The
// turn's bundled MCP server (`hud-slack-mcp.py`) writes a REQUEST json to the
// relay dir and blocks on a matching DECISION json; ClaudeHUD watches the relay,
// renders the request as a Block Kit card, and writes the decision when the
// operator taps a button (or replies in-thread, per the precedence rule). This
// file holds the PURE pieces of that contract — request decoding, decision
// encoding, and the card builders — so the stateful wiring (parked-prompt
// registry, watcher timer, generation hygiene, timeout sweep) stays in
// `SlackService`, which owns the posting + lifecycle.

/// The kind of supervisory pause a relay request represents. Mirrors the
/// `kind` the MCP server stamps: an ambiguity question (3.1), a gated permission
/// (3.2), or a plan-approval gate (3.3).
enum HudPromptKind: String {
    case ask        // clarifying question (AskUserQuestion-shaped)
    case approve    // risk-gated permission
    case plan       // ExitPlanMode approval
    case budget     // reserved for 3.5 (budget guardrail)
}

/// One option in a clarifying question (3.1): a short label + a one-line gloss.
struct HudQuestionOption {
    let label: String
    let description: String
}

/// One clarifying question (an `AskUserQuestion` element mapped 1:1).
struct HudQuestion {
    let header: String
    let question: String
    let multiSelect: Bool
    let options: [HudQuestionOption]
}

/// A decoded relay request. `payload` is kept raw so the kind-specific decoders
/// (`questions`, `toolName`/`input`, `planText`) can pull what they need.
struct SupervisorRequest {
    let id: String
    let kind: HudPromptKind
    let channel: String
    let generation: Int
    let cwd: String
    let reason: String?
    let payload: [String: Any]

    init?(json: [String: Any]) {
        guard let id = json["id"] as? String,
              let kindRaw = json["kind"] as? String,
              let kind = HudPromptKind(rawValue: kindRaw) else { return nil }
        self.id = id
        self.kind = kind
        self.channel = json["channel"] as? String ?? ""
        // Generation is stamped as a string in the mcp-config env.
        if let g = json["generation"] as? Int { self.generation = g }
        else if let s = json["generation"] as? String, let g = Int(s) { self.generation = g }
        else { self.generation = 0 }
        self.cwd = json["cwd"] as? String ?? ""
        self.reason = json["reason"] as? String
        self.payload = json["payload"] as? [String: Any] ?? [:]
    }

    /// Clarifying-question payload (3.1).
    var questions: [HudQuestion] {
        guard let raw = payload["questions"] as? [[String: Any]] else { return [] }
        return raw.map { q in
            let opts = (q["options"] as? [[String: Any]] ?? []).map {
                HudQuestionOption(label: $0["label"] as? String ?? "Option",
                                  description: $0["description"] as? String ?? "")
            }
            return HudQuestion(header: q["header"] as? String ?? "Question",
                               question: q["question"] as? String ?? "",
                               multiSelect: q["multiSelect"] as? Bool ?? false,
                               options: opts)
        }
    }

    /// Permission payload (3.2 / 3.3).
    var toolName: String { payload["tool_name"] as? String ?? "" }
    var toolInput: [String: Any] { payload["input"] as? [String: Any] ?? [:] }

    /// A short, verbatim rendering of the gated action for the approval card.
    var actionPreview: String {
        switch toolName {
        case "Bash":
            return toolInput["command"] as? String ?? ""
        case "Edit", "Write", "MultiEdit":
            return toolInput["file_path"] as? String ?? ""
        case "NotebookEdit":
            return toolInput["notebook_path"] as? String ?? ""
        case "WebFetch", "WebSearch":
            return (toolInput["url"] as? String) ?? (toolInput["query"] as? String) ?? ""
        default:
            if let data = try? JSONSerialization.data(withJSONObject: toolInput, options: [.sortedKeys]),
               let s = String(data: data, encoding: .utf8) { return s }
            return ""
        }
    }

    /// Plan text for the ExitPlanMode card (3.3).
    var planText: String {
        (toolInput["plan"] as? String) ?? (payload["plan"] as? String) ?? ""
    }
}

// MARK: - Decision encoding (what ClaudeHUD writes back to the relay)

/// Builders for the decision JSON the MCP server is blocked on. `approve` returns
/// a PermissionResult; `ask` returns the chosen answers.
enum SupervisorDecision {
    static func allow() -> [String: Any] { ["behavior": "allow"] }
    static func deny(_ message: String) -> [String: Any] {
        ["behavior": "deny", "message": message]
    }
    /// Clarifying-question answers, one per question (header + chosen text).
    static func answers(_ pairs: [(header: String, answer: String)]) -> [String: Any] {
        ["answers": pairs.map { ["header": $0.header, "answer": $0.answer] }]
    }
}

// MARK: - Block Kit cards

/// The supervisory cards rendered into a turn's THREAD. Each carries the prompt
/// id in every button `value` so the interactive dispatch resolves exactly the
/// parked RPC it belongs to (generation hygiene, 3.4, is checked in `SlackService`
/// against the parked prompt's stored generation).
enum SupervisorCards {
    /// Slack button text ceiling.
    private static let buttonCap = 70

    /// 3.1 — the clarifying-question poll. One button per option for single-select
    /// (taps resolve immediately, zero recall); checkboxes + Submit for
    /// multi-select. A "Let me type it" button opens the freeform modal. `qIndex`
    /// scopes the buttons when an ask carries more than one question.
    static func questionCard(promptId: String, questions: [HudQuestion]) -> [[String: Any]] {
        var blocks: [[String: Any]] = []
        blocks.append(SlackBlocks.section(":raising_hand:  *I need a decision before continuing.*"))
        for (qi, q) in questions.enumerated() {
            blocks.append(SlackBlocks.divider())
            blocks.append(SlackBlocks.section("*\(q.header)*\n\(q.question)"))
            if q.multiSelect {
                // Checkboxes capture multiple; Submit reads message state.values.
                let options = q.options.enumerated().map { (oi, opt) -> [String: Any] in
                    [
                        "text": ["type": "mrkdwn", "text": "*\(opt.label)*"],
                        "description": ["type": "mrkdwn",
                                        "text": SlackBlocks.truncate(opt.description, 200)],
                        "value": "\(promptId)|\(qi)|\(oi)"
                    ]
                }
                blocks.append([
                    "type": "actions",
                    "block_id": "ask:\(promptId):\(qi)",
                    "elements": [[
                        "type": "checkboxes",
                        "action_id": SlackAction.answerOption,
                        "options": options
                    ]]
                ])
            } else {
                // One button per option — the operator taps and it resolves.
                var buttons = q.options.enumerated().map { (oi, opt) -> [String: Any] in
                    SlackBlocks.button(text: SlackBlocks.truncate(opt.label, buttonCap),
                                       actionId: SlackAction.answerOption,
                                       value: "\(promptId)|\(qi)|\(oi)")
                }
                buttons.append(SlackBlocks.button(text: ":pencil2: Let me type it",
                                                  actionId: SlackAction.answerCustom,
                                                  value: "\(promptId)|\(qi)"))
                blocks.append(["type": "actions",
                               "block_id": "ask:\(promptId):\(qi)",
                               "elements": buttons])
                // The option descriptions, as a context line under the buttons.
                let gloss = q.options.map { "*\($0.label)* — \($0.description)" }
                    .joined(separator: "\n")
                if !gloss.isEmpty { blocks.append(SlackBlocks.context(gloss)) }
            }
        }
        // For any multi-select question, a Submit resolves from message state.
        if questions.contains(where: { $0.multiSelect }) {
            blocks.append(SlackBlocks.actions([
                SlackBlocks.button(text: "Submit", actionId: SlackAction.answerSubmit,
                                   value: promptId, style: "primary")
            ]))
        }
        blocks.append(SlackBlocks.context("or reply in-thread to answer in words"))
        return blocks
    }

    /// 3.2 — the risk-tiered permission card. The gated action is shown verbatim
    /// (size-capped); the verbs are the anti-fatigue levers.
    static func approvalCard(promptId: String, toolName: String,
                             preview: String, cwd: String, reason: String?) -> [[String: Any]] {
        var blocks: [[String: Any]] = []
        blocks.append(SlackBlocks.section(":lock:  *Approval needed*"))
        if let reason, !reason.isEmpty {
            blocks.append(SlackBlocks.context("Why gated: \(reason)"))
        }
        let label = toolName == "Bash" ? "Run in terminal:" : "\(toolName):"
        let shown = SlackBlocks.truncate(preview, 1500)
        blocks.append(SlackBlocks.section("\(label)\n```\n\(shown)\n```"))
        if !cwd.isEmpty {
            blocks.append(SlackBlocks.context("Working dir: `\(cwd)`"))
        }
        // "Approve & always allow X here" — X is the tool name (the sanctioned
        // writer of a settings rule). Hidden for tools where an always-rule makes
        // no sense (network/destructive stay one-shot).
        var buttons: [[String: Any]] = [
            SlackBlocks.button(text: ":white_check_mark: Approve",
                               actionId: SlackAction.approveAllow, value: promptId, style: "primary")
        ]
        if toolName == "Bash" || toolName == "Edit" || toolName == "Write" || toolName == "MultiEdit" {
            buttons.append(SlackBlocks.button(text: "Approve & always allow \(toolName) here",
                                              actionId: SlackAction.approveAlways, value: promptId))
        }
        buttons.append(SlackBlocks.button(text: ":no_entry: Deny",
                                          actionId: SlackAction.approveDeny, value: promptId, style: "danger"))
        buttons.append(SlackBlocks.button(text: ":pencil2: Deny with note…",
                                          actionId: SlackAction.approveDenyNote, value: promptId))
        blocks.append(SlackBlocks.actions(buttons))
        return blocks
    }

    /// 3.5 — the turn-cap card (NO dollars). The engine hit the per-channel turn
    /// guardrail and stopped with partial work; the operator decides whether to
    /// raise the cap and continue or stop here. `key` is the channel id (the
    /// Continue handler re-spawns `--resume` with a raised cap).
    static func turnCapCard(channelId: String, cap: Int, addend: Int,
                            doneSoFar: String) -> [[String: Any]] {
        var blocks: [[String: Any]] = []
        blocks.append(SlackBlocks.section(
            ":vertical_traffic_light:  *Hit the turn cap (\(cap) turn\(cap == 1 ? "" : "s"))*  ·  paused"))
        if !doneSoFar.isEmpty {
            blocks.append(SlackBlocks.section("Done so far: \(SlackBlocks.truncate(doneSoFar, 1500))"))
        }
        blocks.append(SlackBlocks.context(
            "The agent reached its turn budget for this run. Continue to let it keep going, or stop here — partial work is kept either way."))
        blocks.append(SlackBlocks.actions([
            SlackBlocks.button(text: ":arrows_counterclockwise: Continue +\(addend) turns",
                               actionId: SlackAction.budgetContinue, value: channelId, style: "primary"),
            SlackBlocks.button(text: ":black_square_for_stop: Stop here",
                               actionId: SlackAction.budgetStop, value: channelId)
        ]))
        return blocks
    }

    /// 3.5 — the usage-window pre-flight gate (NO dollars). The shared
    /// subscription 5-hour window is near-exhausted, so rather than launch into a
    /// likely rate-limit rejection we surface the headroom and ask. `key` is the
    /// channel id.
    static func usageGateCard(channelId: String, utilizationPct: Int,
                              resetsHint: String) -> [[String: Any]] {
        var blocks: [[String: Any]] = []
        blocks.append(SlackBlocks.section(
            ":battery:  *Usage window nearly exhausted*  ·  \(utilizationPct)% used"))
        let reset = resetsHint.isEmpty ? "" : " It resets \(resetsHint)."
        blocks.append(SlackBlocks.context(
            "Your Claude subscription 5-hour window is at \(utilizationPct)%.\(reset) Launching now may hit a rate limit mid-turn."))
        blocks.append(SlackBlocks.actions([
            SlackBlocks.button(text: ":arrow_forward: Run anyway",
                               actionId: SlackAction.usageRunAnyway, value: channelId, style: "primary"),
            SlackBlocks.button(text: ":hourglass: Wait",
                               actionId: SlackAction.usageWait, value: channelId)
        ]))
        return blocks
    }

    /// 3.3 — the ExitPlanMode approval card.
    static func planCard(promptId: String, plan: String) -> [[String: Any]] {
        var blocks: [[String: Any]] = []
        blocks.append(SlackBlocks.section(":clipboard:  *Plan ready — approve to execute*"))
        let shown = SlackBlocks.truncate(plan.isEmpty ? "_(no plan text provided)_" : plan, 2500)
        blocks.append(SlackBlocks.section(shown))
        blocks.append(SlackBlocks.actions([
            SlackBlocks.button(text: ":white_check_mark: Approve plan",
                               actionId: SlackAction.planApprove, value: promptId, style: "primary"),
            SlackBlocks.button(text: ":pencil2: Edit plan…",
                               actionId: SlackAction.planEdit, value: promptId),
            SlackBlocks.button(text: ":no_entry: Reject",
                               actionId: SlackAction.planReject, value: promptId, style: "danger")
        ]))
        return blocks
    }
}
