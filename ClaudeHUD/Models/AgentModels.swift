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
    case other(String)

    /// Derive display state from every signal the daemon exposes, not just the
    /// `state` string. The daemon reports activity through `state`, `tempo`,
    /// and `inFlight.tasks`; a session can be actively working while `state`
    /// still reads a stale value, so in-flight work and `tempo` take priority
    /// over an ambiguous `state`. Schema is research-preview, so unknown
    /// tokens fall through to `.other` rather than being dropped.
    static func derive(state: String, tempo: String?, inFlightTasks: Int?, isAlive: Bool) -> AgentDisplayState {
        let s = state.lowercased()
        let t = (tempo ?? "").lowercased()

        // Terminal states win — a finished session isn't "working".
        if ["done", "completed", "complete", "success"].contains(s) { return .completed }
        if ["failed", "error", "errored"].contains(s) { return .failed }
        if ["stopped", "killed", "cancelled", "canceled"].contains(s) { return .stopped }

        // Liveness gate: roster.json is the daemon's authoritative process
        // list. If the worker is NOT in it, the process has exited — its
        // last-written `state.json` is stale. A dead session must never sit
        // in "Working"/"Needs input"/"Idle" masquerading as live (the exact
        // failure mode when a working session is kill -9'd, the daemon
        // restarts, or the machine sleeps before a terminal state is
        // flushed). Cleanly-finished sessions already returned above, so
        // anything reaching here while not alive genuinely exited.
        if !isAlive { return .stopped }

        // Explicitly waiting on the user.
        if ["needs_input", "needs input", "blocked", "input", "waiting", "paused"].contains(s)
            || t == "blocked" { return .needsInput }

        // Actively working — trust in-flight work / tempo even if `state` lags.
        if (inFlightTasks ?? 0) > 0 { return .working }
        if ["working", "running", "active", "busy", "in_progress",
            "generating", "thinking", "tool_use"].contains(s) { return .working }
        if ["working", "running", "busy", "active"].contains(t) { return .working }

        if ["idle", "ready"].contains(s) { return .idle }
        if t == "idle" { return .idle }
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
        case .other: return .secondary
        }
    }

    /// Group buckets mirror `claude agents`: blocked work floats to the top.
    var groupRank: Int {
        switch self {
        case .needsInput: return 0
        case .working: return 1
        case .idle: return 2
        case .completed, .failed, .stopped, .other: return 3
        }
    }

    var groupTitle: String {
        switch self {
        case .needsInput: return "Needs input"
        case .working: return "Working"
        case .idle: return "Idle"
        case .completed, .failed, .stopped, .other: return "Completed"
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

    var display: AgentDisplayState {
        .derive(state: rawState, tempo: tempo, inFlightTasks: inFlightTasks, isAlive: isAlive)
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
