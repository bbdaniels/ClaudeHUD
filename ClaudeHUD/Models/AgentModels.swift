import SwiftUI

/// Display state for a daemon-backed background agent, derived from
/// `~/.claude/jobs/<id>/state.json` `state` plus roster liveness.
///
/// Agent View is a research-preview feature and its on-disk schema can change,
/// so unknown raw states fall through to `.other` instead of being dropped.
enum AgentDisplayState: Equatable {
    case working
    case needsInput
    case idle
    case completed
    case failed
    case stopped
    /// Presentation-only bucket (NOT a daemon state): an alive, non-terminal
    /// session that has no Ghostty window open anywhere. A daemon-`blocked`
    /// session whose window was closed is not awaiting *your* input — there
    /// is no window to act in — so it must not wear urgent "Needs input".
    /// Collapses to one muted bucket at the very bottom. See `AgentSession.bucket`.
    case detached
    case other(String)

    /// Derive display state from every signal the daemon exposes.
    ///
    /// Hard-won detail about the daemon's schema (Agent View, research
    /// preview): `state` is NOT an activity indicator. The daemon uses
    /// `state: "working"` as a *liveness* token — "the worker process is
    /// up" — so a parked, never-prompted, or awaiting-user session still
    /// reports `state: "working"`. The real activity truth is, in order of
    /// reliability: `inFlight.tasks` (real work queued/running) →
    /// `detail` (the daemon's own human-readable status, incl. the
    /// never-started sentinel "… send a prompt to start") → `tempo`
    /// (active/idle/blocked). `state` is only trusted for (a) terminal
    /// outcomes and (b) `blocked`/`needs_input`, which the daemon DOES set
    /// deliberately when waiting on the user — that one is reliable.
    /// Schema is research-preview, so unknown tokens fall through to
    /// `.other` rather than being dropped.
    static func derive(state: String, tempo: String?, inFlightTasks: Int?,
                       detail: String, isAlive: Bool,
                       stateUpdatedAt: Date? = nil,
                       transcriptMtime: Date? = nil) -> AgentDisplayState {
        let s = state.lowercased()
        let t = (tempo ?? "").lowercased()
        let d = detail.lowercased()

        // 1. Terminal states win — a finished session isn't "working".
        if ["done", "completed", "complete", "success"].contains(s) { return .completed }
        if ["failed", "error", "errored"].contains(s) { return .failed }
        if ["stopped", "killed", "cancelled", "canceled"].contains(s) { return .stopped }

        // 2. Liveness gate: roster.json is the daemon's authoritative process
        // list. If the worker is NOT in it, the process has exited — its
        // last-written `state.json` is stale. A dead session must never sit
        // in "Working"/"Needs input"/"Idle" masquerading as live (the exact
        // failure mode when a working session is kill -9'd, the daemon
        // restarts, or the machine sleeps before a terminal state is
        // flushed). Cleanly-finished sessions already returned above, so
        // anything reaching here while not alive genuinely exited.
        if !isAlive { return .stopped }

        // The daemon writes `state.json` event-driven, not heartbeat — for
        // long-running sessions it can fall many minutes behind the
        // transcript. When the transcript file has been touched after
        // `state.json` was last flushed, the daemon's snapshot is the
        // stale one; trust the transcript instead. Tunable threshold of
        // 5s soaks up clock jitter and the daemon's own internal cadence.
        let transcriptIsFresh: Bool = {
            guard let m = transcriptMtime, let u = stateUpdatedAt else { return false }
            return m.timeIntervalSince(u) > 5
        }()

        // 3. Never-started sentinel: a freshly-spawned bg session that has
        // never received a prompt reports a contradictory mix
        // (state="working", tempo="active") — only `detail` tells the
        // truth, deterministically, via the daemon's own sentinel. It is
        // idle, not working. Match the stable anchor phrase, not the exact
        // punctuation (the daemon uses an em dash inside parens).
        //
        // BUT: if the transcript has been written *after* the daemon last
        // flushed this snapshot, the sentinel is itself stale (the user
        // has obviously prompted since). Drop it and fall through to the
        // activity-derived buckets.
        if d.contains("send a prompt to start"), !transcriptIsFresh {
            return .idle
        }

        // 4. Explicitly waiting on the user. `state` blocked/needs_input is
        // a signal the daemon sets deliberately, so it is reliable here and
        // outranks tempo (a blocked session can still read tempo="active").
        if ["needs_input", "needs input", "blocked", "input", "waiting", "paused"].contains(s)
            || t == "blocked" { return .needsInput }

        // 5. Real work in flight is the strongest activity signal.
        if (inFlightTasks ?? 0) > 0 { return .working }

        // 6. Activity truth: `tempo` outranks the coarse `state` liveness
        // token (a parked session reads state="working", tempo="idle").
        if t == "idle" { return .idle }
        if ["working", "running", "busy", "active"].contains(t) { return .working }

        // 7. Fall back to `state` only when `tempo` gave no signal.
        if ["working", "running", "active", "busy", "in_progress",
            "generating", "thinking", "tool_use"].contains(s) { return .working }
        if ["idle", "ready"].contains(s) { return .idle }
        return .other(state)
    }

    var label: String {
        switch self {
        case .working: return "Working"
        case .needsInput: return "Needs input"
        case .idle: return "Idle"
        case .completed: return "Completed"
        case .failed: return "Failed"
        case .stopped: return "Stopped"
        case .detached: return "Detached"
        case .other(let s): return s.isEmpty ? "Unknown" : s.capitalized
        }
    }

