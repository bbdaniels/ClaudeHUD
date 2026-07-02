import Foundation

// MARK: - Canonical turn lifecycle (Plan §1.3)

/// The in-flight Working state plus the EXACTLY FIVE visible terminal states a
/// turn must resolve to. The whole point of the lifecycle is that the
/// `:hourglass:` placeholder is never orphaned: every code path that owns a
/// root message drives it to one of these terminal cases (Plan principle 1,
/// §1.3). Later phases PRODUCE the states this enum already RENDERS:
/// `.stopped` from Stop (1.4), `.needsYou` from the ASK-YOU spine (Phase 3),
/// `.interrupted` from crash reconciliation (1.6).
enum TurnState: String {
    case working
    case done
    case failed
    case stopped       // Stopped-by-you (user-triggered abort, a deliberate outcome)
    case needsYou      // Needs-you (paused on a question/permission)
    case interrupted   // Interrupted (app restarted) — process gone, session preserved

    /// Slack emoji shortcode for the status line and the reaction mirror (1.9).
    var icon: String {
        switch self {
        case .working:     return ":hourglass_flowing_sand:"
        case .done:        return ":white_check_mark:"
        case .failed:      return ":x:"
        case .stopped:     return ":black_square_for_stop:"
        case .needsYou:    return ":raising_hand:"
        case .interrupted: return ":warning:"
        }
    }

    /// Human copy shown in the root status line.
    var label: String {
        switch self {
        case .working:     return "Working…"
        case .done:        return "Done"
        case .failed:      return "Failed"
        case .stopped:     return "Stopped by you"
        case .needsYou:    return "Needs you"
        case .interrupted: return "Interrupted (app restarted)"
        }
    }

    var isTerminal: Bool { self != .working }

    /// Bare emoji NAME (no surrounding colons) for the `reactions.add` /
    /// `reactions.remove` status mirror (1.9). Distinct from `icon`, which is a
    /// `:shortcode:` for message text; the reactions API wants the bare name.
    var reactionName: String {
        switch self {
        case .working:     return "hourglass_flowing_sand"
        case .done:        return "white_check_mark"
        case .failed:      return "x"
        case .stopped:     return "black_square_for_stop"
        case .needsYou:    return "raising_hand"
        case .interrupted: return "warning"
        }
    }
}

// MARK: - Stable interactive action scheme (Plan §1.1)

/// Stable `action_id` / `callback_id` strings carried on every Block Kit button
/// and modal. The interactive dispatch routes purely on these constants, never
/// on button TEXT (which is presentational and localizable). Later phases append
/// cases here as new affordances land; the wire contract stays stable.
enum SlackAction {
    // block_actions (buttons)
    static let stop              = "hud:stop"
    static let retry             = "hud:retry"
    static let resume            = "hud:resume"
    static let resumeWithChanges = "hud:resume_with_changes"
    static let feedbackUp        = "hud:feedback:up"
    static let feedbackDown      = "hud:feedback:down"
    // Git checkpoint affordances (1.7) — rendered only when cwd is a git repo.
    // Both carry the turn's root ts in the button `value` as the checkpoint key.
    static let showDiff          = "hud:show_diff"
    static let undoTurn          = "hud:undo"
    // Activity-trail affordances (2.1/2.2) — both carry the turn's root ts in the
    // button `value` to look up the trail. Show details opens the raw-I/O modal;
    // Show reasoning toggles the collapsed thinking line inline (or a modal if long).
    static let showDetails       = "hud:show_details"
    static let showReasoning     = "hud:show_reasoning"
    // Queue vs Steer follow-up controls (2.4). The ephemeral mid-turn prompt
    // carries a pending id; the queued-item Dequeue and the held-item
    // Run/Discard carry the queued item id — all in the button `value`.
    static let followupQueue     = "hud:followup:queue"
    static let followupSteer     = "hud:followup:steer"
    static let followupCancel    = "hud:followup:cancel"
    static let followupDequeue   = "hud:followup:dequeue"
    static let followupRun        = "hud:followup:run"
    static let followupDiscard   = "hud:followup:discard"

    // ASK-YOU spine (Phase 3). Every supervisory affordance carries the prompt id
    // in the button `value` (and a generation stamp folded into that id, 3.4) so a
    // tap resolves exactly the parked RPC it belongs to and a stale tap is rejected.
    // 3.1 — clarifying questions (the Block Kit poll).
    static let answerOption  = "hud:answer:option"   // radio/checkbox select (one per option)
    static let answerSubmit  = "hud:answer:submit"
    static let answerCustom  = "hud:answer:custom"    // "Let me type it" → modal
    static let answerStage    = "hud:answer:stage"     // staged radio/checkbox pick (held; Submit commits)
    static let answerOpenForm = "hud:answer:open_form" // 2+-question ask → opens the staged modal form
    // 3.2 — risk-tiered permission approval.
    static let approveAllow      = "hud:approve:allow"
    static let approveAlways     = "hud:approve:always"   // allow + write a settings rule
    static let approveDeny       = "hud:approve:deny"
    static let approveDenyNote   = "hud:approve:deny_note" // deny-with-steering → modal
    // 3.3 — ExitPlanMode gate.
    static let planApprove   = "hud:plan:approve"
    static let planEdit      = "hud:plan:edit"        // → modal, injected as deny-with-steering
    static let planReject    = "hud:plan:reject"

