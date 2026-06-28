import Foundation

// MARK: - Phase 4.1: live subagent progress tree
//
// When a turn fans out into subagents (each a `Task` tool_use), the operator
// needs to SEE the fan-out as a tree, not guess from dead air — users misread
// parallel work as stalled (Plan §4.1). This renders the fan-out as ONE pinned
// `chat.update`-d thread message (a Plan header + one line per branch), never N
// messages per subagent (thread-spam is the failure mode). It is a sibling of
// the flat activity trail (`TurnTrail`): the trail is the linear "what happened"
// surface; the tree is the "who is doing what, concurrently" surface.
//
// Data source: the Phase-0 parser already attributes every event. A `Task`
// tool_use opens a branch (its `tool_id` is the `parent_tool_use_id` every
// child event inside that subagent carries). Child tool calls roll up to their
// branch; the branch closes when the Task's own `tool_result` arrives. Depth is
// capped at 1 (parent + direct children) per the plan — deeper nesting collapses
// into the child action count.
//
// Cost surfacing follows the engine's subscription-billing rule: NO dollars.
// The header carries CONCURRENCY ("3 running"), PROGRESS ("2/5 done"), and a
// cost signal that is TOKENS (final, from `result.usage`) plus the live
// UsageService 5-hour window headroom — never a dollar figure. Per-branch token
// cost is not emitted per-subagent on Tier A, so a branch surfaces its action
// count as its live "weight" instead.

/// Live, mutable state of one turn's subagent tree. Reference type so the
/// stream-event closure and the debounced renderer mutate the same record.
/// MainActor-confined (only ever touched from `SlackService`'s MainActor).
@MainActor
final class SubagentTree {
    let channelId: String
    /// The turn's root ts — the tree is posted as a reply in this thread.
    let rootTs: String
    /// ts of the single tree message once posted (then `chat.update`-d in place).
    var threadTs: String?

    // Debounce / reentrancy bookkeeping (shares the trail's ~1 update / 2s budget,
    // well within chat.update's 1-per-3s ceiling).
    var rendering = false
    var dirty = false
    var flushScheduled = false
    var lastRenderedAt: Date = .distantPast
    /// Turn reached a terminal render; running branches flip to done and the
    /// Stop-all control is dropped.
    var finished = false
    /// Whole-turn token total, set on finalize from `result.usage` (NO dollars —
    /// tokens only, per the subscription-billing cost rule).
    var finalTokens: Int = 0

    enum Status {
        case running, done, failed
        var glyph: String {
            switch self {
            case .running: return "⟳"
            case .done:    return "✓"
            case .failed:  return "✗"
            }
        }
        var label: String {
            switch self {
            case .running: return "running"
            case .done:    return "done"
            case .failed:  return "failed"
            }
        }
    }

    /// One subagent branch (a `Task` spawn). Children roll up as a count + the
    /// most recent semantic action (the observable-backtracking signal: a branch
    /// that is "Editing fix" then "Running tests" reads as working, never hung).
    final class Branch {
        let taskId: String
        let title: String
        /// 1-based spawn order (the "2 of 5" position in the header/line).
        let index: Int
        var status: Status = .running
        let startedAt: Date
        var finishedAt: Date?
        var childActions = 0
        var latestChild: String?

        init(taskId: String, title: String, index: Int, startedAt: Date) {
            self.taskId = taskId
            self.title = title
            self.index = index
            self.startedAt = startedAt
        }
    }

    private(set) var branches: [Branch] = []
    private var indexByTaskId: [String: Int] = [:]

    init(channelId: String, rootTs: String) {
        self.channelId = channelId
        self.rootTs = rootTs
    }

    // MARK: - Mutation

    var hasBranches: Bool { !branches.isEmpty }
    var runningCount: Int { branches.lazy.filter { $0.status == .running }.count }
    var doneCount: Int { branches.lazy.filter { $0.status != .running }.count }
    var total: Int { branches.count }

    /// Open a branch for a `Task` tool_use. Idempotent on the task id (a redelivered
    /// or duplicate block never double-counts a subagent).
    func addTask(_ t: CLIToolUseEvent) {
        guard indexByTaskId[t.toolId] == nil else { return }
        let b = Branch(taskId: t.toolId,
                       title: Self.taskTitle(t.input),
                       index: branches.count + 1,
                       startedAt: Date())
        indexByTaskId[t.toolId] = branches.count
        branches.append(b)
    }

    /// Roll a child tool call up to its branch (depth-1). Returns true when it
    /// matched a known branch (so the caller can skip a needless re-render).
    @discardableResult
    func recordChild(_ t: CLIToolUseEvent) -> Bool {
        guard let pid = t.parentToolUseId, let i = indexByTaskId[pid] else { return false }
        branches[i].childActions += 1
        branches[i].latestChild = TurnTrail.semantic(tool: t.toolName, inputJSON: t.input)
        return true
    }

