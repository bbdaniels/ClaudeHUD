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
    /// The daemon's terminal `state` tokens, by outcome. Shared so the reaper
    /// can ask "does this row still *claim* to be running?" without
    /// re-deriving — `derive` collapses any dead worker to `.stopped`, which
    /// would hide exactly the rows the reaper is looking for.
    static let doneStates    = ["done", "completed", "complete", "success"]
    static let failedStates  = ["failed", "error", "errored"]
    static let stoppedStates = ["stopped", "killed", "cancelled", "canceled"]

    /// True iff `state` is any terminal token — the session reported its own
    /// ending, so its `state.json` is a finished record, not a stale snapshot.
    static func isTerminal(state: String) -> Bool {
        let s = state.lowercased()
        return doneStates.contains(s) || failedStates.contains(s) || stoppedStates.contains(s)
    }

    static func derive(state: String, tempo: String?, inFlightTasks: Int?,
                       detail: String, isAlive: Bool,
                       stateUpdatedAt: Date? = nil,
                       transcriptMtime: Date? = nil) -> AgentDisplayState {
        let s = state.lowercased()
        let t = (tempo ?? "").lowercased()
        let d = detail.lowercased()

        // 1. Terminal states win — a finished session isn't "working".
        if doneStates.contains(s) { return .completed }
        if failedStates.contains(s) { return .failed }
        if stoppedStates.contains(s) { return .stopped }

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
    /// `state.json.worktreePath` when the session ran isolated in a git
    /// worktree, and that worktree still exists on disk. `claude rm` deletes
    /// the worktree along with the session — uncommitted work included — so
    /// this is both a warning for the confirm dialog and a hard veto for the
    /// reaper.
    let worktreePath: String?
    /// The Claude Code session id (the transcript's basename), which the
    /// filing rule keys its claim and record tallies on. Nil when the job's
    /// `state.json` names none.
    var sessionId: String? = nil
    /// Set only on a session started from the Claude app through Remote
    /// Control (`ClaudeSessionRecord.isRemoteControlChild`): it has no
    /// terminal window and no daemon job, so focusing it opens its claude.ai
    /// page in the browser instead of raising a window.
    var remoteControlURL: URL? = nil

    /// Set only on an iMac row: the tmux session on the iMac that holds it,
    /// which a click attaches a Ghostty window to over ssh. Nil for an iMac
    /// session with no terminal (one the Remote Control server spawned from
    /// the phone or claude.ai), which a click first moves into the gate's
    /// tmux with the gate's `adopt` (AgentsService.open).
    var iMacTmux: String? = nil
    /// The gate's command that attaches to `iMacTmux` (its own tmux server
    /// or the default one); nil from a gate that does not report it.
    var iMacAttach: String? = nil
    /// The tty of the terminal attached to this session on this Mac (a
    /// `claude attach` or an ssh `tmux attach`), which names its Ghostty tab
    /// so a click can select that tab rather than only raise the window.
    var attachedTTY: String? = nil
    /// The session's title, the one History shows (`SessionScan.sidecarTitle`),
    /// set by `AgentsService.reload` for a live session; nil when none is
    /// written yet.
    var title: String? = nil
    /// True while the CLI reports "shell": the session's turn waits on one
    /// shell command (`SessionLight.holding`).
    var inShell: Bool = false
    /// True when its turn has ended with work still out
    /// (`HostProcsSnapshot.hasWorkOut`), set by `AgentsService.reload`.
    var workOut: Bool = false

    /// True for a Remote Control session row (see `remoteControlURL`).
    var isRemoteControl: Bool { remoteControlURL != nil }
    /// True for a session running on the iMac (`AgentsService.reload`).
    var isIMac: Bool { template == "imac" }
    /// The daemon's verbs (logs, stop, respawn, remove) address a Mac job
    /// id: neither a phone row nor an iMac row has one.
    var hasDaemonJob: Bool { !isRemoteControl && !isIMac }

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

    /// True iff this row is stale debris the reaper may delete.
    ///
    /// The daemon writes `state.json` event-driven and never flushes a
    /// terminal state when a worker dies abnormally (window closed, machine
    /// slept, `kill -9`, daemon restart), so the last snapshot stays frozen
    /// at `blocked`/`working` forever. `claude agents` trusts that file with
    /// no roster cross-check and renders such a row as "awaiting input"
    /// indefinitely — 43 days, on the machine that surfaced this.
    ///
    /// Four conditions, all required:
    ///   1. `rawState` still claims non-terminal — a session that reported
    ///      `done`/`failed` is a finished record, not a lie, and stays.
    ///   2. The worker is absent from the daemon roster, so it is provably
    ///      gone rather than merely quiet.
    ///   3. Older than `cutoff`. An exited session is still `respawn`-able,
    ///      so a recent one is recoverable work, not debris.
    ///   4. Not pinned, and owns no surviving worktree — `claude rm` deletes
    ///      the worktree with its uncommitted changes.
    func isStaleDebris(olderThan cutoff: Date) -> Bool {
        Self.isStaleDebris(rawState: rawState, isAlive: isAlive, isPinned: isPinned,
                           worktreePath: worktreePath,
                           last: updatedAt ?? createdAt, olderThan: cutoff)
    }

    /// The same rule stated over just the fields it needs, so a disk-only
    /// scan (no `ps`, no transcript reads, no name resolution) can apply the
    /// exact rule the UI does. One copy of a delete predicate, not two.
    static func isStaleDebris(rawState: String, isAlive: Bool, isPinned: Bool,
                              worktreePath: String?, last: Date?,
                              olderThan cutoff: Date) -> Bool {
        guard !isAlive, !isPinned, worktreePath == nil else { return false }
        guard !AgentDisplayState.isTerminal(state: rawState) else { return false }
        guard let last else { return false }
        return last < cutoff
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
        if isAlive, isOpen, let live = liveState { return live }
        switch display {
        case .completed, .failed, .stopped, .detached:
            return display
        default:
            return isOpen ? display : .detached
        }
    }

    /// The state of a session whose process is alive, attached to a terminal
    /// or not; nil for a dead one. What the Projects rows show and count:
    /// every running session is a line under its project (Ben, 2026-11-03:
    /// one list of every session, matching the phone and claude.ai). `bucket`
    /// keeps the Agents tab's `.detached` grouping on top of it.
    var liveState: AgentDisplayState? {
        guard isAlive else { return nil }
        switch display {
        case .completed, .failed:
            // Re-derive without the terminal short-circuit by lying about
            // `state`: the activity rungs (tempo, inFlight, detail) tell the
            // truth for a live worker.
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

    /// True when a terminal on this Mac shows the session (a `claude attach`
    /// or an ssh `tmux attach`), so a click raises it rather than opening a
    /// new tab.
    var hasWindow: Bool { attachedGhosttyPid != nil || attachedTTY != nil }

    /// The session's dot on its Projects line (`SessionLight`).
    func light(now: Date) -> SessionLight {
        SessionLight.of(running: liveState == .working, inShell: inShell, workOut: workOut, hasWindow: hasWindow,
                        lastMoved: max(updatedAt ?? .distantPast, transcriptMtime ?? .distantPast), now: now)
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