    // 3.5 — budget / turn guardrails (NO dollars). The turn-cap card's value is the
    // channel id; Continue re-spawns --resume with a raised cap, Stop resolves the
    // turn cleanly.
    static let budgetContinue = "hud:budget:continue"
    static let budgetStop     = "hud:budget:stop"
    // 3.5 — usage-window pre-flight gate. Run-anyway bypasses the headroom check;
    // Wait abandons the launch and leaves a Retry. Value is the channel id.
    static let usageRunAnyway = "hud:usage:run"
    static let usageWait      = "hud:usage:wait"

    // 3.6 — graceful failure. Show error opens the full stderr/error modal (value =
    // root ts, the failureDetails key); Retry-with-changes re-runs the last turn
    // with an appended adjustment.
    static let showError         = "hud:show_error"
    static let retryWithChanges  = "hud:retry_with_changes"
    static let retryChangesModal = "hud:modal:retry_with_changes"

    // PM verbs (task card + Triage capture). The Done button's `value` is
    // "<line>|<project-folder>|<title>" — the task's source line in Tasks.md,
    // the vault folder (so taps resolve from DM-posted cards and survive
    // channel renames), and the parsed title (staleness check before any
    // write). Separators are printable `|` with the first two structural
    // (line is digits-only, folder names carry no pipes; pipes inside the
    // title are harmless) — Slack SILENTLY STRIPS control characters from
    // button values, so a \u{0001}-style separator never round-trips. The
    // Add/Refresh buttons carry the bare folder as their value.
    static let taskDone    = "hud:task:done"
    static let taskAdd     = "hud:task:add"      // opens the add-task modal
    static let taskRefresh = "hud:task:refresh"  // re-render the tapped card

    // view_submission (modal callback_ids) — Phase 3 / 1.4 register handlers
    // against these; declared now so the dispatch scaffold is complete.
    static let resumeWithChangesModal = "hud:modal:resume_with_changes"
    static let answerModal            = "hud:modal:answer"      // 3.1 freeform answer
    static let answerFormModal        = "hud:modal:answer_form" // 3.1 multi-question staged form
    static let denyNoteModal          = "hud:modal:deny_note"   // 3.2 deny-with-note
    static let editPlanModal          = "hud:modal:edit_plan"   // 3.3 edit-plan steering
    static let detailsModal           = "hud:modal:details"
    static let taskAddModal           = "hud:modal:task_add"    // PM add-to-Triage form
}

// MARK: - Block Kit builders (Plan §1.2)

/// Minimal Block Kit block factory. Each helper returns a JSON-serializable
/// `[String: Any]` dictionary that drops straight into `chat.postMessage` /
/// `chat.update`'s `blocks` array. Sections cap at Slack's 3000-char text limit;
/// the secret-redaction / size filter lives upstream (Security S3, later phase).
enum SlackBlocks {
    /// Slack section text hard limit is 3000 chars; stay under it.
    static let sectionLimit = 2900

    static func section(_ mrkdwn: String) -> [String: Any] {
        ["type": "section",
         "text": ["type": "mrkdwn", "text": truncate(mrkdwn, sectionLimit)]]
    }

    static func context(_ mrkdwn: String) -> [String: Any] {
        ["type": "context",
         "elements": [["type": "mrkdwn", "text": truncate(mrkdwn, sectionLimit)]]]
    }

    static func divider() -> [String: Any] { ["type": "divider"] }

    /// A button element. `style` is `"primary"` / `"danger"` or nil (default).
    /// `emoji: true` so `:shortcode:` text renders as the glyph.
    static func button(text: String, actionId: String,
                       value: String = "", style: String? = nil) -> [String: Any] {
        var b: [String: Any] = [
            "type": "button",
            "text": ["type": "plain_text", "text": text, "emoji": true],
            "action_id": actionId
        ]
        if !value.isEmpty { b["value"] = value }
        if let style { b["style"] = style }
        return b
    }

    static func actions(_ buttons: [[String: Any]]) -> [String: Any] {
        ["type": "actions", "elements": buttons]
    }

    /// A section with a right-aligned accessory button (the task-card row).
    static func sectionWithButton(_ mrkdwn: String, button: [String: Any]) -> [String: Any] {
        ["type": "section",
         "text": ["type": "mrkdwn", "text": truncate(mrkdwn, sectionLimit)],
         "accessory": button]
    }

    /// Truncate to `max` chars with a trailing ellipsis (never overruns Slack's
    /// per-block ceiling).
    static func truncate(_ s: String, _ max: Int) -> String {
        s.count <= max ? s : String(s.prefix(max - 1)) + "…"
    }
}