    /// Close a branch when its Task's `tool_result` arrives (keyed by the Task id,
    /// which is the result's `tool_use_id`). Returns true when it matched a branch.
    @discardableResult
    func closeBranch(_ r: CLIToolResultEvent) -> Bool {
        guard let i = indexByTaskId[r.toolId] else { return false }
        branches[i].status = r.isError ? .failed : .done
        branches[i].finishedAt = Date()
        return true
    }

    /// Flip any still-open branch to done — the turn ended (clean finish). A branch
    /// left open at a Stop/Failure keeps its last observed status via the caller.
    func markRunningDone() {
        for b in branches where b.status == .running {
            b.status = .done
            b.finishedAt = Date()
        }
    }

    // MARK: - Rendering

    /// Build the tree message's Block Kit blocks (one message, verbs transform in
    /// place). `usageHint` is the live 5-hour window headroom string the caller
    /// reads from UsageService (nil ⇒ no reading); it is shown only while running,
    /// replaced by the final token total once the turn resolves.
    func blocks(usageHint: String?) -> [[String: Any]] {
        var blocks: [[String: Any]] = []

        // Header: concurrency + progress + cost (tokens / usage window, NO dollars).
        var headParts: [String] = [":deciduous_tree: *Subagents*"]
        let phase: String
        if finished {
            phase = "\(doneCount)/\(total) done"
        } else if runningCount > 0 {
            phase = "\(runningCount) running  ·  \(doneCount)/\(total) done"
        } else {
            // Every branch has returned but the turn is still going — the parent is
            // stitching results. Show it so all-done-but-not-finished never reads
            // as a hang.
            phase = total > 0 ? "\(doneCount)/\(total) done  ·  verifying…" : "spawning…"
        }
        headParts.append(phase)
        if finished, finalTokens > 0 {
            headParts.append(Self.formatTokens(finalTokens))
        } else if let usageHint {
            headParts.append(usageHint)
        }
        blocks.append(SlackBlocks.context(headParts.joined(separator: "  ·  ")))

        // One line per branch (depth-1). Cap to keep under Slack's block limits;
        // the oldest collapse into a "+N earlier" note.
        let maxBranches = 12
        let shown = branches.suffix(maxBranches)
        let hidden = branches.count - shown.count
        var lines: [String] = []
        if hidden > 0 {
            lines.append("_+\(hidden) earlier subagent\(hidden == 1 ? "" : "s")_")
        }
        for b in shown {
            let acts = b.childActions > 0
                ? "  ·  \(b.childActions) action\(b.childActions == 1 ? "" : "s")"
                : ""
            lines.append("\(b.status.glyph) *\(b.title)*  ·  \(b.status.label)  ·  \(b.index)/\(total)\(acts)")
            // The latest child action is the live "what is this branch doing now"
            // signal — only meaningful while the branch is still running.
            if b.status == .running, let child = b.latestChild {
                lines.append("    ↳ \(TurnTrail.redactPlain(child))")
            }
        }
        if !lines.isEmpty {
            blocks.append(SlackBlocks.section(lines.joined(separator: "\n")))
        }

        // Stop the WHOLE tree. On Tier A there is no per-branch kill, so "Stop a
        // branch" degrades to "Stop all", which routes to the same Stop handler
        // that killpg's the entire process group (1.4 / Plan §4.1 constraint) —
        // parent + every subagent die together, none left editing or billing.
        if !finished {
            blocks.append(SlackBlocks.actions([
                SlackBlocks.button(text: ":octagonal_sign: Stop all",
                                   actionId: SlackAction.stop, style: "danger")
            ]))
        }
        return blocks
    }

    // MARK: - Helpers

    /// Title for a branch from the Task tool input (`description`, else
    /// `subagent_type`). One line, capped, secret-redacted.
    static func taskTitle(_ inputJSON: String) -> String {
        let input = (try? JSONSerialization.jsonObject(with: Data(inputJSON.utf8))) as? [String: Any] ?? [:]
        let raw = (input["description"] as? String)
            ?? (input["subagent_type"] as? String)
            ?? "subagent"
        let oneLine = raw.replacingOccurrences(of: "\n", with: " ")
            .trimmingCharacters(in: .whitespaces)
        let capped = oneLine.count <= 48 ? oneLine : String(oneLine.prefix(47)) + "…"
        return TurnTrail.redactPlain(capped.isEmpty ? "subagent" : capped)
    }

    /// `12.3k tokens` / `840 tokens` — the cost signal for a subscription-billed
    /// engine (NO dollars).
    static func formatTokens(_ n: Int) -> String {
        if n >= 1000 { return String(format: "%.1fk tokens", Double(n) / 1000) }
        return "\(n) tokens"
    }
}