    var systemImage: String {
        switch self {
        case .working: return "circle.dotted.circle"
        case .needsInput: return "questionmark.circle.fill"
        case .idle: return "pause.circle"
        case .completed: return "checkmark.circle.fill"
        case .failed: return "xmark.octagon.fill"
        case .stopped: return "stop.circle"
        case .detached: return "moon.zzz"
        case .other: return "circle"
        }
    }

    var color: Color {
        switch self {
        case .working: return .blue
        case .needsInput: return .yellow
        case .idle: return .secondary
        case .completed: return .green
        case .failed: return .red
        case .stopped: return .gray
        case .detached: return .secondary
        case .other: return .secondary
        }
    }

    /// Group buckets. Open work that needs you floats to the top; sessions
    /// not open in any window sink to the very bottom (`.detached`, rank 4),
    /// below even Completed — they are alive but demand nothing from you.
    var groupRank: Int {
        switch self {
        case .needsInput: return 0
        case .working: return 1
        case .idle: return 2
        case .completed, .failed, .stopped, .other: return 3
        case .detached: return 4
        }
    }

    var groupTitle: String {
        switch self {
        case .needsInput: return "Needs input"
        case .working: return "Working"
        case .idle: return "Idle"
        case .completed, .failed, .stopped, .other: return "Completed"
        case .detached: return "Detached"
        }
    }
}

/// One background session from the Claude Code daemon, merged from
/// `roster.json` (liveness) and `jobs/<id>/state.json` (rendered state).
struct AgentSession: Identifiable, Equatable {
    let id: String              // daemon short id (jobs/<id> dir name)
    let name: String            // state.json name → intent → id
    let rawState: String        // state.json.state verbatim
    let detail: String          // one-line summary the daemon generates
    let intent: String          // original dispatch prompt
    let cwd: String
    let createdAt: Date?
    let updatedAt: Date?
    let isAlive: Bool           // present in roster.workers (process running)
    let pid: Int?
    let isPinned: Bool
    let template: String?       // "claude", "bg", subagent name…
    let tempo: String?          // state.json.tempo (idle/working/blocked…)
    let inFlightTasks: Int      // state.json.inFlight.tasks
    /// True iff a `claude attach <short>` process is currently alive somewhere
    /// for this id. This is the only honest "open" signal: the daemon's
    /// state can sit on `blocked` forever after the user closes the window,
    /// and project-name window-title matching was conflating unrelated shorts.
    let isOpen: Bool
    /// Title of the Ghostty window currently hosting `claude attach <id>`,
    /// nil when no Ghostty ancestor was found (attached in a non-Ghostty
    /// terminal, or not attached at all).
    let attachedWindowTitle: String?
    /// PID of the Ghostty process that owns the attached window, so the
    /// AgentsView's attach action can raise *that* window directly instead
    /// of fuzzy-matching by project name.
    let attachedGhosttyPid: pid_t?
    /// Last-write time of the session's `.jsonl` transcript, when readable.
    /// The daemon flushes `state.json` event-driven and can fall minutes
    /// behind for active sessions; the transcript ticks on every model
    /// turn, so its mtime is the only reliable "is this session actually
    /// moving right now" signal.
    let transcriptMtime: Date?

    /// Raw daemon-derived state (activity truth, ignores window-openness).
    var display: AgentDisplayState {
        .derive(state: rawState, tempo: tempo, inFlightTasks: inFlightTasks,
                detail: detail, isAlive: isAlive,
                stateUpdatedAt: updatedAt,
                transcriptMtime: transcriptMtime)
    }

    /// True iff the transcript was touched in the last 30s — used by the
    /// row as a "moving right now" hint independent of the bucketed state,
    /// since the daemon's snapshot can lag well past that.
    var hasRecentTranscriptActivity: Bool {
        guard let m = transcriptMtime else { return false }
        return Date().timeIntervalSince(m) < 30
    }

    /// Effective presentation bucket — what the dash groups and badges by.
    /// Open-ness (real attach state, not project-name window matching) is
    /// the primary axis the user cares about:
    ///   - alive + attached: show whatever the user is doing right now.
    ///     If the daemon reported a terminal `done`/`failed` for the last
    ///     task but the user is still attached and typing, re-derive from
    ///     `tempo`/`inFlight` so the row says Idle/Working — burying it in
    ///     Completed makes the panel look uncoordinated with the window.
    ///   - alive + detached: collapse to `.detached` (muted, bottom).
    ///   - dead: stay terminal.
    var bucket: AgentDisplayState {
        if isAlive, isOpen {
            switch display {
            case .completed, .failed:
                // Re-derive without the terminal short-circuit by lying
                // about `state` — the activity rungs (tempo, inFlight,
                // detail) tell the truth for an attached live worker.
                return AgentDisplayState.derive(
                    state: "active", tempo: tempo,
                    inFlightTasks: inFlightTasks,
                    detail: detail, isAlive: true,
                    stateUpdatedAt: updatedAt,
                    transcriptMtime: transcriptMtime)
            default:
                return display
            }
        }
        switch display {
        case .completed, .failed, .stopped, .detached:
            return display
        default:
            return isOpen ? display : .detached
        }
    }

    var projectName: String {
        let c = cwd.trimmingCharacters(in: .whitespaces)
        guard !c.isEmpty else { return "—" }
        return URL(fileURLWithPath: c).lastPathComponent
    }

    /// Process-liveness glyph, like the icon *shape* in agent view
    /// (`✻` alive vs `∙` exited).
    var livenessLabel: String { isAlive ? "alive" : "exited" }
}
