import Foundation
import Combine
import AppKit
import os

private let logger = Logger(subsystem: "com.claudehud", category: "SlackService")

/// Phase 1 Slack integration: connect to Slack via Socket Mode, and when a
/// human posts in a channel whose name matches a ClaudeHUD project, reply in
/// that channel identifying the resolved project and its working directory.
///
/// Phase 1 proves the loop — receive message → resolve channel → project →
/// reply (no Claude session yet; that is Phase 2). Phase 1.5 adds additive
/// channel provisioning (project → channel sync) and two slash commands:
/// `/claude-sync` (run the sync) and `/claude-project <dir> [name]` (create a
/// vault project for an existing directory + its channel). Interactive
/// payloads are acked by `SocketModeClient` but otherwise just logged.
///
/// Tokens live in the login Keychain under service `com.claudehud.slack`
/// (accounts `bot_token` / `app_token`). If either is absent, `start()` is a
/// no-op so the app runs normally without Slack configured. Token values are
/// never logged.
@MainActor
final class SlackService: ObservableObject {
    @Published private(set) var isConnected = false
    @Published private(set) var lastError: String?

    nonisolated private static let keychainService = "com.claudehud.slack"

    private let projectService: ProjectService
    private let vaultProjects: VaultProjectService
    /// Read-only window into the subscription usage windows (5-hour / 7-day). The
    /// budget guardrail (3.5) reads `usage.fiveHour.utilization/resetsAt` to gate a
    /// launch when the shared window is near-exhausted — it never tracks dollars.
    private let usageService: UsageService

    private var client: SocketModeClient?
    private var botToken: String?
    private var botUserId: String?
    private var botId: String?
    private var teamId: String?
    /// The most recent human poster — the operator we @mention to push a Needs-you
    /// escalation (N1) so the watch buzzes (a `chat.update` alone is silent). Best
    /// effort: captured per channel from the last human message.
    private var operatorUserId: [String: String] = [:]

    /// Cache of Slack channel id → channel name (from `conversations.info`).
    private var channelNameCache: [String: String] = [:]

    private let session = URLSession.shared

    // MARK: - Phase 2: per-channel session driving

    /// Persisted per-channel session state. Each Slack channel maps to one
    /// Claude session id (nil = start fresh) and a permission mode. THIN
    /// manager: we only ever drive the sessions Slack launches, through the
    /// same `~/.claude/projects` JSONL substrate (resume by session id). A
    /// `claude` started by hand in a terminal is a separate OS process we
    /// never touch.
    private struct ChannelSession: Codable {
        var sessionId: String?
        var permissionMode: String   // "plan" | "default" | "dangerously-skip"
        /// The cwd the `sessionId` was created under. A session id only resumes
        /// in the same `~/.claude/projects` store, so if the project's resolved
        /// cwd later changes the stored session is stranded — we detect that by
        /// comparing this against the freshly resolved cwd and start fresh.
        /// Optional for backward-compat with pre-cwd persisted state (→ fresh).
        var cwd: String?
        /// Reasoning-effort dial (2.3): "low" | "medium" | "high" | "xhigh" |
        /// "max". Optional + defaulted (`effortLevel`) for backward-compat with
        /// state persisted before the dial existed.
        var effort: String? = nil
        /// Follow-up policy for a message that arrives mid-turn (2.4):
        /// "ask" | "queue" | "steer". Optional + defaulted (`followupPolicy`).
        var followup: String? = nil
        /// Per-turn turn-count guardrail (3.5, NO dollars): the `--max-turns`
        /// ceiling handed to the engine. Optional + defaulted (`maxTurns`) for
        /// backward-compat with state persisted before the guardrail existed.
        var maxTurns: Int? = nil
    }

    /// A Slack conversation = one thread = one session. The thread's ROOT message
    /// ts identifies the session; the channel scopes it. Different threads run in
    /// PARALLEL (separate sessions/engines/locks/queues) — this is the unit every
    /// per-turn map is now keyed by, replacing the old per-channel model. A
    /// top-level message starts a NEW conversation in its own thread; a reply
    /// continues the conversation of the thread it lands in.
    struct Conversation: Hashable {
        let channelId: String
        let threadRootTs: String
        /// Stable dictionary key. The U+0001 separator can't occur in a Slack
        /// channel id or ts, so `(channel, ts)` round-trips unambiguously.
        var key: String { "\(channelId)\u{0001}\(threadRootTs)" }
    }

    /// Build a conversation dictionary key from a channel + thread-root ts.
    nonisolated private static func convKey(_ channel: String, _ threadRoot: String) -> String {
        "\(channel)\u{0001}\(threadRoot)"
    }

    /// Reconstruct a `Conversation` from a key produced by `convKey`.
    private static func conversation(fromKey key: String) -> Conversation? {
        let parts = key.split(separator: "\u{0001}", maxSplits: 1, omittingEmptySubsequences: false)
        guard parts.count == 2 else { return nil }
        return Conversation(channelId: String(parts[0]), threadRootTs: String(parts[1]))
    }

    /// Default reasoning effort when the channel hasn't set one (2.3).
    private static let defaultEffort = "medium"
    /// Default follow-up policy when the channel hasn't set one (2.4).
    private static let defaultFollowup = "ask"
    /// Default per-turn turn-count guardrail (3.5, ON by default). Bounded so a
    /// walk-away runaway loop trips this rather than burning the whole usage
    /// window silently; the operator raises it from the turn-cap card or
    /// `/claude-budget`. The "Continue +N" addend the card offers.
    private static let defaultMaxTurns = 40
    private static let turnCapAddend = 40
    /// 5-hour usage-window utilization (%) at/above which a fresh launch is gated
    /// behind the usage card rather than fired into a likely rate limit (3.5/E5).
    private static let usageNearExhaustedPct: Double = 92
    /// Hard per-turn wall-clock timeout (3.6 / E5, ON by default). The silence
    /// watchdog (1.5) only catches a STALLED process; a runaway-but-active
    /// edit→test→fail loop is caught here. On expiry the turn is force-killed and
    /// resolved to a clear Failed (timed out) with Retry — never a hung spinner.
    private static let wallClockTimeout: TimeInterval = 1500  // 25 min

    /// The conversation's current effort level, falling back to the default.
    private func effortLevel(_ key: String) -> String {
        let e = channelSessions[key]?.effort ?? Self.defaultEffort
        return ClaudeCLIClient.effortLevels.contains(e) ? e : Self.defaultEffort
    }
    /// The conversation's current follow-up policy, falling back to the default.
    private func followupPolicy(_ key: String) -> String {
        channelSessions[key]?.followup ?? Self.defaultFollowup
    }
    /// The conversation's current per-turn turn cap (3.5), falling back to the
    /// default. A one-shot override (set by Continue +N from the turn-cap card)
    /// wins for the very next turn, then is consumed.
    private func maxTurns(_ key: String) -> Int {
        if let override = turnCapOverride[key] { return override }
        return channelSessions[key]?.maxTurns ?? Self.defaultMaxTurns
    }

    /// Outcome-labelled name for an effort level (Plan 2.3: label by outcome,
    /// not jargon).
    private static func effortLabel(_ level: String) -> String {
        switch level {
        case "low":   return "Quick (~1x tokens)"
        case "medium": return "Balanced"
        case "high":  return "Careful (~2x tokens)"
        case "xhigh": return "Exhaustive"
        case "max":   return "Max"
        default:      return level
        }
    }
    /// Per-CONVERSATION session state, keyed by `Conversation.key` (channel +
    /// thread root). Each thread has its own session id / mode / effort / cwd, so
    /// threads run in parallel without sharing resume state.
    private var channelSessions: [String: ChannelSession] = [:]

    /// Per-CHANNEL config defaults (mode / effort / followup / maxTurns only),
    /// keyed by channel id. A brand-new conversation seeds its session config from
    /// here, and the channel-scoped slash commands (which carry no thread context)
    /// write here so the next conversation inherits the operator's choices. The
    /// sessionId / cwd fields are never used in this map.
    private var channelDefaults: [String: ChannelSession] = [:]

    /// The most-recent conversation's thread root per channel id. Slash commands
    /// arrive without thread context, so they act on this "current" conversation
    /// (and the channel defaults). Updated whenever a turn runs.
    private var lastConversation: [String: String] = [:]

    /// Latest init-event skills/agents the engine reported for each channel's
    /// session (Phase 0 system/init), cached when a turn runs. The authoritative
    /// per-session lists Claude reports, not a static catalog. Dictionary
    /// presence is the marker that *some* session has run in the channel: a
    /// missing key means "no turn yet" (so the slash commands ask the operator to
    /// post a message first), whereas a present-but-empty list means the session
    /// genuinely reports none. Surfaced by `/claude-skills` and `/claude-agents`.
    private var channelSkills: [String: [String]] = [:]
    private var channelAgents: [String: [String]] = [:]

    /// One dedicated `ClaudeCLIClient` per channel — deliberately NOT the
    /// shared `AppState.cliClient` the chat tab owns. Per-channel instances
    /// give each channel its own `currentProcess` (so different channels can
    /// run concurrently) and isolate Slack's resume state from the chat tab.
    private var clients: [String: ClaudeCLIClient] = [:]

    /// Channels with a turn currently in flight (single-writer per channel).
    private var inFlight: Set<String> = []

    /// Channels whose in-flight turn the operator has tapped Stop on. Set when
    /// the Stop button fires so the turn resolves to `.stopped` (Stopped-by-you)
    /// rather than `.failed` when the killed process unwinds. (Full process-group
    /// kill + partial capture is 1.4; this is the lifecycle hook it plugs into.)
    private var stopRequested: Set<String> = []

    /// Channels whose in-flight turn the wall-clock watchdog (3.6) is force-killing
    /// for exceeding `wallClockTimeout`. Distinct from `stopRequested` so the kill
    /// resolves to Failed (timed out) rather than Stopped-by-you — the operator did
    /// not initiate it.
    private var timeoutRequested: Set<String> = []

    /// One-shot per-channel turn-cap override consumed by the next `runTurn`
    /// (Continue +N from the turn-cap card, 3.5). Cleared once the turn launches.
    private var turnCapOverride: [String: Int] = [:]

    /// Full failure text (stderr / error body) keyed by the turn's root ts, so the
    /// Failed card's Show-error button (3.6) can open it on demand. Capped.
    private var failureDetails: [String: String] = [:]
    private static let maxFailureDetails = 60

    /// A launch gated by the usage-window pre-flight check (3.5), keyed by channel
    /// id. Run-anyway re-enters `runTurn` with the gate bypassed; Wait abandons it.
    private struct UsageHold {
        let conv: Conversation
        let projectName: String
        let cwd: String
        let obsidianPath: String
        let text: String
        let rootTs: String?
    }
    private var usageHolds: [String: UsageHold] = [:]

    /// A turn parked on the turn-cap decision (3.5: hit `error_max_turns`), keyed
    /// by channel id. Continue re-runs with a raised cap; Stop resolves it cleanly.
    private struct BudgetHold {
        let conv: Conversation
        let projectName: String
        let cwd: String
        let obsidianPath: String
        let text: String
        let rootTs: String?
        let cap: Int
    }
    private var budgetHolds: [String: BudgetHold] = [:]

    /// Everything needed to re-run a channel's most recent turn for the Retry /
    /// Resume buttons. Stored at turn start, read by the interactive dispatch.
    private struct LastTurn {
        let projectName: String
        let cwd: String
        let obsidianPath: String
        let text: String
    }
    /// Keyed by `Conversation.key`. The conversation is reconstructable from the
    /// key components, but Retry/Resume need the project context stored here.
    private var lastTurns: [String: LastTurn] = [:]

    // MARK: - Per-thread auto-queue (follow-up handling)

    /// One buffered follow-up: a message the operator posted in a thread while
    /// that thread's turn was in flight. Auto-queued (no Queue/Steer/Cancel
    /// prompt) and run automatically after the current turn finishes — exactly
    /// like the terminal CLI queues a message typed mid-turn.
    private struct QueuedFollowup {
        let id: String
        let channelId: String
        /// The conversation (thread root) this follow-up belongs to, so the drain
        /// re-runs it in the right thread/session.
        let threadRootTs: String
        let text: String
        let projectName: String
        let cwd: String
        let obsidianPath: String
        /// The thread message ts carrying this item's `[ Dequeue ]` button, so
        /// the affordance can be cleared once the item runs or is dequeued.
        var dequeueTs: String?
        var conv: Conversation { Conversation(channelId: channelId, threadRootTs: threadRootTs) }
    }
    /// Per-CONVERSATION FIFO of queued follow-ups, keyed by `Conversation.key`.
    /// Drained one at a time at each turn's resolution (any terminal state), so a
    /// mid-turn message in a thread runs next, like the CLI's typed-ahead queue.
    private var followupQueue: [String: [QueuedFollowup]] = [:]

    // MARK: - Phase 1.5/1.6: live in-flight turns (heartbeat + durable registry)

    /// A turn currently running in a channel. Reference type so the heartbeat
    /// timer (1.5) and the stream-event closure both mutate the same record.
    /// Mirrored to an on-disk registry (1.6) so an app crash mid-turn can be
    /// reconciled to Interrupted on relaunch rather than orphaning the spinner.
    private final class InFlightTurn {
        let channelId: String
        /// The CONVERSATION thread root ts (the session key component). For the
        /// first turn of a new conversation this equals `rootTs`; for a later turn
        /// (a reply) it is the original thread root and `rootTs` is a reply ts.
        /// Mutable: a brand-new conversation's thread root is its posted root ts,
        /// known only after the root is posted.
        var threadRootTs: String
        /// The conversation key this turn is registered under.
        var convKey: String { SlackService.convKey(channelId, threadRootTs) }
        var conv: Conversation { Conversation(channelId: channelId, threadRootTs: threadRootTs) }
        var rootTs: String?
        let request: String
        let projectName: String
        let cwd: String
        let obsidianPath: String
        let generation: Int
        let startedAt: Date
        /// Reasoning effort + permission mode this turn ran under, surfaced as a
        /// faint provenance line on the root (2.3).
        let effort: String
        let permissionMode: String
        /// Last time ANY stream event arrived — the watchdog's silence clock.
        var lastEventAt: Date
        var toolCount: Int = 0
        /// Operator tapped Stop; the kill is in flight (suppresses heartbeat
        /// overwrites of the optimistic "Stopping…" card).
        var stopping = false
        /// Watchdog already escalated to the silence warning (avoids re-logging).
        var warned = false
        /// Turn has reached a terminal render; heartbeat must stop touching it.
        var resolved = false
        /// Turn is parked on a supervisory prompt (Phase 3): a clarifying question,
        /// a permission gate, or a plan approval. The process is ALIVE and waiting
        /// on the blocked MCP RPC, so the silence watchdog (1.5) must NOT flip it to
        /// "still working" — it is Needs-you, not stalled. Cleared when the
        /// operator's decision unblocks the RPC and the stream resumes.
        var parked = false
        var pid: Int32?
        var pgid: Int32?
        var sessionId: String?
        /// Pre-turn git checkpoint (1.7), nil when cwd is not a repo. Powers the
        /// Show-diff / Undo-turn buttons on the terminal card.
        var checkpoint: GitCheckpoint?
        /// The reaction emoji NAME currently mirrored onto the root (1.9), so the
        /// terminal transition can remove the running `:hourglass:` before adding
        /// the resolved glyph.
        var reaction: String?

        init(channelId: String, threadRootTs: String, rootTs: String?, request: String,
             projectName: String, cwd: String, obsidianPath: String, generation: Int,
             startedAt: Date, effort: String, permissionMode: String) {
            self.channelId = channelId
            self.threadRootTs = threadRootTs
            self.rootTs = rootTs
            self.request = request
            self.projectName = projectName
            self.cwd = cwd
            self.obsidianPath = obsidianPath
            self.generation = generation
            self.startedAt = startedAt
            self.effort = effort
            self.permissionMode = permissionMode
            self.lastEventAt = startedAt
        }
    }
    private var inFlightTurns: [String: InFlightTurn] = [:]

    /// Per-channel monotonic turn generation (stamps the registry; the basis for
    /// the stale-prompt hygiene that lands in Phase 3.4).
    private var channelGeneration: [String: Int] = [:]

    /// Whether the long-lived heartbeat loop (1.5) is already running.
    private var heartbeatRunning = false

    // MARK: - Phase 2.1/2.2: in-thread semantic activity trail + thinking

    /// Live activity trails for in-flight turns, keyed by channel id. The trail
    /// is the single `chat.update`-d thread message that carries semantic events
    /// (not tokens, not raw I/O). Created lazily on the first trail-worthy event.
    private var trails: [String: TurnTrail] = [:]

    /// Finished trails, keyed by root ts, kept so the operator can tap
    /// Show details / Show reasoning on a resolved turn's thread message after it
    /// has left the active map. In-memory only (the Slack message itself is the
    /// durable artifact); capped to avoid unbounded growth.
    private var trailsByRoot: [String: TurnTrail] = [:]
    private static let maxTrailsByRoot = 60

    /// Trail update debounce (Plan §L4: ~1/2s, within chat.update's 1/3s ceiling).
    private static let trailDebounce: TimeInterval = 2.0

    // MARK: - Phase 4.1: in-thread subagent progress tree

    /// Live subagent trees for in-flight turns, keyed by channel id. Created
    /// lazily on the first `Task` spawn (most turns never fan out, so most turns
    /// never post a tree message). Sibling of `trails`: the trail is the flat
    /// activity surface, the tree is the concurrent fan-out surface (Plan §4.1).
    private var subagentTrees: [String: SubagentTree] = [:]

    // MARK: - Phase 1.7: durable git checkpoints (rootTs → pre-turn snapshot)

    /// Pre-turn checkpoints keyed by the turn's root ts (also the Show-diff /
    /// Undo-turn button `value`). Mirrored to disk so the buttons on a terminal
    /// card keep working after an app restart (the card persists in Slack). Capped.
    private var checkpoints: [String: GitCheckpoint] = [:]
    private static let maxCheckpoints = 60

    // MARK: - Phase 1.8: durable message de-duplication

    /// Stable message ids already turned into a spawn (`client_msg_id`, else
    /// `channel:ts`). The `SocketModeClient` envelope-id dedupe (1.8) catches a
    /// same-socket redelivery; this durable layer additionally catches a
    /// redelivery that straddles an app restart, BEFORE a turn is spawned — the
    /// destructive double-spawn the plan calls out. Short TTL, persisted.
    private var seenMessages: [String: Date] = [:]
    private static let seenMessageTTL: TimeInterval = 3600  // 1 hour

    /// On-disk shape of an in-flight turn (1.6). Only the fields needed to flip
    /// the root to Interrupted and offer Resume after a crash are persisted —
    /// the live heartbeat fields (lastEventAt/toolCount) are in-memory only.
    private struct PersistedTurn: Codable {
        var channelId: String
        /// The conversation thread root (session key). Optional for backward-compat
        /// with registries written before per-thread routing (→ fall back to rootTs).
        var threadRootTs: String?
        var rootTs: String?
        var sessionId: String?
        var pid: Int32?
        var pgid: Int32?
        var startedAt: Date
        var generation: Int
        var request: String
        var projectName: String
        var cwd: String
        var obsidianPath: String
    }

    // MARK: - Phase 3 (ASK-YOU spine): parked supervisory prompts

    /// Whether Slack turns run SUPERVISED (Phase 3): `--dangerously-skip-permissions`
    /// is dropped in favor of the bundled MCP server's permission-prompt-tool +
    /// risk policy. Default ON; the operator can fall back to the old skip path via
    /// this default if the supervised seam ever misbehaves (degrades, never breaks).
    private var supervisedMode: Bool {
        UserDefaults.standard.object(forKey: "slack.supervised") as? Bool ?? true
    }

    /// One live supervisory pause. Reference type so the watcher, the interactive
    /// dispatch, and the timeout sweep all mutate the same record. A parked prompt
    /// blocks a live `claude -p` turn on the MCP RPC; resolving it writes the
    /// decision file the MCP server is polling for.
    private final class ParkedPrompt {
        let id: String
        let channelId: String
        /// The conversation thread root the parking turn belongs to (routes the
        /// prompt back to the right per-thread turn when channels run in parallel).
        let threadRootTs: String
        var convKey: String { SlackService.convKey(channelId, threadRootTs) }
        let generation: Int
        let kind: HudPromptKind
        let request: SupervisorRequest
        /// The thread message ts carrying this prompt's card (so it can be cleared
        /// / disabled on resolve, timeout, or generation cancel).
        var cardTs: String?
        let createdAt: Date
        /// Accumulated answers for a multi-question ask (3.1), keyed by question
        /// index. The ask resolves only once every question is answered.
        var answers: [Int: String] = [:]
        /// Set the instant a valid decision is written, so a double-click (e.g.
        /// Approve then Deny) can't resolve the same RPC twice (3.4).
        var locked = false

        init(request: SupervisorRequest) {
            self.id = request.id
            self.channelId = request.channel
            self.threadRootTs = request.thread
            self.generation = request.generation
            self.kind = request.kind
            self.request = request
            self.createdAt = Date()
        }
    }

    /// Live parked prompts keyed by prompt id. The button `value` carries the id;
    /// the dispatch looks the prompt up here, checks its generation against the
    /// channel's current generation (3.4), then writes the decision.
    private var parkedPrompts: [String: ParkedPrompt] = [:]

    /// Request ids already rendered, so the relay watcher renders each exactly
    /// once even though it re-scans the directory on every tick.
    private var relaySeenRequests: Set<String> = []

    /// Whether the relay watcher loop (Phase 3) is already running.
    private var relayWatcherRunning = false

    /// Relay root: requests/ (MCP → ClaudeHUD) and decisions/ (ClaudeHUD → MCP).
    /// Distinct from the HUD panel's `~/.claude/hud/pending` so the supervisory
    /// spine only ever touches turns ClaudeHUD itself spawned with the mcp-config.
    private static var relayDir: String { "\(NSHomeDirectory())/.claude/hud/slack" }
    private static var relayRequestsDir: String { "\(relayDir)/requests" }
    private static var relayDecisionsDir: String { "\(relayDir)/decisions" }

    /// Absolute path to the bundled MCP server script (resolved once).
    private lazy var mcpScriptPath: String? =
        Bundle.main.url(forResource: "hud-slack-mcp", withExtension: "py")?.path

    /// Per-turn parked-prompt timeout (seconds) handed to the MCP server. The
    /// server is the authoritative clock (it must return SOMETHING to unblock the
    /// turn); ClaudeHUD's watcher only cleans up the card when the request file
    /// vanishes. ~30 min: long enough for a walk-away operator, bounded so a
    /// dropped tap can't wedge a channel forever (E4).
    private static let parkedPromptTimeout: TimeInterval = 1800

    /// Model used for Slack-driven turns.
    private static let slackModel = "sonnet"

    init(projectService: ProjectService, vaultProjects: VaultProjectService,
         usageService: UsageService) {
        self.projectService = projectService
        self.vaultProjects = vaultProjects
        self.usageService = usageService
    }

    // MARK: - Lifecycle

    /// Read tokens, learn the bot's own identity, and open the socket. No-op
    /// (logged) if already started or if either token is missing.
    func start() {
        SlackFileLog.log("SlackService.start() entry")
        guard client == nil else {
            SlackFileLog.log("SlackService.start() already started; ignoring")
            return
        }
        loadChannelSessions()
        loadCheckpoints()
        loadSeenMessages()
        startRelayWatcher()   // Phase 3: bridge the MCP relay dir to Slack cards

        Task {
            // Load tokens OFF the main thread. The Keychain read can re-prompt
            // (macOS partition-list gate) and block on the prompt; doing it on
            // the MainActor froze the HUD at "start() entry". A detached task
            // keeps the main thread free no matter how slow the credential read.
            let loaded = await Task.detached(priority: .utility) {
                Self.loadTokens()
            }.value

            SlackFileLog.log("bot_token present=\(loaded?.bot.isEmpty == false ? "Y" : "N") app_token present=\(loaded?.app.isEmpty == false ? "Y" : "N")")
            guard let loaded, !loaded.bot.isEmpty, !loaded.app.isEmpty else {
                logger.info("Slack tokens not present; SlackService idle")
                SlackFileLog.log("tokens missing")
                return
            }
            let botToken = loaded.bot
            let appToken = loaded.app
            self.botToken = botToken

            await authTest(botToken: botToken)

            let client = SocketModeClient(appToken: appToken)
            await client.setEventHandler { [weak self] eventData in
                Task { @MainActor in self?.handleEvent(data: eventData) }
            }
            await client.setSlashCommandHandler { [weak self] payloadData in
                Task { @MainActor in await self?.handleSlashCommand(data: payloadData) }
            }
            await client.setInteractiveHandler { [weak self] payloadData in
                Task { @MainActor in await self?.handleInteractive(data: payloadData) }
            }
            self.client = client
            await client.start()
            self.isConnected = true
            logger.info("Slack Socket Mode started")
            SlackFileLog.log("Slack Socket Mode started")

            // CRASH RECONCILIATION (1.6): before doing anything else, resolve any
            // turn that was in flight when the app last quit — its process, its
            // watchdog, and its in-memory registry all died with the app, so its
            // root would otherwise hang on `:hourglass:` forever (principle 1).
            await self.reconcileInFlightOnLaunch()

            // Additive channel provisioning on startup: ensure every project
            // has a matching public channel the bot has joined. Never destructive.
            let summary = await self.syncChannels()
            SlackFileLog.log("startup sync: \(summary.projects) projects, \(summary.created) channels created")

            // PM ambient layer: the once-daily cross-project morning digest DM.
            self.startDigestLoop()
        }
    }

    func stop() {
        let client = self.client
        self.client = nil
        isConnected = false
        Task { await client?.stop() }
    }

    // MARK: - Token loading

    private struct LoadedTokens: Sendable {
        let bot: String
        let app: String
    }

    /// Load the Slack tokens. File FIRST — `~/Library/Application Support/
    /// ClaudeHUD/slack-tokens.json` (a 0600 JSON object with `bot_token` /
    /// `app_token`) — so Debug rebuilds don't re-trigger the Keychain
    /// partition-list prompt. Falls back to the login Keychain only if the
    /// file is absent/unreadable. `nonisolated static` so it runs off the
    /// MainActor; never logs token values.
    nonisolated private static func loadTokens() -> LoadedTokens? {
        let url = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/ClaudeHUD/slack-tokens.json")
        if let data = try? Data(contentsOf: url),
           let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
           let bot = json["bot_token"] as? String,
           let app = json["app_token"] as? String,
           !bot.isEmpty, !app.isEmpty {
            SlackFileLog.log("tokens loaded from file")
            return LoadedTokens(bot: bot, app: app)
        }

        if let bot = KeychainService.loadGeneric(service: keychainService, account: "bot_token"),
           let app = KeychainService.loadGeneric(service: keychainService, account: "app_token"),
           !bot.isEmpty, !app.isEmpty {
            SlackFileLog.log("tokens loaded from keychain")
            return LoadedTokens(bot: bot, app: app)
        }
        return nil
    }

    // MARK: - Bot identity

    /// `auth.test` learns the bot's own `user_id` / `bot_id` so inbound
    /// messages it posted itself can be filtered out (loop prevention).
    private func authTest(botToken: String) async {
        var req = URLRequest(url: URL(string: "https://slack.com/api/auth.test")!)
        req.httpMethod = "POST"
        req.setValue("Bearer \(botToken)", forHTTPHeaderField: "Authorization")
        req.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        req.httpBody = Data()
        do {
            let (data, _) = try await session.data(for: req)
            let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] ?? [:]
            guard json["ok"] as? Bool == true else {
                let err = json["error"] as? String ?? "unknown"
                logger.error("auth.test failed: \(err)")
                SlackFileLog.log("auth.test failed: \(err)")
                lastError = err
                return
            }
            botUserId = json["user_id"] as? String
            botId = json["bot_id"] as? String
            teamId = json["team_id"] as? String
            logger.info("Slack auth.test ok (bot identity resolved)")
            SlackFileLog.log("auth.test ok bot_user_id=\(botUserId ?? "nil")")
        } catch {
            logger.error("auth.test request failed: \(error.localizedDescription)")
            SlackFileLog.log("auth.test request failed: \(error.localizedDescription)")
            lastError = error.localizedDescription
        }
    }

    // MARK: - Inbound events

    /// Dispatch an inbound Events API `event` object by its `type`.
    private func handleEvent(data: Data) {
        guard let event = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let type = event["type"] as? String else { return }

        switch type {
        case "message":
            handleMessageEvent(event)
        case "channel_created":
            handleChannelCreated(event)
        case "reaction_added":
            handleReactionAdded(event)
        default:
            break
        }
    }

    /// Filter to genuine human messages. Skips edits/deletes (any `subtype`),
    /// bot posts (`bot_id`), and the bot's own `user` id — all of which would
    /// otherwise create reply loops.
    private func handleMessageEvent(_ event: [String: Any]) {
        // Inbound image support: a message bearing image attachments may arrive
        // with subtype "file_share" (or files alongside text). Such a message
        // must NOT be dropped by the edit/delete subtype filter — allow it
        // through when it carries image files, otherwise skip any subtype.
        let files = event["files"] as? [[String: Any]] ?? []
        let imageFiles = files.filter {
            ($0["mimetype"] as? String)?.hasPrefix("image/") == true
        }
        if event["subtype"] != nil, imageFiles.isEmpty { return }
        guard event["bot_id"] == nil else { return }
        let user = event["user"] as? String ?? ""
        if !user.isEmpty, user == botUserId { return }
        guard let channel = event["channel"] as? String else { return }
        let text = event["text"] as? String ?? ""

        // Durable de-dupe (1.8): a redelivery that straddles an app restart slips
        // past the socket's in-memory envelope set, so guard the SPAWN itself on
        // a stable message id. `client_msg_id` is present on user-typed messages;
        // fall back to channel:ts. Drop a message already turned into a turn.
        let ts = event["ts"] as? String ?? ""
        let msgKey = (event["client_msg_id"] as? String) ?? "\(channel):\(ts)"
        if isDuplicateMessage(msgKey) {
            SlackFileLog.log("dedupe: dropped duplicate message \(msgKey)")
            return
        }
        let threadTs = event["thread_ts"] as? String
        SlackFileLog.log("rx: channel=\(channel) ts=\(ts) thread_ts=\(threadTs ?? "nil") text=\(text.prefix(40))")

        Task { await self.handleMessage(channel: channel, text: text, user: user, imageFiles: imageFiles, inboundThreadTs: threadTs, messageTs: ts) }
    }

    /// On `channel_created`: join the new channel and bind it to a project if
    /// its name resolves to one, posting a short orientation message either way.
    private func handleChannelCreated(_ event: [String: Any]) {
        guard let channel = event["channel"] as? [String: Any],
              let channelId = channel["id"] as? String,
              let name = channel["name"] as? String else { return }
        channelNameCache[channelId] = name

        Task {
            await joinChannel(id: channelId)
            if let resolved = resolveProject(forChannelName: name) {
                SlackFileLog.log("channel_created: #\(name) joined bound=Y")
                await postMessage(
                    channel: channelId,
                    text: "Bound to project *\(resolved.name)* → cwd `\(resolved.cwd)`. Post a message to start a session."
                )
            } else {
                SlackFileLog.log("channel_created: #\(name) joined bound=N")
                await postMessage(
                    channel: channelId,
                    text: "This channel isn't attached to a project yet. Run `/claude-project <absolute-dir> [name]` to attach a directory, or rename it to match a project."
                )
            }
        }
    }

    /// Scratch dir for inbound Slack image attachments.
    private static var slackFilesDir: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/ClaudeHUD/slack-files",
                                    isDirectory: true)
    }

    /// Download inbound image attachments via authenticated GET on `url_private`
    /// (Bearer bot token) into the scratch dir and return their local paths.
    /// Best-effort: a failed download is logged and skipped. Opportunistically
    /// prunes scratch files older than 24h on each call.
    private func downloadInboundImages(_ files: [[String: Any]]) async -> [String] {
        let images = files.filter {
            ($0["mimetype"] as? String)?.hasPrefix("image/") == true
        }
        guard !images.isEmpty, let token = botToken else { return [] }
        let dir = Self.slackFilesDir
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        Self.cleanupOldSlackFiles(in: dir)

        var paths: [String] = []
        for file in images {
            guard let urlStr = file["url_private"] as? String,
                  let url = URL(string: urlStr) else { continue }
            var req = URLRequest(url: url)
            req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
            do {
                let (data, response) = try await session.data(for: req)
                if let http = response as? HTTPURLResponse, http.statusCode != 200 {
                    SlackFileLog.log("image download http \(http.statusCode) for \(urlStr)")
                    continue
                }
                // Preserve the original extension so the Read tool recognizes the
                // image type; make the on-disk name unique with a UUID prefix.
                let original = (file["name"] as? String) ?? (file["id"] as? String) ?? "image"
                let ext = (original as NSString).pathExtension
                let base = ext.isEmpty
                    ? "\(file["filetype"] as? String ?? "img")"
                    : ext
                let unique = "\(UUID().uuidString).\(base)"
                let dest = dir.appendingPathComponent(unique)
                try data.write(to: dest)
                paths.append(dest.path)
            } catch {
                SlackFileLog.log("image download failed: \(error.localizedDescription)")
            }
        }
        if !paths.isEmpty {
            SlackFileLog.log("rx \(paths.count) image(s) -> \(dir.path)")
        }
        return paths
    }

    /// Remove scratch image files older than 24h. Silent best-effort.
    private static func cleanupOldSlackFiles(in dir: URL) {
        let cutoff = Date().addingTimeInterval(-24 * 3600)
        guard let items = try? FileManager.default.contentsOfDirectory(
            at: dir, includingPropertiesForKeys: [.contentModificationDateKey]) else { return }
        for item in items {
            let mod = (try? item.resourceValues(forKeys: [.contentModificationDateKey]))?
                .contentModificationDate
            if let mod, mod < cutoff {
                try? FileManager.default.removeItem(at: item)
            }
        }
    }

    private func handleMessage(channel: String, text rawText: String, user: String,
                               imageFiles: [[String: Any]] = [],
                               inboundThreadTs: String? = nil,
                               messageTs: String = "") async {
        // Inbound images: download any image attachments to a local scratch dir
        // and splice their paths into the turn so Claude can Read them.
        var text = rawText
        let imagePaths = await downloadInboundImages(imageFiles)
        if !imagePaths.isEmpty {
            let suffix = "The user attached image(s) at: \(imagePaths.joined(separator: ", "))"
                + " — use the Read tool to view them."
            text = text.isEmpty ? suffix : "\(text)\n\n\(suffix)"
        }
        guard let name = await channelName(for: channel) else {
            // A DM has no channel name — it is the GENERIC surface, not a drop.
            if channel.hasPrefix("D") {
                await handleDirectMessage(channelId: channel, text: text, user: user,
                                          inboundThreadTs: inboundThreadTs, messageTs: messageTs)
            } else {
                logger.debug("Could not resolve channel name for \(channel)")
                SlackFileLog.log("rx message in \(channel); channel name unresolved")
            }
            return
        }
        SlackFileLog.log("rx message in #\(name) (\(channel))")
        if !user.isEmpty { operatorUserId[channel] = user }

        // PM bang-verbs: a message beginning with `!` is a host-side command
        // (task card, briefing, Triage capture) — a vault read/write, never an
        // engine turn. These work today in every bound channel; the slash twins
        // (`/claude-tasks`, `/claude-brief`) additionally need a one-time
        // manifest save on api.slack.com.
        if text.trimmingCharacters(in: .whitespaces).hasPrefix("!") {
            await handleBangCommand(text: text, channelId: channel, user: user,
                                    threadTs: inboundThreadTs)
            return
        }

        // PER-THREAD ROUTING. A reply in a thread continues THAT thread's session;
        // a top-level message starts a NEW conversation in its own thread. Only a
        // reply can land in an existing conversation (and thus hit a parked prompt
        // or a busy turn) — a top-level message is always a fresh thread.
        if let threadRoot = inboundThreadTs {
            let conv = Conversation(channelId: channel, threadRootTs: threadRoot)

            // Thread-reply precedence (3.1): if a clarifying question is parked for
            // THIS conversation, the next reply is captured as its freeform answer.
            if captureThreadReplyAnswer(conv: conv, text: text) { return }

            guard let resolved = resolveProject(forChannelName: name) else {
                SlackFileLog.log("no match for #\(name)")
                await postMessage(
                    channel: channel,
                    text: "No ClaudeHUD project matches #\(name). Rename the channel to a project name (later this becomes the ~ catch-all).",
                    threadTs: threadRoot)
                return
            }
            SlackFileLog.log("resolved -> \(resolved.name)/\(resolved.cwd) thread=\(threadRoot)")
            // A message that lands while THIS thread's turn is running AUTO-QUEUES
            // (no Queue/Steer/Cancel prompt) — exactly like the terminal CLI queues
            // a message typed mid-turn. It runs automatically after the current
            // turn finishes. A turn in another thread does not block this one.
            //
            // BUSY = this thread's turn is in flight OR items are already queued for
            // it. Testing the queue too (not just `inFlight`) closes the FIFO hole:
            // during the brief window where a turn has resolved (inFlight cleared)
            // but its drain hasn't re-acquired the lock yet, a fresh reply must still
            // queue BEHIND the already-buffered items instead of racing ahead. The
            // busy test and the synchronous enqueue/lock below straddle NO await, so
            // the decision is atomic.
            let busy = inFlight.contains(conv.key)
                || !(followupQueue[conv.key]?.isEmpty ?? true)
            if busy {
                await autoQueueFollowup(conv: conv, text: text, resolved: resolved)
                return
            }
            // Not busy: reserve the in-flight slot SYNCHRONOUSLY (atomic with the
            // busy test above — no await in between) before running, so any racing
            // reply observes "busy" and queues behind us. runTurn runs with the lock
            // pre-held (`lockAlreadyHeld`).
            inFlight.insert(conv.key)
            await runTurn(conv: conv, channelId: channel, projectName: resolved.name,
                          cwd: resolved.cwd, obsidianPath: resolved.obsidianPath, text: text,
                          lockAlreadyHeld: true)
            return
        }

        if let resolved = resolveProject(forChannelName: name) {
            SlackFileLog.log("resolved -> \(resolved.name)/\(resolved.cwd) (new top-level conversation, thread under user msg \(messageTs))")
            // Top-level message: start a fresh conversation threaded UNDER the user's
            // OWN message (messageTs is the thread root), so Claude's reply + work are
            // replies to the user's post rather than a separate Claude channel root.
            // The conv key is the user's message ts — unique, so it can never be busy.
            let conv = messageTs.isEmpty ? nil : Conversation(channelId: channel, threadRootTs: messageTs)
            await runTurn(conv: conv, channelId: channel, projectName: resolved.name,
                          cwd: resolved.cwd, obsidianPath: resolved.obsidianPath, text: text)
        } else {
            SlackFileLog.log("no match for #\(name)")
            await postMessage(
                channel: channel,
                text: "No ClaudeHUD project matches #\(name). Rename the channel to a project name (later this becomes the ~ catch-all)."
            )
        }
    }

    // MARK: - Phase 2: turn driving (per-thread)

    /// Seed a brand-new conversation's session config from the channel defaults
    /// (mode / effort / followup / maxTurns), so the channel-scoped slash commands
    /// still shape new threads. sessionId / cwd start empty (a new thread is fresh).
    private func sessionForNewConversation(channel: String) -> ChannelSession {
        var s = ChannelSession(sessionId: nil, permissionMode: "default", cwd: nil)
        if let d = channelDefaults[channel] {
            s.permissionMode = d.permissionMode
            s.effort = d.effort
            s.followup = d.followup
            s.maxTurns = d.maxTurns
        }
        return s
    }

    /// Drive one Claude turn for a CONVERSATION (one thread). `existing == nil`
    /// starts a brand-new top-level conversation in its own thread; otherwise the
    /// turn continues `existing`'s session and posts into its thread. Each
    /// conversation has its own session id, engine, in-flight lock and queue, so
    /// different threads run in parallel without blocking one another.
    private func runTurn(conv existing: Conversation?, channelId: String,
                         projectName: String, cwd: String,
                         obsidianPath: String, text: String,
                         bypassUsageGate: Bool = false,
                         lockAlreadyHeld: Bool = false) async {
        // The thread to respond in: the existing conversation's root, or nil for a
        // brand-new top-level conversation (whose posted root opens its thread).
        let responseThreadTs = existing?.threadRootTs

        // Busy guard — only an existing conversation can already be in flight. (A
        // mid-turn reply is auto-queued upstream; this catches programmatic
        // re-entry such as Retry while still running.) When the caller pre-reserved
        // the lock (`lockAlreadyHeld` — the thread-reply and drain paths), this is
        // INTENTIONALLY held: skip the guard so we don't bail on our own reservation.
        if !lockAlreadyHeld, let existing, inFlight.contains(existing.key) {
            await postMessage(channel: channelId, text: "Busy with this thread's current turn — it'll run next.",
                              threadTs: existing.threadRootTs)
            return
        }

        // USAGE-WINDOW PRE-FLIGHT (3.5, NO dollars): before spawning, check the
        // shared subscription 5-hour window. If near-exhausted, ask (Run anyway /
        // Wait) rather than fire into a likely rate-limit rejection. For a new
        // conversation the gate card itself opens the thread.
        if !bypassUsageGate, let gate = usageGateIfNearExhausted() {
            let gateTs = await postMessage(
                channel: channelId,
                text: ":battery: Usage window nearly exhausted — decide before launching.",
                threadTs: responseThreadTs,
                blocks: SupervisorCards.usageGateCard(channelId: channelId,
                                                      utilizationPct: gate.pct, resetsHint: gate.hint))
            let threadRoot = responseThreadTs ?? gateTs ?? "pending-\(Date().timeIntervalSince1970)"
            let conv = Conversation(channelId: channelId, threadRootTs: threadRoot)
            usageHolds[conv.key] = UsageHold(conv: conv, projectName: projectName, cwd: cwd,
                                             obsidianPath: obsidianPath, text: text, rootTs: gateTs)
            // Releasing a pre-held lock here (this is an early return BEFORE the defer
            // that would otherwise clear it) so the conversation isn't wedged busy
            // while parked on the usage gate — Run-anyway re-enters cleanly later.
            if lockAlreadyHeld, let existing { inFlight.remove(existing.key) }
            SlackFileLog.log("usage gate: held launch \(conv.key) at \(gate.pct)% (resets \(gate.hint))")
            return
        }

        // Reserve the in-flight slot for an existing conversation immediately, so a
        // racing reply observes "busy" while we post the root.
        if let existing { inFlight.insert(existing.key) }

        let startedAt = Date()

        // Session state: the existing conversation's, or a fresh one seeded from the
        // channel defaults for a brand-new thread.
        var state = existing.flatMap { channelSessions[$0.key] }
            ?? sessionForNewConversation(channel: channelId)

        // CWD-AWARE SESSIONS: a session id only resumes in the cwd's own
        // `~/.claude/projects` store. If the resolved cwd changed since the session
        // was created (or none was recorded), the stored session is stranded.
        if state.sessionId != nil, state.cwd != cwd {
            SlackFileLog.log("cwd changed (\(state.cwd ?? "none") -> \(cwd)); starting fresh session")
            state.sessionId = nil
        }
        let isFresh = state.sessionId == nil

        // Dials for this turn, read directly off the (possibly seeded) state so the
        // key need not exist yet.
        let turnEffort: String = {
            let e = state.effort ?? Self.defaultEffort
            return ClaudeCLIClient.effortLevels.contains(e) ? e : Self.defaultEffort
        }()
        let turnMode = state.permissionMode
        let turnCap = existing.flatMap { turnCapOverride[$0.key] } ?? state.maxTurns ?? Self.defaultMaxTurns
        // Generation supersedes the prior one for the SAME conversation (1 for a new).
        let generation = (existing.map { channelGeneration[$0.key] ?? 0 } ?? 0) + 1

        let turn = InFlightTurn(channelId: channelId, threadRootTs: responseThreadTs ?? "",
                                rootTs: nil, request: text, projectName: projectName, cwd: cwd,
                                obsidianPath: obsidianPath, generation: generation, startedAt: startedAt,
                                effort: turnEffort, permissionMode: turnMode)

        // CHECKPOINT (1.7): snapshot the working tree before the agent edits it.
        let checkpoint = await GitCheckpointService.make(cwd: cwd)
        turn.checkpoint = checkpoint

        let freshOutgoing = Self.contextPreamble(projectName: projectName, cwd: cwd,
                                                 obsidianPath: obsidianPath, userText: text)

        // Post the ROOT — top-level for a new conversation (opening its thread), or
        // as a reply into the existing thread. Its ts finalizes a new conversation's
        // key (the thread root == this root for the first turn).
        SlackFileLog.log("runTurn: convKey=\(existing?.key ?? "new") responseThreadTs=\(responseThreadTs ?? "nil") lockHeld=\(lockAlreadyHeld) posting root")
        let rootTs = await postMessage(
            channel: channelId,
            text: "\(TurnState.working.icon) Working…",
            threadTs: responseThreadTs,
            blocks: workingBlocks(turn: turn, now: startedAt, warning: false, stopping: false)
        )
        let threadRoot = responseThreadTs ?? rootTs ?? "pending-\(startedAt.timeIntervalSince1970)"
        turn.threadRootTs = threadRoot
        turn.rootTs = rootTs
        let key = Self.convKey(channelId, threadRoot)
        let conv = Conversation(channelId: channelId, threadRootTs: threadRoot)
        SlackFileLog.log("runTurn: key=\(key) rootTs=\(rootTs ?? "nil") gen=\(generation) resume=\(isFresh ? "N" : "Y") mode=\(turnMode) effort=\(turnEffort)")

        // Keyed registration (now that the conversation key is final).
        inFlight.insert(key)
        stopRequested.remove(key)
        timeoutRequested.remove(key)
        channelGeneration[key] = generation
        lastConversation[channelId] = threadRoot
        lastTurns[key] = LastTurn(projectName: projectName, cwd: cwd,
                                  obsidianPath: obsidianPath, text: text)
        turnCapOverride.removeValue(forKey: key)
        inFlightTurns[key] = turn
        ensureHeartbeat()
        persistInFlight()
        // Generation hygiene (3.4): supersede any straggler parked prompt for this
        // conversation with its safe default before the new generation's land.
        await cancelParkedPrompts(conv: conv)

        // The state this turn resolves to, read by the deferred follow-up drain so
        // a queued mid-turn message auto-runs next.
        var resolvedState: TurnState = .failed
        defer {
            inFlight.remove(key)
            stopRequested.remove(key)
            timeoutRequested.remove(key)
            inFlightTurns.removeValue(forKey: key)
            persistInFlight()
            let term = resolvedState
            Task { @MainActor in await self.drainFollowupQueue(conv: conv, lastTerminal: term) }
        }

        if let rootTs {
            await mirrorReaction(channel: channelId, ts: rootTs, to: .working, turn: turn)
        }

        // Persist the checkpoint under the root ts (its Show-diff/Undo button key).
        if let cp = checkpoint, cp.isCapturable, let rootTs {
            checkpoints[rootTs] = cp
            saveCheckpoints()
            if cp.dirtyAtStart {
                SlackFileLog.log("checkpoint: \(key) tree was dirty before turn")
                await postMessage(
                    channel: channelId,
                    text: ":information_source: Working tree had uncommitted changes before this turn — Undo restores to this pre-turn snapshot, not a clean tree.",
                    threadTs: rootTs)
            }
        }

        do {
            var run = try await runEngine(
                conv: conv,
                message: isFresh ? freshOutgoing : text,
                permissionMode: state.permissionMode,
                effort: turnEffort,
                sessionId: state.sessionId,
                cwd: cwd,
                maxTurns: turnCap
            )

            // EMPTY-RESUME AUTO-RETRY: a resumed turn that returns empty usually
            // means the session was stranded in this cwd's store. Retry ONCE fresh.
            // Skip on Stop (a stopped resume also returns empty).
            if !isFresh, run.text.isEmpty, !stopRequested.contains(key) {
                SlackFileLog.log("empty resume result; retried fresh")
                state.sessionId = nil
                run = try await runEngine(
                    conv: conv,
                    message: freshOutgoing,
                    permissionMode: state.permissionMode,
                    effort: turnEffort,
                    sessionId: nil,
                    cwd: cwd,
                    maxTurns: turnCap
                )
            }

            let finalText = Self.toSlackMrkdwn(run.text)
            let toolCounts = run.tools

            if !run.result.sessionId.isEmpty {
                state.sessionId = run.result.sessionId
                state.cwd = cwd
                channelSessions[key] = state
                saveChannelSessions()
            }

            let toolTotal = toolCounts.values.reduce(0, +)
            let summary = Self.toolSummary(toolCounts)

            // TURN-CAP GUARDRAIL (3.5): the engine hit `--max-turns`. A DECISION,
            // not a failure — park on a Continue/Stop card.
            if run.result.subtype == "error_max_turns",
               !stopRequested.contains(key), !timeoutRequested.contains(key) {
                resolvedState = .needsYou
                turn.resolved = true
                await finalizeTrail(key)
                await finalizeTree(key, tokens: run.result.inputTokens + run.result.outputTokens)
                budgetHolds[key] = BudgetHold(conv: conv, projectName: projectName, cwd: cwd,
                                              obsidianPath: obsidianPath, text: text,
                                              rootTs: rootTs, cap: turnCap)
                let doneSoFar = finalText.isEmpty ? summary : finalText
                await renderTurnCapHold(channelId: channelId, rootTs: rootTs, request: text,
                                        cap: turnCap, doneSoFar: doneSoFar)
                if let rootTs {
                    await mirrorReaction(channel: channelId, ts: rootTs, to: .needsYou, turn: turn)
                }
                SlackFileLog.log("turn-cap hit: \(key) cap=\(turnCap); offered Continue/Stop")
                return
            }

            let terminal: TurnState
            if timeoutRequested.contains(key) {
                terminal = .failed
            } else if stopRequested.contains(key) || run.result.interrupted {
                terminal = .stopped
            } else if run.result.isError {
                terminal = .failed
            } else {
                terminal = .done
            }
            resolvedState = terminal
            SlackFileLog.log("turn resolved: \(key) state=\(terminal.rawValue) session=\(run.result.sessionId.prefix(8)) tools=\(toolTotal) chars=\(finalText.count)")

            turn.resolved = true
            await finalizeTrail(key)
            await finalizeTree(key, tokens: run.result.inputTokens + run.result.outputTokens)

            if terminal == .failed {
                let timedOut = timeoutRequested.contains(key)
                let detail = timedOut
                    ? "Wall-clock timeout: the turn ran past \(Int(Self.wallClockTimeout / 60)) minutes and was stopped."
                    : (run.result.result.isEmpty ? "The engine returned an error result." : run.result.result)
                await renderFailed(channelId: channelId, rootTs: rootTs, request: text,
                                   summary: summary, partialText: finalText,
                                   subtype: timedOut ? "error_timeout" : run.result.subtype,
                                   detail: detail, turn: turn)
                if let rootTs {
                    await mirrorReaction(channel: channelId, ts: rootTs, to: .failed, turn: turn)
                }
                return
            }

            var body: String
            if finalText.isEmpty {
                body = summary
            } else {
                body = summary.isEmpty ? finalText : "\(summary)\n\n\(finalText)"
            }
            if body.isEmpty {
                body = terminal == .stopped ? "Stopped. Any partial edits remain on disk." : "(no output)"
            }

            let statusLine: String
            switch terminal {
            case .stopped:
                statusLine = "partial work kept"
            default:
                statusLine = Self.badge(durationMs: run.result.durationMs, tools: toolTotal,
                                        tokens: run.result.inputTokens + run.result.outputTokens)
            }

            await renderTerminal(channelId: channelId, convKey: key, rootTs: rootTs, state: terminal,
                                 request: text, statusLine: statusLine, body: body)
            if let rootTs {
                await mirrorReaction(channel: channelId, ts: rootTs, to: terminal, turn: turn)
            }
        } catch {
            SlackFileLog.log("turn error: \(key) \(error.localizedDescription)")
            turn.resolved = true
            await finalizeTrail(key)
            await finalizeTree(key)
            if stopRequested.contains(key) && !timeoutRequested.contains(key) {
                resolvedState = .stopped
                await renderTerminal(channelId: channelId, convKey: key, rootTs: rootTs, state: .stopped,
                                     request: text, statusLine: "partial work kept",
                                     body: "Stopped. Any partial edits remain on disk.")
                if let rootTs {
                    await mirrorReaction(channel: channelId, ts: rootTs, to: .stopped, turn: turn)
                }
            } else {
                resolvedState = .failed
                let timedOut = timeoutRequested.contains(key)
                let detail = timedOut
                    ? "Wall-clock timeout: the turn ran past \(Int(Self.wallClockTimeout / 60)) minutes and was stopped."
                    : error.localizedDescription
                await renderFailed(channelId: channelId, rootTs: rootTs, request: text,
                                   summary: "", partialText: "",
                                   subtype: timedOut ? "error_timeout" : "error_during_execution",
                                   detail: detail, turn: turn)
                if let rootTs {
                    await mirrorReaction(channel: channelId, ts: rootTs, to: .failed, turn: turn)
                }
            }
        }
    }

    // MARK: - Phase 1.2/1.3: root rendering + control bar

    /// Build the channel ROOT message blocks: a single self-sufficient status
    /// line, the quoted request (so the ledger is self-describing when
    /// collapsed), an optional result body, and the control bar. This is the
    /// notification surface — terse, no tool noise, detail lives in the thread.
    private func rootBlocks(state: TurnState, request: String, statusLine: String,
                            body: String?, buttons: [[String: Any]],
                            provenance: String? = nil) -> [[String: Any]] {
        var blocks: [[String: Any]] = []
        blocks.append(SlackBlocks.section("\(state.icon)  *\(state.label)*  ·  \(statusLine)"))
        blocks.append(SlackBlocks.context("> \(SlackBlocks.truncate(Self.singleLine(request), 280))"))
        if let provenance { blocks.append(SlackBlocks.context(provenance)) }
        if let body, !body.isEmpty {
            blocks.append(SlackBlocks.section(body))
        }
        if !buttons.isEmpty {
            blocks.append(SlackBlocks.actions(buttons))
        }
        return blocks
    }

    /// The control bar for each state. Buttons carry stable `action_id`s (§1.1),
    /// never presentational text. When `checkpointKey` is non-nil (cwd is a git
    /// repo and a pre-turn snapshot was taken) the terminal states also offer the
    /// git affordances (1.7); the question/permission cards arrive in Phase 3.
    private func controlBar(for state: TurnState, checkpointKey: String? = nil) -> [[String: Any]] {
        // Show diff / Undo turn, rendered only when there is a checkpoint to act
        // on. The key (the turn's root ts) rides in the button `value`.
        var git: [[String: Any]] = []
        if let key = checkpointKey {
            git = [
                SlackBlocks.button(text: ":mag: Show diff", actionId: SlackAction.showDiff, value: key),
                SlackBlocks.button(text: ":leftwards_arrow_with_hook: Undo turn", actionId: SlackAction.undoTurn, value: key)
            ]
        }
        switch state {
        case .working:
            return [SlackBlocks.button(text: ":octagonal_sign: Stop",
                                       actionId: SlackAction.stop, style: "danger")]
        case .done:
            return [
                SlackBlocks.button(text: ":arrows_counterclockwise: Retry", actionId: SlackAction.retry)
            ] + git + [
                SlackBlocks.button(text: ":+1:", actionId: SlackAction.feedbackUp),
                SlackBlocks.button(text: ":-1:", actionId: SlackAction.feedbackDown)
            ]
        case .failed:
            return [SlackBlocks.button(text: ":arrows_counterclockwise: Retry", actionId: SlackAction.retry)] + git
        case .stopped:
            return [
                SlackBlocks.button(text: ":arrows_counterclockwise: Resume from here",
                                   actionId: SlackAction.resume),
                SlackBlocks.button(text: ":pencil2: Resume with changes",
                                   actionId: SlackAction.resumeWithChanges)
            ] + git
        case .needsYou:
            return []   // Phase 3 supplies the answer/permission buttons
        case .interrupted:
            return [SlackBlocks.button(text: ":arrows_counterclockwise: Resume", actionId: SlackAction.resume)] + git
        }
    }

    /// Swap the root in place to its terminal state (a `chat.update`, not a new
    /// post, so the anchor ts is stable). A body that overruns a section is
    /// truncated in the root and the FULL output is posted into the turn's
    /// THREAD — detail flows down in altitude, the root stays scannable. If the
    /// root post failed (no ts), post the terminal card fresh as a fallback so
    /// the turn is still never left unresolved.
    private func renderTerminal(channelId: String, convKey: String? = nil, rootTs: String?, state: TurnState,
                                request: String, statusLine: String, body: String) async {
        let headCap = SlackBlocks.sectionLimit - 100
        var rootBody = body
        var overflow: String? = nil
        if body.count > headCap {
            rootBody = SlackBlocks.truncate(body, headCap) + "\n\n_(full output in thread ↓)_"
            overflow = body
        }
        // Offer the git affordances only when this turn actually has a checkpoint
        // (its root ts is the key). Hidden for non-repo cwds.
        let cpKey: String? = {
            if let ts = rootTs, checkpoints[ts] != nil { return ts }
            return nil
        }()
        // Carry the provenance line (effort/mode/project) onto the terminal card
        // too, read from the still-live in-flight record (2.3 "surface it").
        let provenance: String? = {
            guard let k = convKey, let t = inFlightTurns[k] else { return nil }
            return Self.provenanceLine(project: t.projectName, mode: t.permissionMode, effort: t.effort)
        }()
        // The single turn message keeps Show details / Show reasoning on the
        // terminal card (the trail was retired to `trailsByRoot` just before this).
        let (_, trailButtons) = trailSummaryAndButtons(forRoot: rootTs)
        let blocks = rootBlocks(state: state, request: request, statusLine: statusLine,
                                body: rootBody,
                                buttons: controlBar(for: state, checkpointKey: cpKey) + trailButtons,
                                provenance: provenance)
        let fallback = "\(state.icon) \(state.label) · \(statusLine)"

        let anchorTs: String?
        if let ts = rootTs {
            await chatUpdate(channel: channelId, ts: ts, text: fallback, blocks: blocks)
            anchorTs = ts
        } else {
            anchorTs = await postMessage(channel: channelId, text: fallback, blocks: blocks)
        }

        if let overflow, let ts = anchorTs {
            for chunk in Self.splitChunks(overflow) {
                await postMessage(channel: channelId, text: chunk, threadTs: ts)
            }
        }
    }

    // MARK: - Phase 3.5: budget / turn + usage-window guardrails (NO dollars)

    /// The 5-hour usage window's headroom check (3.5). Returns the rounded
    /// utilization % and a human "resets in …" hint when the window is at/above the
    /// near-exhausted threshold; nil when there's headroom or no reading at all
    /// (degrade to launching, never block on a missing number).
    private func usageGateIfNearExhausted() -> (pct: Int, hint: String)? {
        guard let w = usageService.usage?.fiveHour, w.utilization >= Self.usageNearExhaustedPct else {
            return nil
        }
        return (Int(w.utilization.rounded()), Self.resetsHint(w.resetsAt))
    }

    /// "in 23m" / "in 1h 5m" / "soon" for a window reset timestamp.
    private static func resetsHint(_ resetsAt: Date?) -> String {
        guard let resetsAt else { return "" }
        let secs = Int(resetsAt.timeIntervalSinceNow)
        if secs <= 0 { return "any moment" }
        let mins = secs / 60
        if mins < 60 { return "in \(max(1, mins))m" }
        return "in \(mins / 60)h \(mins % 60)m"
    }

    /// Render the turn-cap Continue/Stop card on the root (3.5). The turn is paused
    /// on a DECISION, not failed: partial work is kept and the operator chooses.
    private func renderTurnCapHold(channelId: String, rootTs: String?, request: String,
                                   cap: Int, doneSoFar: String) async {
        var blocks: [[String: Any]] = [
            SlackBlocks.section(":vertical_traffic_light:  *Hit the turn cap (\(cap) turn\(cap == 1 ? "" : "s"))*  ·  paused"),
            SlackBlocks.context("> \(SlackBlocks.truncate(Self.singleLine(request), 280))")
        ]
        blocks.append(contentsOf: SupervisorCards.turnCapCard(channelId: channelId, cap: cap,
                                                              addend: Self.turnCapAddend,
                                                              doneSoFar: Self.toSlackMrkdwn(doneSoFar)).dropFirst())
        let fallback = ":vertical_traffic_light: Hit the turn cap (\(cap) turns) — Continue or Stop?"
        if let ts = rootTs {
            await chatUpdate(channel: channelId, ts: ts, text: fallback, blocks: blocks)
        } else {
            await postMessage(channel: channelId, text: fallback, blocks: blocks)
        }
        // Escalate a push: a paused turn that needs a decision must reach a phone.
        if let op = operatorUserId[channelId], let ts = rootTs {
            await postMessage(channel: channelId,
                              text: "<@\(op)> :vertical_traffic_light: A turn hit its cap and needs a Continue/Stop decision.",
                              threadTs: ts)
        }
    }

    /// Continue from a turn-cap hold (3.5): re-run the held turn with a raised cap
    /// (`--resume` continues the same session). Consumed once.
    private func continueFromTurnCap(conv: Conversation) async {
        guard let hold = budgetHolds.removeValue(forKey: conv.key) else {
            SlackFileLog.log("budget continue: no hold for \(conv.key)")
            return
        }
        guard !inFlight.contains(conv.key) else {
            SlackFileLog.log("budget continue: busy, ignoring \(conv.key)")
            return
        }
        turnCapOverride[conv.key] = hold.cap + Self.turnCapAddend
        SlackFileLog.log("budget continue: \(conv.key) cap \(hold.cap) -> \(hold.cap + Self.turnCapAddend)")
        // Clear the old turn-cap card's buttons + reaction so they can't be tapped
        // again while the continuation runs (the continuation posts its own root).
        if let ts = hold.rootTs {
            await chatUpdate(channel: conv.channelId, ts: ts, text: "Continuing…",
                             blocks: [SlackBlocks.section(":arrows_counterclockwise: Continuing with +\(Self.turnCapAddend) turns — see the new turn below.")])
            await reactionRemove(channel: conv.channelId, ts: ts, name: TurnState.needsYou.reactionName)
        }
        await runTurn(conv: hold.conv, channelId: conv.channelId, projectName: hold.projectName,
                      cwd: hold.cwd, obsidianPath: hold.obsidianPath, text: hold.text, bypassUsageGate: true)
    }

    /// Stop at a turn-cap hold (3.5): resolve the root to a clean Stopped-by-you so
    /// the ledger closes and the follow-up queue can drain.
    private func stopAtTurnCap(conv: Conversation) async {
        guard let hold = budgetHolds.removeValue(forKey: conv.key) else { return }
        SlackFileLog.log("budget stop: \(conv.key)")
        await renderTerminal(channelId: conv.channelId, rootTs: hold.rootTs, state: .stopped,
                             request: hold.text, statusLine: "stopped at the turn cap · partial work kept",
                             body: "Stopped at the turn cap. Any partial edits remain on disk; Resume to continue.")
        if let ts = hold.rootTs {
            // The hold card carried the Needs-you glyph; swap it to Stopped.
            await reactionRemove(channel: conv.channelId, ts: ts, name: TurnState.needsYou.reactionName)
            await reactionAdd(channel: conv.channelId, ts: ts, name: TurnState.stopped.reactionName)
        }
        // The follow-up queue was already drained (held) when the turn-cap hold
        // resolved via runTurn's defer; nothing more to drain here.
    }

    /// Operator chose Run-anyway on the usage gate (3.5): re-enter the launch with
    /// the headroom check bypassed.
    private func resolveUsageGate(conv: Conversation, run: Bool) async {
        guard let hold = usageHolds.removeValue(forKey: conv.key) else {
            SlackFileLog.log("usage gate: no hold for \(conv.key)")
            return
        }
        if run {
            SlackFileLog.log("usage gate: \(conv.key) Run anyway")
            // Clear the gate card so it isn't left as a dangling prompt; the new
            // turn posts its own root.
            if let ts = hold.rootTs {
                await chatUpdate(channel: conv.channelId, ts: ts, text: "Launching…",
                                 blocks: [SlackBlocks.section(":arrow_forward: Running despite the usage window — launching.")])
            }
            await runTurn(conv: hold.conv, channelId: conv.channelId, projectName: hold.projectName,
                          cwd: hold.cwd, obsidianPath: hold.obsidianPath, text: hold.text, bypassUsageGate: true)
        } else {
            SlackFileLog.log("usage gate: \(conv.key) Wait")
            lastTurns[conv.key] = LastTurn(projectName: hold.projectName, cwd: hold.cwd,
                                           obsidianPath: hold.obsidianPath, text: hold.text)
            let blocks: [[String: Any]] = [
                SlackBlocks.section(":hourglass: *Waiting on the usage window*  ·  not launched"),
                SlackBlocks.context("> \(SlackBlocks.truncate(Self.singleLine(hold.text), 280))"),
                SlackBlocks.actions([
                    SlackBlocks.button(text: ":arrows_counterclockwise: Retry now",
                                       actionId: SlackAction.retry, style: "primary")
                ])
            ]
            if let ts = hold.rootTs {
                await chatUpdate(channel: conv.channelId, ts: ts,
                                 text: "Waiting on the usage window.", blocks: blocks)
            }
        }
    }

    // MARK: - Phase 3.6: graceful failure

    /// Classify a failure into retry guidance copy. Distinguishes a transient,
    /// retriable condition (rate limit / overloaded / timeout) from a permanent
    /// limitation (a disallowed tool in this mode) from a generic error.
    private enum FailureClass { case rateLimit, timeout, permanent, transient }
    private static func classifyFailure(subtype: String?, detail: String) -> FailureClass {
        let d = detail.lowercased()
        if subtype == "error_timeout" { return .timeout }
        if d.contains("rate limit") || d.contains("rate_limit") || d.contains("429")
            || d.contains("overloaded") || d.contains("529") || d.contains("too many requests") {
            return .rateLimit
        }
        if d.contains("disallowed") || d.contains("not allowed") || d.contains("permission denied")
            || subtype == "error_max_budget_usd" {
            return .permanent
        }
        return .transient
    }

    /// Render the graceful-failure card (3.6): completed-then-failed summary, a
    /// transient/permanent distinction, the full error stashed behind Show-error,
    /// and Retry / Retry-with-changes / Undo affordances — never a hung spinner.
    private func renderFailed(channelId: String, rootTs: String?, request: String,
                              summary: String, partialText: String,
                              subtype: String?, detail: String, turn: InFlightTurn) async {
        let klass = Self.classifyFailure(subtype: subtype, detail: detail)
        // Stash the full error for the Show-error modal (keyed by root ts).
        if let ts = rootTs {
            failureDetails[ts] = detail
            if failureDetails.count > Self.maxFailureDetails {
                // Evict oldest by simple count trim (cards persist in Slack anyway).
                for k in failureDetails.keys.prefix(failureDetails.count - Self.maxFailureDetails) {
                    failureDetails.removeValue(forKey: k)
                }
            }
        }

        let statusLine: String
        let headNote: String
        switch klass {
        case .timeout:
            statusLine = "timed out"
            headNote = ":alarm_clock: The turn ran too long and was stopped. Retry to pick it up again."
        case .rateLimit:
            let hint = usageService.usage?.fiveHour.map {
                " (5h window at \(Int($0.utilization.rounded()))%, resets \(Self.resetsHint($0.resetsAt)))"
            } ?? ""
            statusLine = "rate limited"
            headNote = ":battery: Hit a rate limit\(hint). This is transient — Retry, ideally after the window resets."
        case .permanent:
            statusLine = "blocked"
            headNote = ":no_entry: A permanent limitation, not a transient error — Retry alone won't fix it. Use Retry with changes to adjust the approach or mode."
        case .transient:
            statusLine = "error"
            headNote = ":x: The turn failed. Retry, or Retry with changes to adjust before re-running."
        }

        var bodyParts: [String] = []
        if !summary.isEmpty { bodyParts.append("Completed: \(summary)") }
        if !partialText.isEmpty {
            bodyParts.append(SlackBlocks.truncate(Self.toSlackMrkdwn(partialText), 800))
        }
        bodyParts.append(headNote)
        let body = bodyParts.joined(separator: "\n\n")

        // Buttons: Show error (opens the stashed stderr), Retry, Retry with
        // changes, plus Undo turn when this turn has a git checkpoint.
        var buttons: [[String: Any]] = []
        if let ts = rootTs, failureDetails[ts] != nil {
            buttons.append(SlackBlocks.button(text: ":mag: Show error",
                                              actionId: SlackAction.showError, value: ts))
        }
        buttons.append(SlackBlocks.button(text: ":arrows_counterclockwise: Retry",
                                          actionId: SlackAction.retry, style: "primary"))
        buttons.append(SlackBlocks.button(text: ":pencil2: Retry with changes",
                                          actionId: SlackAction.retryWithChanges))
        if let ts = rootTs, checkpoints[ts] != nil {
            buttons.append(SlackBlocks.button(text: ":leftwards_arrow_with_hook: Undo turn",
                                              actionId: SlackAction.undoTurn, value: ts))
        }
        // Keep the folded-in Show details / Show reasoning on the failed card too,
        // so a failed turn's actions remain inspectable (one message, no trail).
        let (_, trailButtons) = trailSummaryAndButtons(forRoot: rootTs)
        buttons += trailButtons

        let provenance = Self.provenanceLine(project: turn.projectName,
                                             mode: turn.permissionMode, effort: turn.effort)
        let blocks = rootBlocks(state: .failed, request: request, statusLine: statusLine,
                                body: body, buttons: buttons, provenance: provenance)
        let fallback = ":x: Failed · \(statusLine)"
        if let ts = rootTs {
            await chatUpdate(channel: channelId, ts: ts, text: fallback, blocks: blocks)
        } else {
            await postMessage(channel: channelId, text: fallback, blocks: blocks)
        }
        SlackFileLog.log("failed render: #\(channelId) class=\(klass) subtype=\(subtype ?? "nil")")
    }

    /// Open the full error behind Show-error (3.6), secret-light: the stashed text
    /// is the engine's own stderr/result, posted into the thread (size-capped).
    private func showError(rootTs: String, channelId: String, threadTs: String) async {
        guard let detail = failureDetails[rootTs], !detail.isEmpty else {
            await postMessage(channel: channelId, text: "No further error detail was captured.",
                              threadTs: threadTs)
            return
        }
        for chunk in Self.splitChunks("```\n\(SlackBlocks.truncate(detail, 6000))\n```") {
            await postMessage(channel: channelId, text: chunk, threadTs: threadTs)
        }
    }

    /// Collapse a multi-line request to one line for the root's quoted recap.
    private static func singleLine(_ s: String) -> String {
        s.replacingOccurrences(of: "\n", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Status badge for the root. Subscription-billed engine ⇒ TOKENS, not
    /// dollars (NO dollar reporting). e.g. `38s · 4 tools · 12.3k tokens`.
    private static func badge(durationMs: Int, tools: Int, tokens: Int) -> String {
        var parts: [String] = []
        if durationMs > 0 { parts.append(formatDuration(durationMs)) }
        parts.append("\(tools) tool\(tools == 1 ? "" : "s")")
        if tokens > 0 { parts.append(formatTokens(tokens)) }
        return parts.joined(separator: " · ")
    }

    private static func formatDuration(_ ms: Int) -> String {
        let s = ms / 1000
        if s < 60 { return "\(s)s" }
        return String(format: "%d:%02d", s / 60, s % 60)
    }

    private static func formatTokens(_ n: Int) -> String {
        if n >= 1000 { return String(format: "%.1fk tokens", Double(n) / 1000) }
        return "\(n) tokens"
    }

    // MARK: - Phase 1.5: liveness heartbeat + watchdog

    /// The working root's live status line (1.5). Three variants:
    ///  - normal:   `Working… · last action 4s ago · 18 tools · 1:42`
    ///  - warning:  `:warning: Still working · last activity 47s ago · 1:42` (+ Force-stop)
    ///  - stopping: `Stopping… · killing the turn` (no button — kill is in flight)
    /// Sparse progress reads as stuck, so the root always carries a freshness age.
    private func workingBlocks(turn: InFlightTurn, now: Date,
                               warning: Bool, stopping: Bool) -> [[String: Any]] {
        let elapsed = Self.formatDuration(Int(now.timeIntervalSince(turn.startedAt) * 1000))
        let silence = Int(now.timeIntervalSince(turn.lastEventAt))

        let head: String
        var buttons: [[String: Any]] = []
        if stopping {
            head = "\(TurnState.working.icon)  *Stopping…*  ·  killing the turn"
        } else if warning {
            head = ":warning:  *Still working*  ·  last activity \(silence)s ago  ·  \(elapsed)"
            buttons = [SlackBlocks.button(text: ":octagonal_sign: Force-stop",
                                          actionId: SlackAction.stop, style: "danger")]
        } else {
            let tools = "\(turn.toolCount) tool\(turn.toolCount == 1 ? "" : "s")"
            head = "\(TurnState.working.icon)  *Working…*  ·  last action \(silence)s ago  ·  \(tools)  ·  \(elapsed)"
            buttons = [SlackBlocks.button(text: ":octagonal_sign: Stop",
                                          actionId: SlackAction.stop, style: "danger")]
        }

        var blocks: [[String: Any]] = [
            SlackBlocks.section(head),
            SlackBlocks.context("> \(SlackBlocks.truncate(Self.singleLine(turn.request), 280))"),
            SlackBlocks.context(Self.provenanceLine(project: turn.projectName,
                                                    mode: turn.permissionMode, effort: turn.effort))
        ]
        // One-message turn: the activity trail is folded INTO this root tile as a
        // single counts-only line (NO inline action list, NO inline thinking) plus
        // the Show-details / Show-reasoning affordances — the full log lives only
        // behind those modals now.
        let (summary, extraButtons) = trailSummaryAndButtons(forRoot: turn.rootTs)
        if let summary { blocks.append(SlackBlocks.context(summary)) }
        let allButtons = buttons + extraButtons
        if !allButtons.isEmpty { blocks.append(SlackBlocks.actions(allButtons)) }
        return blocks
    }

    /// The trail's one-line activity summary (":gear: N actions · M subagents",
    /// counts only) and its Show-details / Show-reasoning buttons, folded into the
    /// single turn message. Resolves the live trail (running) or the retired trail
    /// (resolved) by root ts. Returns (nil, []) when there's nothing trail-worthy.
    private func trailSummaryAndButtons(forRoot rootTs: String?) -> (summary: String?, buttons: [[String: Any]]) {
        guard let rootTs, let trail = trail(forRoot: rootTs), !trail.isEmpty else { return (nil, []) }
        var parts: [String] = []
        if trail.actionCount > 0 {
            parts.append("\(trail.actionCount) action\(trail.actionCount == 1 ? "" : "s")")
        }
        if trail.subagentCount > 0 {
            parts.append("\(trail.subagentCount) subagent\(trail.subagentCount == 1 ? "" : "s")")
        }
        let summary = parts.isEmpty ? nil : ":gear: \(parts.joined(separator: "  ·  "))"
        var buttons: [[String: Any]] = []
        if trail.hasShowableDetails {
            buttons.append(SlackBlocks.button(text: ":file_folder: Show details",
                                              actionId: SlackAction.showDetails, value: rootTs))
        }
        if trail.hasThinking {
            buttons.append(SlackBlocks.button(text: ":brain: Show reasoning",
                                              actionId: SlackAction.showReasoning, value: rootTs))
        }
        return (summary, buttons)
    }

    /// Faint provenance/context line carried on a turn's root: where it came
    /// from and the dials it ran under, so `effort` is visible on every turn
    /// (2.3 "surface it"; the fuller provenance stamp is Phase 6).
    private static func provenanceLine(project: String, mode: String, effort: String) -> String {
        "_via Slack · \(project) · \(mode) · effort=\(effort)_"
    }

    /// Start the single long-lived heartbeat loop (idempotent). Every 5s it
    /// re-renders each live working root so its age advances, and flips a turn
    /// silent for ≥45s to the watchdog warning with a Force-stop — distinguishing
    /// a genuinely stalled process from a merely slow one. It never KILLS a turn:
    /// runaway-but-active loops are the wall-clock/budget guards' job (E5, Phase
    /// 3.5); the watchdog only catches SILENCE.
    private func ensureHeartbeat() {
        guard !heartbeatRunning else { return }
        heartbeatRunning = true
        SlackFileLog.log("heartbeat loop started")
        Task { @MainActor in
            while heartbeatRunning {
                try? await Task.sleep(nanoseconds: 5_000_000_000)
                await tickHeartbeat()
            }
        }
    }

    /// One heartbeat pass: refresh every live working root that isn't resolved
    /// or mid-stop.
    private func tickHeartbeat() async {
        // The flat trail now folds into the root tile, and the per-turn root
        // repaint below flushes its latest summary every tick — so no separate
        // trail backstop is needed. Keep the subagent-tree backstop (§4.1): a
        // final fan-out batch landing inside the debounce window then falling
        // silent still gets painted on its own tree message.
        for key in Array(subagentTrees.keys) where subagentTrees[key]?.dirty == true {
            await renderTree(key)
        }

        guard !inFlightTurns.isEmpty else { return }
        let now = Date()
        for (key, turn) in inFlightTurns {
            guard let ts = turn.rootTs, !turn.stopping, !turn.resolved else { continue }
            // A turn parked on a supervisory prompt (Phase 3) is Needs-you, not
            // silent-working: the watchdog must not paint it "still working" while
            // it waits on the operator. The Needs-you root is owned by the spine.
            // A parked turn is also exempt from the wall-clock cap — the operator,
            // not the agent, owns the clock while it waits on a decision.
            if turn.parked { continue }
            // WALL-CLOCK CAP (3.6 / E5): a runaway-but-ACTIVE loop never trips the
            // silence watchdog, so a hard per-turn wall-clock timeout force-kills it
            // and resolves to Failed (timed out). Fire once per turn.
            if !timeoutRequested.contains(key),
               now.timeIntervalSince(turn.startedAt) >= Self.wallClockTimeout {
                SlackFileLog.log("watchdog: \(key) exceeded wall-clock \(Int(Self.wallClockTimeout))s; force-stopping")
                await forceTimeout(conv: turn.conv)
                continue
            }
            let silence = now.timeIntervalSince(turn.lastEventAt)
            let warning = silence >= 45
            if warning && !turn.warned {
                turn.warned = true
                SlackFileLog.log("watchdog: \(key) silent \(Int(silence))s; surfaced warning + Force-stop")
            } else if !warning && turn.warned {
                turn.warned = false
            }
            await chatUpdate(channel: turn.channelId, ts: ts, text: "Working…",
                             blocks: workingBlocks(turn: turn, now: now, warning: warning, stopping: false))
        }
    }

    // MARK: - Phase 1.6: durable in-flight registry + crash reconciliation

    private static var registryFileURL: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/ClaudeHUD/slack-inflight.json")
    }

    /// Mirror the live in-flight turns to disk (1.6). Resolved turns are excluded
    /// so a turn that finished cleanly is never reconciled to Interrupted. Writes
    /// 0600 and atomically. Cheap and called only at lifecycle edges (start,
    /// spawn, session-id capture, resolve), never per stream event.
    private func persistInFlight() {
        let map: [String: PersistedTurn] = inFlightTurns.compactMapValues { t in
            guard !t.resolved else { return nil }
            return PersistedTurn(channelId: t.channelId, threadRootTs: t.threadRootTs,
                                 rootTs: t.rootTs, sessionId: t.sessionId,
                                 pid: t.pid, pgid: t.pgid, startedAt: t.startedAt,
                                 generation: t.generation, request: t.request,
                                 projectName: t.projectName, cwd: t.cwd, obsidianPath: t.obsidianPath)
        }
        let url = Self.registryFileURL
        if map.isEmpty {
            try? FileManager.default.removeItem(at: url)
            return
        }
        guard let data = try? JSONEncoder().encode(map) else { return }
        try? FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        do {
            try data.write(to: url, options: [.atomic])
            try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
        } catch {
            SlackFileLog.log("persistInFlight failed: \(error.localizedDescription)")
        }
    }

    /// On relaunch, reconcile any turn that was in flight when the app last quit.
    /// Its process/watchdog/registry all died with the app, so its root is a
    /// permanently orphaned `:hourglass:` — flip it to Interrupted with a Resume
    /// affordance, restore the Resume context + the interrupted session id, and
    /// best-effort reap a genuinely-orphaned process group (so it cannot keep
    /// editing/billing). The pid/pgid match guards against pid reuse.
    private func reconcileInFlightOnLaunch() async {
        let url = Self.registryFileURL
        guard let data = try? Data(contentsOf: url),
              let map = try? JSONDecoder().decode([String: PersistedTurn].self, from: data),
              !map.isEmpty else { return }
        SlackFileLog.log("reconcile: \(map.count) orphaned in-flight turn(s) from previous run")

        for (storedKey, p) in map {
            // The conversation this orphan belonged to. Prefer the persisted thread
            // root; fall back to the turn's root ts (a new conversation's first turn)
            // or the stored map key for legacy per-channel registries.
            let channelId = p.channelId
            let threadRoot = p.threadRootTs ?? p.rootTs ?? Self.conversation(fromKey: storedKey)?.threadRootTs ?? channelId
            let conv = Conversation(channelId: channelId, threadRootTs: threadRoot)
            let key = conv.key
            // Liveness + safe cleanup: only kill a group we can positively
            // identify as our own orphan (alive pid whose group still matches).
            var reaped = false
            if let pid = p.pid, pid > 0, kill(pid, 0) == 0 {
                if let pgid = p.pgid, getpgid(pid) == pgid {
                    SlackFileLog.log("reconcile: \(key) orphan pid=\(pid) alive; killpg(SIGTERM) pgid=\(pgid)")
                    killpg(pgid, SIGTERM)
                    reaped = true
                } else {
                    SlackFileLog.log("reconcile: \(key) pid=\(pid) alive but group mismatch (pid reuse); leaving it")
                }
            }

            // Restore Resume context so the button works after a cold start.
            lastTurns[key] = LastTurn(projectName: p.projectName, cwd: p.cwd,
                                      obsidianPath: p.obsidianPath, text: p.request)
            lastConversation[channelId] = threadRoot
            // Point the conversation session at the interrupted turn's session so
            // Resume continues from its JSONL rather than starting fresh.
            if let sid = p.sessionId, !sid.isEmpty {
                var st = channelSessions[key]
                    ?? ChannelSession(sessionId: nil, permissionMode: "default", cwd: nil)
                st.sessionId = sid
                st.cwd = p.cwd
                channelSessions[key] = st
                saveChannelSessions()
            }

            if let ts = p.rootTs {
                let statusLine = reaped ? "session preserved · cleaned up orphaned process"
                                        : "session preserved"
                let body = "The app restarted while this turn was running. The Claude session is preserved — Resume to continue from where it left off."
                // The pre-turn checkpoint persisted across the restart (keyed by
                // root ts), so the interrupted card can still offer Show diff/Undo.
                let cpKey: String? = checkpoints[ts] != nil ? ts : nil
                let blocks = rootBlocks(state: .interrupted, request: p.request,
                                        statusLine: statusLine, body: body,
                                        buttons: controlBar(for: .interrupted, checkpointKey: cpKey))
                // Resume-after-restart posts into ITS original thread root.
                await chatUpdate(channel: channelId, ts: ts,
                                 text: "\(TurnState.interrupted.icon) Interrupted (app restarted)",
                                 blocks: blocks)
                // Swap the sidebar reaction from running to interrupted (1.9).
                await mirrorReaction(channel: channelId, ts: ts, to: .interrupted, turn: nil)
            }
            SlackFileLog.log("reconcile: \(key) -> Interrupted")
        }

        // All entries reconciled — clear the registry.
        try? FileManager.default.removeItem(at: url)
    }

    // MARK: - Phase 1.1: interactive dispatch

    /// Entry point for every `block_actions` / `view_submission` payload routed
    /// from `SocketModeClient` (the envelope is already acked). Dispatches purely
    /// on the payload `type`, then on the stable `action_id` / `callback_id`.
    private func handleInteractive(data: Data) async {
        guard let payload = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let type = payload["type"] as? String else {
            SlackFileLog.log("interactive: undecodable payload")
            return
        }
        switch type {
        case "block_actions":
            await handleBlockAction(payload)
        case "view_submission":
            await handleViewSubmission(payload)
        default:
            SlackFileLog.log("interactive: unhandled type \(type)")
        }
    }

    /// Route a button tap by its `action_id`. The channel comes off the payload;
    /// the root ts (`message.ts`) is the turn anchor for affordances that need it.
    private func handleBlockAction(_ payload: [String: Any]) async {
        let channelId = (payload["channel"] as? [String: Any])?["id"] as? String ?? ""
        let triggerId = payload["trigger_id"] as? String ?? ""
        let message = payload["message"] as? [String: Any]
        let messageTs = message?["ts"] as? String
        // The CONVERSATION the tapped card belongs to: every turn card lives in its
        // thread, so the thread root (message.thread_ts, or the message ts itself
        // when the card IS the thread root) plus the channel identifies the
        // conversation. This routes Stop/Retry/Continue/etc. to the right per-thread
        // turn even when several threads run in parallel in one channel.
        let threadRoot = (message?["thread_ts"] as? String) ?? messageTs ?? channelId
        let conv = Conversation(channelId: channelId, threadRootTs: threadRoot)
        // The interactive payload's response_url is the only handle to an
        // ephemeral message, used to clear a follow-up prompt.
        let responseUrl = payload["response_url"] as? String
        let actions = payload["actions"] as? [[String: Any]] ?? []
        guard let action = actions.first,
              let actionId = action["action_id"] as? String else {
            SlackFileLog.log("block_action: no action in payload")
            return
        }
        // The git affordances (1.7) carry the checkpoint key (the turn's root ts)
        // in the button value; fall back to the message ts the button lives on.
        let actionValue = (action["value"] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? messageTs ?? ""
        SlackFileLog.log("block_action id=\(actionId) conv=\(conv.key)")

        // Single-select answer buttons carry a per-option suffix on their action_id
        // (`hud:answer:option:<qi>:<oi>`) because Slack requires unique action_ids
        // within an actions block. Collapse that family back to the base id so the
        // switch routes every option tap to `onAnswerOption` (the choice rides in the
        // button `value`). The multi-select checkbox element keeps the bare id and
        // matches the `==` arm. No other action_id begins with this prefix.
        let routedId = (actionId == SlackAction.answerOption
                        || actionId.hasPrefix(SlackAction.answerOption + ":"))
            ? SlackAction.answerOption : actionId

        switch routedId {
        case SlackAction.stop:
            await stopTurn(conv: conv)
        case SlackAction.retry, SlackAction.resume:
            await retryTurn(conv: conv)
        case SlackAction.showDiff:
            await showDiff(conv: conv, key: actionValue, threadTs: messageTs ?? actionValue)
        case SlackAction.undoTurn:
            await undoTurn(conv: conv, key: actionValue, threadTs: messageTs ?? actionValue)
        case SlackAction.resumeWithChanges:
            await openResumeWithChangesModal(conv: conv, triggerId: triggerId)
        // 3.5 — turn-cap Continue/Stop.
        case SlackAction.budgetContinue:
            await continueFromTurnCap(conv: conv)
        case SlackAction.budgetStop:
            await stopAtTurnCap(conv: conv)
        // 3.5 — usage-window gate.
        case SlackAction.usageRunAnyway:
            await resolveUsageGate(conv: conv, run: true)
        case SlackAction.usageWait:
            await resolveUsageGate(conv: conv, run: false)
        // 3.6 — graceful failure affordances.
        case SlackAction.showError:
            await showError(rootTs: actionValue, channelId: channelId,
                            threadTs: messageTs ?? actionValue)
        case SlackAction.retryWithChanges:
            await openRetryWithChangesModal(conv: conv, triggerId: triggerId)
        case SlackAction.showDetails:
            await showTrailDetails(rootTs: actionValue, triggerId: triggerId)
        case SlackAction.showReasoning:
            await toggleReasoning(rootTs: actionValue, triggerId: triggerId)
        case SlackAction.feedbackUp:
            SlackFileLog.log("feedback +1 conv=\(conv.key)")
        case SlackAction.feedbackDown:
            SlackFileLog.log("feedback -1 conv=\(conv.key)")
        // Auto-queue Dequeue control. `actionValue` is the queued item id.
        case SlackAction.followupDequeue:
            await dequeueFollowup(conv: conv, itemId: actionValue)
        // ASK-YOU spine (Phase 3) ---------------------------------------------
        // 3.1 — clarifying questions. The option button value is `promptId|qIndex|optIndex`.
        case SlackAction.answerOption:
            await onAnswerOption(value: actionValue)
        case SlackAction.answerSubmit:
            await onAnswerSubmit(promptId: actionValue, payload: payload)
        case SlackAction.answerCustom:
            await openAnswerModal(value: actionValue, triggerId: triggerId)
        case SlackAction.answerStage:
            // Radio/checkbox selection on the inline card — staged only; the Submit
            // button commits it (this no-op is the "holding" behavior, CLI-like).
            break
        case SlackAction.answerOpenForm:
            await openAnswerFormModal(promptId: actionValue, triggerId: triggerId)
        // 3.2 — risk-tiered permission approval.
        case SlackAction.approveAllow:
            await resolveApproval(promptId: actionValue, behavior: .allow)
        case SlackAction.approveAlways:
            await resolveApproval(promptId: actionValue, behavior: .allowAlways)
        case SlackAction.approveDeny:
            await resolveApproval(promptId: actionValue, behavior: .deny(nil))
        case SlackAction.approveDenyNote:
            await openDenyNoteModal(promptId: actionValue, triggerId: triggerId)
        // 3.3 — ExitPlanMode gate.
        case SlackAction.planApprove:
            await resolveApproval(promptId: actionValue, behavior: .allow)
        case SlackAction.planEdit:
            await openEditPlanModal(promptId: actionValue, triggerId: triggerId)
        case SlackAction.planReject:
            await resolveApproval(promptId: actionValue,
                                  behavior: .deny("Plan rejected — please re-plan with a different approach."))
        // PM verbs — task-card interactions (host-side vault writes, no engine).
        case SlackAction.taskDone:
            let userId = (payload["user"] as? [String: Any])?["id"] as? String ?? ""
            await onTaskDone(channelId: channelId, messageTs: messageTs,
                             value: action["value"] as? String ?? "", user: userId)
        case SlackAction.taskAdd:
            let folder = (action["value"] as? String).flatMap { $0.isEmpty ? nil : $0 }
            await openTaskAddModal(channelId: channelId, triggerId: triggerId,
                                   projectArg: folder)
        case SlackAction.taskRefresh:
            if let messageTs {
                let folder = (action["value"] as? String).flatMap { $0.isEmpty ? nil : $0 }
                await tasksCard(channelId: channelId, responseUrl: nil, updateTs: messageTs,
                                projectArg: folder)
            }
        default:
            SlackFileLog.log("block_action: unknown action_id \(actionId)")
        }
    }

    /// Modal submit dispatch scaffold. No Phase-1 turn posts a modal yet (the
    /// answer / resume-with-changes / edit-plan modals arrive in 1.4 and Phase
    /// 3); this routes on `callback_id` so those land cleanly. The envelope is
    /// already acked under 3s by `SocketModeClient`, which also closes the modal.
    private func handleViewSubmission(_ payload: [String: Any]) async {
        let view = payload["view"] as? [String: Any]
        let callbackId = view?["callback_id"] as? String ?? ""
        SlackFileLog.log("view_submission callback_id=\(callbackId)")
        switch callbackId {
        case SlackAction.resumeWithChangesModal:
            // The conversation key rides in private_metadata; the note is the modal's
            // single multiline input. Run a fresh turn that resumes the stopped
            // session with the adjustment appended — the honest Tier-A substitute
            // for mid-flight steering (1.4).
            let convKey = view?["private_metadata"] as? String ?? ""
            let note = Self.modalInputValue(view, blockId: "adjust", actionId: "note")
            SlackFileLog.log("resume-with-changes submit conv=\(convKey) note_chars=\(note.count)")
            if let conv = Self.conversation(fromKey: convKey) {
                await resumeWithChanges(conv: conv, note: note)
            }
        // 3.6 — retry-with-changes: re-run the last turn with an appended adjustment.
        case SlackAction.retryChangesModal:
            let convKey = view?["private_metadata"] as? String ?? ""
            let note = Self.modalInputValue(view, blockId: "adjust", actionId: "note")
            SlackFileLog.log("retry-with-changes submit conv=\(convKey) note_chars=\(note.count)")
            if let conv = Self.conversation(fromKey: convKey) {
                await retryWithChanges(conv: conv, note: note)
            }
        // 3.1 — freeform "Let me type it" answer. private_metadata = `promptId|qIndex`.
        case SlackAction.answerModal:
            let meta = view?["private_metadata"] as? String ?? ""
            let answer = Self.modalInputValue(view, blockId: "answer", actionId: "text")
            await submitFreeformAnswer(meta: meta, answer: answer)
        // 3.1 — multi-question staged form. private_metadata = promptId; each
        // question's pick(s) live under block_id `askq:<qi>`, element action_id `sel`.
        case SlackAction.answerFormModal:
            await submitAnswerForm(promptId: view?["private_metadata"] as? String ?? "", view: view)
        // PM — add-to-Triage form. private_metadata = "<channel>|<folder>".
        case SlackAction.taskAddModal:
            let meta = view?["private_metadata"] as? String ?? ""
            let metaParts = meta.split(separator: "|", maxSplits: 1,
                                       omittingEmptySubsequences: false).map(String.init)
            let channelId = metaParts.first ?? ""
            let projectArg = metaParts.count > 1 && !metaParts[1].isEmpty ? metaParts[1] : nil
            let title = Self.modalInputValue(view, blockId: "title", actionId: "text")
            let note = Self.modalInputValue(view, blockId: "note", actionId: "text")
            let userId = (payload["user"] as? [String: Any])?["id"] as? String ?? ""
            await addTriage(title: title, body: note.isEmpty ? nil : note,
                            channelId: channelId, user: userId, projectArg: projectArg)
        // 3.2 — deny-with-note (deny carries steering). private_metadata = promptId.
        case SlackAction.denyNoteModal:
            let promptId = view?["private_metadata"] as? String ?? ""
            let note = Self.modalInputValue(view, blockId: "note", actionId: "text")
            await resolveApproval(promptId: promptId,
                                  behavior: .deny(note.isEmpty ? nil : note))
        // 3.3 — edit-plan: the edits are injected as deny-with-steering so the
        // model re-plans against them.
        case SlackAction.editPlanModal:
            let promptId = view?["private_metadata"] as? String ?? ""
            let edits = Self.modalInputValue(view, blockId: "edits", actionId: "text")
            await resolveApproval(promptId: promptId, behavior: .deny(
                edits.isEmpty ? "Revise the plan before executing." :
                    "Do not execute this plan as written. Revise it per these notes, then proceed: \(edits)"))
        default:
            SlackFileLog.log("view_submission: no handler for \(callbackId)")
        }
    }

    /// Pull a single input value out of a `view_submission` state tree:
    /// `view.state.values[blockId][actionId].value`.
    private static func modalInputValue(_ view: [String: Any]?, blockId: String, actionId: String) -> String {
        guard let state = view?["state"] as? [String: Any],
              let values = state["values"] as? [String: Any],
              let block = values[blockId] as? [String: Any],
              let element = block[actionId] as? [String: Any],
              let value = element["value"] as? String else { return "" }
        return value.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Open the Resume-with-changes modal: a single prefilled-prompt box whose
    /// submission re-runs the turn with the operator's adjustment. The conversation
    /// key is carried in `private_metadata` so the submit handler can route it.
    private func openResumeWithChangesModal(conv: Conversation, triggerId: String) async {
        guard !triggerId.isEmpty else {
            SlackFileLog.log("resume-with-changes: missing trigger_id")
            return
        }
        let view: [String: Any] = [
            "type": "modal",
            "callback_id": SlackAction.resumeWithChangesModal,
            "private_metadata": conv.key,
            "title": ["type": "plain_text", "text": "Resume with changes"],
            "submit": ["type": "plain_text", "text": "Resume"],
            "close": ["type": "plain_text", "text": "Cancel"],
            "blocks": [[
                "type": "input",
                "block_id": "adjust",
                "optional": true,
                "label": ["type": "plain_text", "text": "Anything to adjust before continuing?"],
                "element": [
                    "type": "plain_text_input",
                    "action_id": "note",
                    "multiline": true,
                    "placeholder": ["type": "plain_text",
                                    "text": "e.g. don't run Stata yet, just write the do-file"]
                ]
            ]]
        ]
        await openModal(triggerId: triggerId, view: view)
    }

    /// Re-run a conversation's most recent turn with an operator adjustment
    /// appended to the original goal. Refuses while that thread's turn is in flight.
    private func resumeWithChanges(conv: Conversation, note: String) async {
        guard let lt = lastTurns[conv.key] else {
            SlackFileLog.log("resume-with-changes: no recorded turn for \(conv.key)")
            return
        }
        guard !inFlight.contains(conv.key) else {
            SlackFileLog.log("resume-with-changes: busy, ignoring for \(conv.key)")
            return
        }
        let combined = note.isEmpty
            ? lt.text
            : "\(lt.text)\n\n[Adjustment before continuing: \(note)]"
        await runTurn(conv: conv, channelId: conv.channelId, projectName: lt.projectName,
                      cwd: lt.cwd, obsidianPath: lt.obsidianPath, text: combined)
    }

    /// Open the Retry-with-changes modal (3.6): a single adjustment box whose
    /// submission re-runs the FAILED turn with the note appended. Distinct from
    /// Resume-with-changes (a stopped turn) only in copy; both append to the goal.
    private func openRetryWithChangesModal(conv: Conversation, triggerId: String) async {
        guard !triggerId.isEmpty else {
            SlackFileLog.log("retry-with-changes: missing trigger_id")
            return
        }
        let view: [String: Any] = [
            "type": "modal",
            "callback_id": SlackAction.retryChangesModal,
            "private_metadata": conv.key,
            "title": ["type": "plain_text", "text": "Retry with changes"],
            "submit": ["type": "plain_text", "text": "Retry"],
            "close": ["type": "plain_text", "text": "Cancel"],
            "blocks": [[
                "type": "input",
                "block_id": "adjust",
                "optional": true,
                "label": ["type": "plain_text", "text": "What should change before re-running?"],
                "element": [
                    "type": "plain_text_input",
                    "action_id": "note",
                    "multiline": true,
                    "placeholder": ["type": "plain_text",
                                    "text": "e.g. switch to default mode so Bash is gated, not blocked"]
                ]
            ]]
        ]
        await openModal(triggerId: triggerId, view: view)
    }

    /// Re-run a conversation's most recent (failed) turn with an operator
    /// adjustment appended (3.6). Refuses while that thread's turn is in flight.
    private func retryWithChanges(conv: Conversation, note: String) async {
        guard let lt = lastTurns[conv.key] else {
            SlackFileLog.log("retry-with-changes: no recorded turn for \(conv.key)")
            return
        }
        guard !inFlight.contains(conv.key) else {
            SlackFileLog.log("retry-with-changes: busy, ignoring for \(conv.key)")
            return
        }
        let combined = note.isEmpty
            ? lt.text
            : "\(lt.text)\n\n[Adjustment before retrying: \(note)]"
        await runTurn(conv: conv, channelId: conv.channelId, projectName: lt.projectName,
                      cwd: lt.cwd, obsidianPath: lt.obsidianPath, text: combined)
    }

    /// Stop a conversation's in-flight turn: flag it (so it resolves to
    /// Stopped-by-you, not Failed) and cancel that thread's engine. Per-thread —
    /// stopping one thread never touches another running in parallel.
    private func stopTurn(conv: Conversation) async {
        guard inFlight.contains(conv.key) else {
            SlackFileLog.log("stop: no in-flight turn for \(conv.key)")
            return
        }
        stopRequested.insert(conv.key)
        // Optimistic relabel: flip the root to "Stopping…" and drop the Stop
        // button so it can't be double-tapped while the kill is in flight. The
        // turn's terminal .stopped card lands a beat later from `runTurn`.
        if let turn = inFlightTurns[conv.key] {
            turn.stopping = true
            if let ts = turn.rootTs {
                await chatUpdate(channel: conv.channelId, ts: ts, text: "Stopping…",
                                 blocks: workingBlocks(turn: turn, now: Date(),
                                                       warning: false, stopping: true))
            }
        }
        // Generation hygiene (3.4): resolve any parked supervisory prompt for this
        // conversation with its safe default before the kill races it.
        await cancelParkedPrompts(conv: conv)
        clients[conv.key]?.cancel()
        SlackFileLog.log("stop requested for \(conv.key)")
    }

    /// Wall-clock watchdog kill (3.6 / E5): the turn ran past `wallClockTimeout`
    /// while still active. Flag it as a TIMEOUT (so it resolves to Failed, not
    /// Stopped-by-you), flip the root, cancel any parked prompt, and kill the
    /// process group. The `runTurn` resolution reads `timeoutRequested` to render
    /// the timed-out Failed card with Retry — never a hung spinner.
    private func forceTimeout(conv: Conversation) async {
        guard inFlight.contains(conv.key) else { return }
        timeoutRequested.insert(conv.key)
        if let turn = inFlightTurns[conv.key] {
            turn.stopping = true
            if let ts = turn.rootTs {
                await chatUpdate(channel: conv.channelId, ts: ts, text: "Timing out…",
                                 blocks: workingBlocks(turn: turn, now: Date(),
                                                       warning: false, stopping: true))
            }
        }
        await cancelParkedPrompts(conv: conv)
        clients[conv.key]?.cancel()
        SlackFileLog.log("wall-clock timeout fired for \(conv.key)")
    }

    /// Re-run a conversation's most recent turn (Retry / Resume). Refuses while
    /// that thread's turn is in flight (single-writer per thread).
    private func retryTurn(conv: Conversation) async {
        guard let lt = lastTurns[conv.key] else {
            SlackFileLog.log("retry: no recorded turn for \(conv.key)")
            return
        }
        guard !inFlight.contains(conv.key) else {
            SlackFileLog.log("retry: busy, ignoring for \(conv.key)")
            return
        }
        SlackFileLog.log("retry/resume turn for \(conv.key)")
        await runTurn(conv: conv, channelId: conv.channelId, projectName: lt.projectName,
                      cwd: lt.cwd, obsidianPath: lt.obsidianPath, text: lt.text)
    }

    // MARK: - Per-thread auto-queue (follow-up handling)

    /// A message arrived in a thread while THAT thread's turn was running.
    /// AUTO-QUEUE it (no Queue/Steer/Cancel prompt) — exactly like the terminal
    /// CLI queues a message typed mid-turn — with a lightweight `:hourglass:`
    /// reaction as the ack and a Dequeue affordance. It runs automatically after
    /// the current turn finishes. (Steer/interrupt stays an explicit action: the
    /// Stop button or `/claude-stop`.)
    private func autoQueueFollowup(conv: Conversation, text: String,
                                   resolved: (name: String, cwd: String, obsidianPath: String)) async {
        let id = UUID().uuidString
        let item = QueuedFollowup(id: id, channelId: conv.channelId, threadRootTs: conv.threadRootTs,
                                  text: text, projectName: resolved.name, cwd: resolved.cwd,
                                  obsidianPath: resolved.obsidianPath, dequeueTs: nil)
        // ENQUEUE SYNCHRONOUSLY — before any await — so the append is atomic with
        // the caller's busy test. Previously the append happened only AFTER the
        // postMessage round-trip below; during that suspension the running turn
        // could resolve and its drain fire on a still-empty queue, orphaning this
        // item (it would then never run). Appending first eliminates that window.
        followupQueue[conv.key, default: []].append(item)
        SlackFileLog.log("followup: auto-queued id=\(id.prefix(8)) \(conv.key) depth=\(followupQueue[conv.key]?.count ?? 0)")
        // Audit the queued item in the running turn's thread with a Dequeue button.
        let threadTs = inFlightTurns[conv.key]?.rootTs ?? conv.threadRootTs
        let ts = await postMessage(
            channel: conv.channelId,
            text: "↳ queued: \(SlackBlocks.truncate(Self.singleLine(text), 200))",
            threadTs: threadTs,
            blocks: [
                SlackBlocks.context("↳ queued (runs after the current turn): \(SlackBlocks.truncate(Self.singleLine(text), 200))"),
                SlackBlocks.actions([
                    SlackBlocks.button(text: ":wastebasket: Dequeue",
                                       actionId: SlackAction.followupDequeue, value: id)
                ])
            ])
        // Patch the queued item's Dequeue affordance ts BY ID. The queue may have
        // been drained or reordered during the await above; locating the item by id
        // (rather than blindly mutating index 0) keeps the affordance attached to
        // the right item, and if the item already ran this simply finds nothing.
        if let idx = followupQueue[conv.key]?.firstIndex(where: { $0.id == id }) {
            followupQueue[conv.key]?[idx].dequeueTs = ts
        }
        // Lightweight ack: an :hourglass: reaction on the queued message itself.
        if let ts {
            await reactionAdd(channel: conv.channelId, ts: ts, name: "hourglass")
        }
    }

    /// Drain one queued follow-up after a turn resolves. Runs automatically after
    /// ANY terminal state (like the CLI's typed-ahead queue); the operator can
    /// Dequeue before it fires. runTurn's own resolution drains the next item, so
    /// the queue processes sequentially.
    private func drainFollowupQueue(conv: Conversation, lastTerminal: TurnState) async {
        guard !inFlight.contains(conv.key) else { return }   // a new turn already started
        guard var q = followupQueue[conv.key], !q.isEmpty else { return }
        // RESERVE the in-flight slot SYNCHRONOUSLY (no await between the not-busy
        // checks above and this insert), THEN dequeue under the same reservation.
        // This closes the dropped-message race: previously the item was removed and
        // then `clearDequeueAffordance` suspended with inFlight cleared, so a racing
        // reply saw "not busy", ran directly, and re-acquired the lock — causing the
        // resumed drain's runTurn to bail busy and silently discard the dequeued
        // item (FIFO broken). Holding the lock across the affordance clear forces any
        // racing reply to queue behind us, and runTurn runs with the lock pre-held.
        inFlight.insert(conv.key)
        let item = q.removeFirst()
        followupQueue[conv.key] = q
        await clearDequeueAffordance(channelId: conv.channelId, item: item)
        SlackFileLog.log("followup: auto-run id=\(item.id.prefix(8)) after \(lastTerminal.rawValue) \(conv.key) depth=\(q.count)")
        await runTurn(conv: item.conv, channelId: item.channelId, projectName: item.projectName,
                      cwd: item.cwd, obsidianPath: item.obsidianPath, text: item.text,
                      lockAlreadyHeld: true)
    }

    /// Strip the `[ Dequeue ]` button from a queued item's trail line once it
    /// runs / is dequeued, leaving the audit text in place.
    private func clearDequeueAffordance(channelId: String, item: QueuedFollowup) async {
        guard let ts = item.dequeueTs else { return }
        let line = "↳ queued: \(SlackBlocks.truncate(Self.singleLine(item.text), 200))"
        await chatUpdate(channel: channelId, ts: ts, text: line,
                         blocks: [SlackBlocks.context(line)])
    }

    /// Dequeue a still-buffered follow-up before it runs.
    private func dequeueFollowup(conv: Conversation, itemId: String) async {
        guard var q = followupQueue[conv.key], let idx = q.firstIndex(where: { $0.id == itemId }) else {
            SlackFileLog.log("followup dequeue: id \(itemId.prefix(8)) not queued")
            return
        }
        let item = q.remove(at: idx)
        followupQueue[conv.key] = q
        await clearDequeueAffordance(channelId: conv.channelId, item: item)
        SlackFileLog.log("followup: dequeued id=\(itemId.prefix(8)) \(conv.key)")
        if let ts = item.dequeueTs {
            await postMessage(channel: conv.channelId, text: ":wastebasket: Dequeued — this follow-up will not run.", threadTs: ts)
        }
    }

    // MARK: - Phase 1.7: Show diff / Undo turn handlers

    /// Render `git diff` of what the keyed turn changed into its thread. The key
    /// is the turn's root ts; the diff is size-capped and posted in a code block
    /// (the secret-redaction pass lands with Security S3 in a later phase).
    private func showDiff(conv: Conversation, key: String, threadTs: String?) async {
        let channelId = conv.channelId
        guard let cp = checkpoints[key] else {
            SlackFileLog.log("show-diff: no checkpoint for key \(key)")
            await postMessage(channel: channelId,
                              text: "No checkpoint recorded for this turn — diff unavailable.",
                              threadTs: threadTs)
            return
        }
        let diff = await GitCheckpointService.diff(cp)
        SlackFileLog.log("show-diff: \(conv.key) key=\(key) chars=\(diff.count)")
        guard !diff.isEmpty else {
            await postMessage(channel: channelId,
                              text: ":mag: No changes since the pre-turn checkpoint.",
                              threadTs: threadTs)
            return
        }
        await postMessage(channel: channelId,
                          text: ":mag: *Diff since pre-turn checkpoint*",
                          threadTs: threadTs)
        // Wrap each chunk as a code block; leave headroom under Slack's limit.
        for chunk in Self.splitChunks(diff, limit: 3600) {
            await postMessage(channel: channelId, text: "```\n\(chunk)\n```", threadTs: threadTs)
        }
    }

    /// Restore the working tree to the keyed turn's pre-turn checkpoint and report
    /// the outcome into the thread. Refuses while a turn is in flight (the live
    /// turn is editing the same tree).
    private func undoTurn(conv: Conversation, key: String, threadTs: String?) async {
        let channelId = conv.channelId
        guard let cp = checkpoints[key] else {
            SlackFileLog.log("undo: no checkpoint for key \(key)")
            await postMessage(channel: channelId,
                              text: "No checkpoint recorded for this turn — nothing to undo.",
                              threadTs: threadTs)
            return
        }
        guard !inFlight.contains(conv.key) else {
            SlackFileLog.log("undo: busy, refusing for \(conv.key)")
            await postMessage(channel: channelId,
                              text: "A turn is running in this thread — Stop it before undoing.",
                              threadTs: threadTs)
            return
        }
        let result = await GitCheckpointService.undo(cp)
        SlackFileLog.log("undo: \(conv.key) key=\(key) ok=\(result.ok) — \(result.detail)")
        let icon = result.ok ? ":leftwards_arrow_with_hook:" : ":x:"
        await postMessage(channel: channelId,
                          text: "\(icon) \(result.detail)" + (result.ok
                            ? " (the prior state is recoverable via `refs/claudehud/undo-safety`)."
                            : ""),
                          threadTs: threadTs)
    }

    // MARK: - Phase 1.9: emoji-reaction status mirror

    /// Mirror a turn's state onto its root message as a single reaction (1.9):
    /// add the new state's glyph, removing the previously-mirrored one first so
    /// the sidebar shows exactly one status emoji. `turn` carries the prior
    /// reaction; on the reconcile path (turn == nil) we best-effort strip the
    /// running `:hourglass:`. Failures (already_reacted / no_reaction) are benign.
    private func mirrorReaction(channel: String, ts: String, to state: TurnState, turn: InFlightTurn?) async {
        let newName = state.reactionName
        let oldName = turn?.reaction ?? (turn == nil ? TurnState.working.reactionName : nil)
        if let oldName, oldName != newName {
            await reactionRemove(channel: channel, ts: ts, name: oldName)
        }
        await reactionAdd(channel: channel, ts: ts, name: newName)
        turn?.reaction = newName
    }

    private func reactionAdd(channel: String, ts: String, name: String) async {
        _ = await slackForm(method: "reactions.add",
                            form: ["channel": channel, "timestamp": ts, "name": name])
    }

    private func reactionRemove(channel: String, ts: String, name: String) async {
        _ = await slackForm(method: "reactions.remove",
                            form: ["channel": channel, "timestamp": ts, "name": name])
    }

    // MARK: - Phase 1.7/1.8: durable checkpoint + seen-message persistence

    private static var checkpointsFileURL: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/ClaudeHUD/slack-checkpoints.json")
    }
    private static var seenMessagesFileURL: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/ClaudeHUD/slack-seen.json")
    }

    private func loadCheckpoints() {
        guard let data = try? Data(contentsOf: Self.checkpointsFileURL),
              let map = try? JSONDecoder().decode([String: GitCheckpoint].self, from: data) else { return }
        checkpoints = map
        SlackFileLog.log("loaded \(map.count) git checkpoints")
    }

    /// Persist the checkpoint map, pruned to the most-recent `maxCheckpoints` by
    /// creation time so it never grows without bound. Written 0600 + atomically.
    private func saveCheckpoints() {
        if checkpoints.count > Self.maxCheckpoints {
            let keep = checkpoints.sorted { $0.value.createdAt > $1.value.createdAt }
                .prefix(Self.maxCheckpoints)
            checkpoints = Dictionary(uniqueKeysWithValues: keep.map { ($0.key, $0.value) })
        }
        Self.writeJSON(checkpoints, to: Self.checkpointsFileURL, label: "saveCheckpoints")
    }

    /// Record `key` and report whether it was already seen (a redelivery). Prunes
    /// expired ids and persists durably so a restart-straddling redelivery is
    /// caught before a turn spawns (1.8).
    private func isDuplicateMessage(_ key: String) -> Bool {
        let now = Date()
        seenMessages = seenMessages.filter { now.timeIntervalSince($0.value) < Self.seenMessageTTL }
        let dup = seenMessages[key] != nil
        seenMessages[key] = now
        Self.writeJSON(seenMessages, to: Self.seenMessagesFileURL, label: "saveSeenMessages")
        return dup
    }

    private func loadSeenMessages() {
        guard let data = try? Data(contentsOf: Self.seenMessagesFileURL),
              let map = try? JSONDecoder().decode([String: Date].self, from: data) else { return }
        let now = Date()
        seenMessages = map.filter { now.timeIntervalSince($0.value) < Self.seenMessageTTL }
        SlackFileLog.log("loaded \(seenMessages.count) seen message ids")
    }

    /// Encode `value` to `url` 0600 + atomically; logs failures, never throws.
    private static func writeJSON<T: Encodable>(_ value: T, to url: URL, label: String) {
        guard let data = try? JSONEncoder().encode(value) else { return }
        try? FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        do {
            try data.write(to: url, options: [.atomic])
            try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
        } catch {
            SlackFileLog.log("\(label) failed: \(error.localizedDescription)")
        }
    }

    /// Run one engine invocation for a channel and collect the result. When
    /// `sessionId` is nil this is a fresh run — the client's stale
    /// `currentSessionId` is cleared first so `send()` can't fall back to it.
    /// Returns the final assistant text, per-tool counts, and the (new) session
    /// id. Repeatable, so the empty-resume retry can call it twice.
    private func runEngine(conv: Conversation, message: String, permissionMode: String,
                           effort: String, sessionId: String?, cwd: String,
                           maxTurns: Int? = nil) async throws
        -> (result: CLIResultEvent, text: String, tools: [String: Int]) {
        let key = conv.key
        let client = clientFor(key)
        if sessionId == nil { client.newSession() }

        // SUPERVISED MODE (Phase 3): drop --dangerously-skip-permissions and route
        // every gated tool through the bundled MCP server (permission-prompt-tool +
        // risk policy). The per-turn mcp-config carries the channel + thread +
        // generation + cwd as env so the server stamps each parked request for
        // per-thread routing. If the config can't be written, fall back to the
        // legacy skip path so the turn still runs (degrade, never break).
        let generation = inFlightTurns[key]?.generation ?? 0
        var mcpConfigPath: String? = nil
        var supervisedSystemPrompt: String? = nil
        if supervisedMode, let path = writeMcpConfig(conv: conv,
                                                     generation: generation, cwd: cwd) {
            mcpConfigPath = path
            supervisedSystemPrompt = Self.supervisedPreamble
        }

        var assistantText = ""
        var toolCounts: [String: Int] = [:]
        let result = try await client.send(
            message: message,
            model: Self.slackModel,
            permissionMode: permissionMode,
            effort: effort,
            systemPrompt: supervisedSystemPrompt,
            sessionId: sessionId,
            workingDirectory: cwd,
            supervisedMcpConfig: mcpConfigPath,
            maxTurns: maxTurns,
            onSpawn: { [weak self] pid, pgid in
                // Record the live process in the durable registry (1.6) the
                // moment it spawns, so a crash an instant later is reconcilable.
                guard let self, let turn = self.inFlightTurns[key] else { return }
                turn.pid = pid
                turn.pgid = pgid
                self.persistInFlight()
                SlackFileLog.log("inflight registered: \(key) pid=\(pid) gen=\(turn.generation)")
            }
        ) { [weak self] event in
            // Every event bumps the watchdog's silence clock (1.5).
            if let turn = self?.inFlightTurns[key] { turn.lastEventAt = Date() }
            switch event {
            case .system(let sys):
                if let turn = self?.inFlightTurns[key], !sys.sessionId.isEmpty,
                   turn.sessionId != sys.sessionId {
                    turn.sessionId = sys.sessionId
                    self?.persistInFlight()
                }
                // Cache the authoritative per-session skills/agents the init event
                // reports so `/claude-skills` and `/claude-agents` can answer from
                // this conversation's live session.
                if sys.subtype == "init" {
                    self?.channelSkills[key] = sys.skills
                    self?.channelAgents[key] = sys.agents
                }
            case .assistant(let msg):
                if let t = msg.text { assistantText = t }
                // Thinking summary → collapsed reasoning line in the thread (§2.2),
                // never the answer text, never the channel root.
                if msg.isThinking { self?.recordTrailEvent(convKey: key, event: event) }
            case .toolUse(let tool):
                // The supervisory tools (mcp__hud__approve / ask_human) are the
                // pause MECHANISM, not work the operator wants on the trail — skip
                // them from the count and the activity trail.
                if tool.toolName.hasPrefix("mcp__hud__") { break }
                toolCounts[tool.toolName, default: 0] += 1
                self?.inFlightTurns[key]?.toolCount += 1
                // Open a semantic line in the in-thread trail (§2.1).
                self?.recordTrailEvent(convKey: key, event: event)
            case .toolResult:
                // Close the matching trail line by tool_use_id (§2.1).
                self?.recordTrailEvent(convKey: key, event: event)
            case .result(let r):
                if !r.result.isEmpty { assistantText = r.result }
            default:
                break
            }
        }
        let text = result.result.isEmpty ? assistantText : result.result
        return (result, text, toolCounts)
    }

    /// The conversation's dedicated CLI engine (created on first use), keyed by
    /// `Conversation.key` so each thread runs its own process in parallel.
    private func clientFor(_ key: String) -> ClaudeCLIClient {
        if let existing = clients[key] { return existing }
        let client = ClaudeCLIClient()
        clients[key] = client
        return client
    }

    // MARK: - Phase 3 (ASK-YOU spine): relay bridge + supervisory cards

    /// System-prompt addendum for supervised turns: teach the model to use the
    /// `ask_human` tool on a consequential ambiguity rather than guessing, and to
    /// finish plan mode with `ExitPlanMode` so the operator can approve it.
    private static let supervisedPreamble = """
    You are running under operator supervision via Slack. Two affordances:
    - When you hit a genuinely consequential ambiguity you cannot safely resolve \
    on your own, call the `mcp__hud__ask_human` tool with 2-4 concrete options \
    (each a short label + one-line description) instead of guessing. Use it \
    sparingly — only for decisions that materially change the outcome.
    - Consequential actions (shell commands, network calls, deletes, writes outside \
    the working tree) are gated for operator approval automatically; reads and \
    in-repo edits proceed without interruption. Do not ask permission for those in \
    prose — just proceed and the gate will handle approvals.
    - In plan mode, present your plan via `ExitPlanMode`; the operator approves it \
    before any execution.
    """

    /// Create the relay directories and start the watcher that turns MCP request
    /// files into Slack cards. Idempotent.
    private func startRelayWatcher() {
        guard !relayWatcherRunning else { return }
        let fm = FileManager.default
        try? fm.createDirectory(atPath: Self.relayRequestsDir, withIntermediateDirectories: true)
        try? fm.createDirectory(atPath: Self.relayDecisionsDir, withIntermediateDirectories: true)
        relayWatcherRunning = true
        SlackFileLog.log("relay watcher started dir=\(Self.relayDir)")
        Task { @MainActor in
            while relayWatcherRunning {
                try? await Task.sleep(nanoseconds: 400_000_000)  // 0.4s
                await tickRelay()
            }
        }
    }

    /// One relay pass: render any NEW request as a card, and detect requests whose
    /// file vanished WITHOUT our decision (the MCP server's per-prompt timeout
    /// fired) so the card and the Needs-you root are cleaned up (E4).
    private func tickRelay() async {
        let fm = FileManager.default
        let files = (try? fm.contentsOfDirectory(atPath: Self.relayRequestsDir))?
            .filter { $0.hasSuffix(".json") } ?? []
        let liveIds = Set(files.map { String($0.dropLast(5)) })

        // New requests → cards.
        for file in files {
            let id = String(file.dropLast(5))
            guard !relaySeenRequests.contains(id) else { continue }
            let path = "\(Self.relayRequestsDir)/\(file)"
            guard let data = fm.contents(atPath: path), !data.isEmpty,
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let req = SupervisorRequest(json: json) else { continue }
            relaySeenRequests.insert(id)
            await handleRelayRequest(req)
        }

        // Vanished-without-decision → MCP timed out; un-park and restore the root.
        for (id, prompt) in parkedPrompts where !prompt.locked && !liveIds.contains(id) {
            SlackFileLog.log("relay: prompt \(id.prefix(8)) timed out (request gone); cleaning up")
            await timeoutParked(prompt)
        }

        // HARD EXPIRY (3.4 / E4): a belt-and-suspenders clock independent of the
        // MCP server. If the MCP server is wedged or dead, its request file never
        // vanishes, so the check above never fires and a parked prompt (plus its
        // clickable buttons resolving a dead RPC) could live forever. Expire any
        // unlocked prompt older than the timeout + a grace window by force-writing
        // the safe default and clearing the card.
        let now = Date()
        let hardDeadline = Self.parkedPromptTimeout + 120  // MCP clock + 2 min grace
        for (id, prompt) in parkedPrompts
            where !prompt.locked && now.timeIntervalSince(prompt.createdAt) > hardDeadline {
            SlackFileLog.log("relay: prompt \(id.prefix(8)) hard-expired after \(Int(now.timeIntervalSince(prompt.createdAt)))s; safe-default")
            await finishParked(prompt, decision: safeDefault(for: prompt.kind),
                               cardNote: ":hourglass: This prompt expired without an answer and was resolved with the safe default.")
        }

        // Bounded growth: forget seen ids that are no longer on disk.
        if relaySeenRequests.count > 200 {
            relaySeenRequests = relaySeenRequests.intersection(liveIds)
        }
    }

    /// Render one supervisory request: post its card into the turn's thread, flip
    /// the root to Needs-you, park the live turn, and escalate a push.
    private func handleRelayRequest(_ req: SupervisorRequest) async {
        let channelId = req.channel
        // Route to the per-thread turn via the conversation key (channel + thread).
        let convKey = Self.convKey(req.channel, req.thread)
        guard let turn = inFlightTurns[convKey], let rootTs = turn.rootTs else {
            // No live turn for this request (already resolved / stale) — unblock
            // the MCP with a safe default so it never hangs.
            SlackFileLog.log("relay: no live turn for request \(req.id.prefix(8)) conv=\(convKey); safe-default")
            writeDecision(promptId: req.id, decision: safeDefault(for: req.kind))
            return
        }
        // Generation hygiene (3.4): a request stamped with an old generation belongs
        // to a turn that has since been superseded — resolve it safely, don't render.
        if req.generation != turn.generation {
            SlackFileLog.log("relay: stale generation \(req.generation) != \(turn.generation); safe-default")
            writeDecision(promptId: req.id, decision: safeDefault(for: req.kind))
            return
        }

        let prompt = ParkedPrompt(request: req)
        var blocks: [[String: Any]]
        switch req.kind {
        case .ask:
            // 1 question → inline staged radio/checkbox card; 2+ → a compact card with
            // an "Answer…" button that opens the staged modal form (CLI parity).
            blocks = req.questions.count >= 2
                ? SupervisorCards.questionFormCard(promptId: req.id, questions: req.questions)
                : SupervisorCards.questionCard(promptId: req.id, questions: req.questions)
        case .approve:
            blocks = SupervisorCards.approvalCard(promptId: req.id, toolName: req.toolName,
                                                  preview: req.actionPreview, cwd: req.cwd,
                                                  reason: req.reason)
        case .plan:
            blocks = SupervisorCards.planCard(promptId: req.id, plan: req.planText)
        case .budget:
            blocks = SupervisorCards.planCard(promptId: req.id, plan: req.planText)  // reserved
        }

        // Fold the operator @mention into the card's lead line so the SINGLE card
        // both pings the operator (watch/phone push) and shows the prompt — this
        // replaces the separate "a decision is needed" escalation reply, which read
        // as a redundant follow-on next to the card.
        let mention = operatorUserId[channelId].map { "<@\($0)> " } ?? ""
        if !mention.isEmpty, !blocks.isEmpty,
           let textObj = blocks[0]["text"] as? [String: Any],
           let leadText = textObj["text"] as? String {
            var lead = blocks[0]
            lead["text"] = ["type": "mrkdwn", "text": "\(mention)\(leadText)"]
            blocks[0] = lead
        }

        var cardTs = await postMessage(channel: channelId,
                                       text: "\(mention)\(needsYouFallback(req.kind))",
                                       threadTs: rootTs, blocks: blocks)
        if cardTs == nil {
            // The Block Kit card was rejected (e.g. invalid_blocks) — postMessage
            // logged the Slack error to os_log only, so surface it in the readable
            // file log here. Never strand the operator on an invisible prompt:
            // re-post the request as blocks-free plain text. For an ask the in-thread
            // reply path still resolves it; for approve/plan it makes the pending
            // decision readable and points to the app's buttons.
            SlackFileLog.log("card post FAILED (err=\(lastError ?? "unknown")); plain-text fallback for \(req.id.prefix(8))")
            cardTs = await postMessage(channel: channelId,
                                       text: "\(mention)\(plainTextRequest(req))",
                                       threadTs: rootTs)
        }
        prompt.cardTs = cardTs
        parkedPrompts[req.id] = prompt
        turn.parked = true
        SlackFileLog.log("parked: \(convKey) kind=\(req.kind.rawValue) id=\(req.id.prefix(8)) card=\(cardTs ?? "nil")")

        await renderNeedsYouRoot(turn: turn, kind: req.kind)
    }

    private func needsYouFallback(_ kind: HudPromptKind) -> String {
        switch kind {
        case .ask:    return ":raising_hand: A decision is needed to continue."
        case .approve: return ":lock: Approval needed to continue."
        case .plan:   return ":clipboard: A plan is ready for your approval."
        case .budget: return ":coin: Budget decision needed."
        }
    }

    /// A blocks-free rendering of a relay request, posted into the thread as the
    /// fallback when the Block Kit card is rejected — so a card failure can never
    /// leave the operator answering an invisible prompt. Asks stay fully resolvable
    /// here via the in-thread reply path; approve/plan are made readable and direct
    /// the operator to the buttons in the ClaudeHUD app (text can't resolve those).
    private func plainTextRequest(_ req: SupervisorRequest) -> String {
        switch req.kind {
        case .ask:
            var lines = [":raising_hand:  *I need a decision before continuing.*  Reply in-thread to answer."]
            for (qi, q) in req.questions.enumerated() {
                lines.append("")
                lines.append("*\(qi + 1). \(q.header)* — \(q.question)")
                for opt in q.options {
                    let gloss = opt.description.isEmpty ? "" : " — \(opt.description)"
                    lines.append("   •  *\(opt.label)*\(gloss)")
                }
            }
            if req.questions.count > 1 {
                lines.append("")
                lines.append("_Reply once per question, in order._")
            }
            return SlackBlocks.truncate(lines.joined(separator: "\n"), 3500)
        case .approve:
            let label = req.toolName == "Bash" ? "Run in terminal" : req.toolName
            let preview = SlackBlocks.truncate(req.actionPreview, 1500)
            return ":lock:  *Approval needed* — \(label):\n```\n\(preview)\n```\nApprove or deny from the ClaudeHUD app (the buttons couldn't be rendered here)."
        case .plan:
            return ":clipboard:  *Plan ready for approval:*\n\(SlackBlocks.truncate(req.planText, 2500))\n\nApprove or deny from the ClaudeHUD app (the buttons couldn't be rendered here)."
        case .budget:
            return ":coin:  A budget decision is needed — continue or stop from the ClaudeHUD app."
        }
    }

    /// Flip the turn's root to Needs-you while keeping it in flight (the card with
    /// the buttons lives in the thread). The reaction mirror follows.
    private func renderNeedsYouRoot(turn: InFlightTurn, kind: HudPromptKind) async {
        guard let ts = turn.rootTs else { return }
        let status = kind == .approve ? "approval needed" :
                     (kind == .plan ? "plan ready" : "needs a decision")
        let provenance = Self.provenanceLine(project: turn.projectName,
                                             mode: turn.permissionMode, effort: turn.effort)
        let blocks = rootBlocks(state: .needsYou, request: turn.request,
                                statusLine: status, body: ":point_down: Answer in the thread.",
                                buttons: [], provenance: provenance)
        await chatUpdate(channel: turn.channelId, ts: ts,
                         text: "\(TurnState.needsYou.icon) Needs you", blocks: blocks)
        await mirrorReaction(channel: turn.channelId, ts: ts, to: .needsYou, turn: turn)
    }

    /// Restore the working root once a prompt resolves and the turn resumes.
    private func restoreWorkingRoot(turn: InFlightTurn) async {
        guard let ts = turn.rootTs, !turn.resolved else { return }
        turn.parked = false
        turn.lastEventAt = Date()   // reset the silence clock so it doesn't warn
        await chatUpdate(channel: turn.channelId, ts: ts, text: "Working…",
                         blocks: workingBlocks(turn: turn, now: Date(), warning: false, stopping: false))
        await mirrorReaction(channel: turn.channelId, ts: ts, to: .working, turn: turn)
    }

    // MARK: - Phase 3: decision plumbing

    /// Write the decision the MCP server is blocked on, atomically, and remove the
    /// request file so the server's poll loop returns immediately.
    private func writeDecision(promptId: String, decision: [String: Any]) {
        let fm = FileManager.default
        try? fm.createDirectory(atPath: Self.relayDecisionsDir, withIntermediateDirectories: true)
        guard let data = try? JSONSerialization.data(withJSONObject: decision) else { return }
        let path = "\(Self.relayDecisionsDir)/\(promptId).json"
        let tmp = path + ".tmp"
        try? data.write(to: URL(fileURLWithPath: tmp))
        try? fm.moveItem(atPath: tmp, toPath: path)
    }

    /// The safe default for a parked prompt that must be resolved without an answer
    /// (stale generation, no live turn, or MCP timeout): deny permissions/plans,
    /// "no answer" for questions (E4).
    private func safeDefault(for kind: HudPromptKind) -> [String: Any] {
        switch kind {
        case .ask:    return SupervisorDecision.answers([])
        default:      return SupervisorDecision.deny("No decision from the operator; denied for safety.")
        }
    }

    /// Lock + resolve a parked prompt: write the decision, clear its card buttons,
    /// un-park the turn, and restore the working root. Locking on the FIRST valid
    /// decision makes a double-click (Approve then Deny) a no-op (3.4).
    private func finishParked(_ prompt: ParkedPrompt, decision: [String: Any],
                              cardNote: String) async {
        guard !prompt.locked else {
            SlackFileLog.log("parked \(prompt.id.prefix(8)) already locked; ignoring")
            return
        }
        prompt.locked = true
        writeDecision(promptId: prompt.id, decision: decision)
        parkedPrompts.removeValue(forKey: prompt.id)
        // Replace the card with a terse, button-free confirmation (the audit trail).
        if let cardTs = prompt.cardTs {
            await chatUpdate(channel: prompt.channelId, ts: cardTs, text: cardNote,
                             blocks: [SlackBlocks.section(cardNote)])
        }
        if let turn = inFlightTurns[prompt.convKey], turn.generation == prompt.generation {
            await restoreWorkingRoot(turn: turn)
        }
        SlackFileLog.log("resolved parked \(prompt.id.prefix(8)): \(cardNote)")
    }

    /// MCP-timeout cleanup for a parked prompt whose request file vanished without
    /// our decision: clear the card, un-park, restore the root (the turn continues
    /// — the MCP already returned the safe default to the model).
    private func timeoutParked(_ prompt: ParkedPrompt) async {
        prompt.locked = true
        parkedPrompts.removeValue(forKey: prompt.id)
        if let cardTs = prompt.cardTs {
            let note = ":hourglass: This prompt timed out and was resolved with the safe default."
            await chatUpdate(channel: prompt.channelId, ts: cardTs, text: note,
                             blocks: [SlackBlocks.section(note)])
        }
        if let turn = inFlightTurns[prompt.convKey], turn.generation == prompt.generation {
            await restoreWorkingRoot(turn: turn)
        }
    }

    /// Generation hygiene (3.4): resolve every parked prompt for a CONVERSATION
    /// (e.g. on Stop or a superseding new turn) with its safe default so no live
    /// button can resolve a dead RPC and no MCP RPC is left hanging.
    private func cancelParkedPrompts(conv: Conversation) async {
        for (_, prompt) in parkedPrompts where prompt.convKey == conv.key && !prompt.locked {
            await finishParked(prompt, decision: safeDefault(for: prompt.kind),
                               cardNote: ":black_square_for_stop: Cancelled — the turn was stopped or superseded.")
        }
    }

    // MARK: - Phase 3.1: clarifying-question resolution

    /// Look up a parked prompt for a button value, enforcing generation hygiene
    /// (3.4). A tap is rejected when: the prompt is gone (already resolved /
    /// expired — a stale tap), already locked (a double-tap racing the first valid
    /// decision), there is no live turn for the channel (the turn ended, so the
    /// prompt's generation can no longer be confirmed current), or the live turn's
    /// generation has moved past the prompt's (a superseding new turn). All four
    /// are "a late tap on a superseded prompt is ignored."
    private func validParked(_ promptId: String) -> ParkedPrompt? {
        guard let prompt = parkedPrompts[promptId] else {
            SlackFileLog.log("parked \(promptId.prefix(8)) not found (stale tap)")
            return nil
        }
        if prompt.locked {
            SlackFileLog.log("parked \(promptId.prefix(8)) already locked (stale tap)")
            return nil
        }
        guard let turn = inFlightTurns[prompt.convKey] else {
            SlackFileLog.log("parked \(promptId.prefix(8)) has no live turn (stale tap)")
            return nil
        }
        if turn.generation != prompt.generation {
            SlackFileLog.log("parked \(promptId.prefix(8)) generation mismatch (stale tap)")
            return nil
        }
        return prompt
    }

    /// A single-select option button: `promptId|qIndex|optIndex`. Records the
    /// chosen label and resolves once every question in the ask is answered.
    private func onAnswerOption(value: String) async {
        let parts = value.split(separator: "|").map(String.init)
        guard parts.count == 3, let qi = Int(parts[1]), let oi = Int(parts[2]),
              let prompt = validParked(parts[0]), prompt.kind == .ask else { return }
        let questions = prompt.request.questions
        guard qi < questions.count, oi < questions[qi].options.count else { return }
        prompt.answers[qi] = questions[qi].options[oi].label
        await maybeResolveAsk(prompt)
    }

    /// Submit on the inline staged card: read each question's HELD selection from
    /// message state (radio = one option, checkboxes = many) and record the chosen
    /// labels, then resolve. Nudges (without resolving) if nothing was picked, so a
    /// stray Submit can't commit "(no answer)".
    private func onAnswerSubmit(promptId: String, payload: [String: Any]) async {
        guard let prompt = validParked(promptId), prompt.kind == .ask else { return }
        let questions = prompt.request.questions
        let state = (payload["state"] as? [String: Any])?["values"] as? [String: Any] ?? [:]
        func label(_ v: String, _ q: HudQuestion) -> String? {
            let p = v.split(separator: "|").map(String.init)
            guard p.count == 3, let oi = Int(p[2]), oi < q.options.count else { return nil }
            return q.options[oi].label
        }
        var recorded = 0
        for (qi, q) in questions.enumerated() {
            let blockId = "ask:\(promptId):\(qi)"
            guard let block = state[blockId] as? [String: Any],
                  let element = block[SlackAction.answerStage] as? [String: Any] else { continue }
            if q.multiSelect {
                let selected = element["selected_options"] as? [[String: Any]] ?? []
                let labels = selected.compactMap { ($0["value"] as? String).flatMap { label($0, q) } }
                if !labels.isEmpty { prompt.answers[qi] = labels.joined(separator: ", "); recorded += 1 }
            } else if let opt = element["selected_option"] as? [String: Any],
                      let v = opt["value"] as? String, let l = label(v, q) {
                prompt.answers[qi] = l; recorded += 1
            }
        }
        if recorded == 0 {
            let user = (payload["user"] as? [String: Any])?["id"] as? String ?? ""
            await postEphemeral(channel: prompt.channelId, user: user,
                                text: "Pick an option (or tap “Let me type it”) before Submit.")
            return
        }
        await maybeResolveAsk(prompt, force: true)
    }

    /// Resolve an ask once every question has an answer (or `force` for a Submit
    /// that swept all multi-selects at once). Single-question asks resolve on the
    /// first tap.
    private func maybeResolveAsk(_ prompt: ParkedPrompt, force: Bool = false) async {
        let questions = prompt.request.questions
        if !force && prompt.answers.count < questions.count {
            // Partial — nudge in-thread so the operator sees progress on a
            // multi-question ask.
            let rootTs = inFlightTurns[prompt.convKey]?.rootTs
            await postMessage(channel: prompt.channelId,
                              text: "Recorded \(prompt.answers.count)/\(questions.count); answer the rest.",
                              threadTs: rootTs)
            return
        }
        let pairs: [(header: String, answer: String)] = questions.enumerated().map { (i, q) in
            (header: q.header, answer: prompt.answers[i] ?? "(no answer)")
        }
        let summary = pairs.map { ":white_check_mark: You chose: \($0.answer)" }.joined(separator: "\n")
        await finishParked(prompt, decision: SupervisorDecision.answers(pairs), cardNote: summary)
    }

    /// Thread-reply precedence (3.1): if a clarifying question is parked for this
    /// CONVERSATION, capture the reply as the next unanswered question's answer.
    /// Returns true if the reply was consumed as an answer.
    private func captureThreadReplyAnswer(conv: Conversation, text: String) -> Bool {
        // The most recently parked ASK prompt for this conversation.
        let asks = parkedPrompts.values
            .filter { $0.convKey == conv.key && $0.kind == .ask && !$0.locked }
            .sorted { $0.createdAt > $1.createdAt }
        guard let prompt = asks.first else { return false }
        let questions = prompt.request.questions
        guard let nextQ = (0..<questions.count).first(where: { prompt.answers[$0] == nil }) else {
            return false
        }
        prompt.answers[nextQ] = text.trimmingCharacters(in: .whitespacesAndNewlines)
        SlackFileLog.log("captured thread reply as answer to q\(nextQ) of \(prompt.id.prefix(8))")
        Task { @MainActor in await self.maybeResolveAsk(prompt) }
        return true
    }

    /// Open the freeform-answer modal ("Let me type it"). value = `promptId|qIndex`.
    private func openAnswerModal(value: String, triggerId: String) async {
        guard !triggerId.isEmpty else { return }
        let parts = value.split(separator: "|").map(String.init)
        guard parts.count == 2, validParked(parts[0]) != nil else { return }
        let view: [String: Any] = [
            "type": "modal",
            "callback_id": SlackAction.answerModal,
            "private_metadata": value,
            "title": ["type": "plain_text", "text": "Your answer"],
            "submit": ["type": "plain_text", "text": "Answer"],
            "close": ["type": "plain_text", "text": "Cancel"],
            "blocks": [[
                "type": "input", "block_id": "answer",
                "label": ["type": "plain_text", "text": "Type your answer"],
                "element": ["type": "plain_text_input", "action_id": "text", "multiline": true]
            ]]
        ]
        await openModal(triggerId: triggerId, view: view)
    }

    /// Submit handler for the freeform answer modal. meta = `promptId|qIndex`.
    private func submitFreeformAnswer(meta: String, answer: String) async {
        let parts = meta.split(separator: "|").map(String.init)
        guard parts.count == 2, let qi = Int(parts[1]),
              let prompt = validParked(parts[0]), prompt.kind == .ask else { return }
        prompt.answers[qi] = answer.isEmpty ? "(no answer)" : answer
        await maybeResolveAsk(prompt)
    }

    /// Open the multi-question staged form (a 2+-question ask). `promptId` rides in
    /// the view's private_metadata; the modal's Submit lands in handleViewSubmission.
    private func openAnswerFormModal(promptId: String, triggerId: String) async {
        guard !triggerId.isEmpty, let prompt = validParked(promptId), prompt.kind == .ask else { return }
        let view = SupervisorCards.questionModalView(promptId: promptId, questions: prompt.request.questions)
        await openModal(triggerId: triggerId, view: view)
    }

    /// Submit handler for the multi-question modal: map each question's staged
    /// selection (radio = one, checkboxes = many) to its chosen label(s), then resolve.
    /// Option values are `qIndex|optIndex`; the promptId came from private_metadata.
    private func submitAnswerForm(promptId: String, view: [String: Any]?) async {
        guard let prompt = validParked(promptId), prompt.kind == .ask else { return }
        let questions = prompt.request.questions
        let values = ((view?["state"] as? [String: Any])?["values"] as? [String: Any]) ?? [:]
        func label(_ v: String, _ q: HudQuestion) -> String? {
            let p = v.split(separator: "|").map(String.init)
            guard p.count == 2, let oi = Int(p[1]), oi < q.options.count else { return nil }
            return q.options[oi].label
        }
        for (qi, q) in questions.enumerated() {
            guard let block = values["askq:\(qi)"] as? [String: Any],
                  let element = block["sel"] as? [String: Any] else { continue }
            if q.multiSelect {
                let selected = element["selected_options"] as? [[String: Any]] ?? []
                let labels = selected.compactMap { ($0["value"] as? String).flatMap { label($0, q) } }
                if !labels.isEmpty { prompt.answers[qi] = labels.joined(separator: ", ") }
            } else if let opt = element["selected_option"] as? [String: Any],
                      let v = opt["value"] as? String, let l = label(v, q) {
                prompt.answers[qi] = l
            }
        }
        await maybeResolveAsk(prompt, force: true)
    }

    // MARK: - Phase 3.2/3.3: permission + plan resolution

    /// The operator's verb on an approval/plan card.
    private enum ApprovalBehavior {
        case allow
        case allowAlways
        case deny(String?)
    }

    /// Resolve an approval/plan prompt to its PermissionResult, writing an
    /// always-allow settings rule when asked (the sanctioned writer of
    /// `.claude/settings.local.json`, S2).
    private func resolveApproval(promptId: String, behavior: ApprovalBehavior) async {
        guard let prompt = validParked(promptId),
              prompt.kind == .approve || prompt.kind == .plan else { return }
        let decision: [String: Any]
        let note: String
        switch behavior {
        case .allow:
            decision = SupervisorDecision.allow()
            note = prompt.kind == .plan
                ? ":white_check_mark: Plan approved — executing."
                : ":white_check_mark: Approved."
        case .allowAlways:
            writeAlwaysAllowRule(cwd: prompt.request.cwd, toolName: prompt.request.toolName)
            decision = SupervisorDecision.allow()
            note = ":white_check_mark: Approved — and always allow `\(prompt.request.toolName)` here."
        case .deny(let msg):
            decision = SupervisorDecision.deny(msg ?? "Denied by the operator.")
            note = msg == nil ? ":no_entry: Denied." : ":no_entry: Denied with a note — the agent will adjust."
        }
        await finishParked(prompt, decision: decision, cardNote: note)
    }

    /// Open the deny-with-note modal (deny carries steering). meta = promptId.
    private func openDenyNoteModal(promptId: String, triggerId: String) async {
        guard !triggerId.isEmpty, validParked(promptId) != nil else { return }
        let view: [String: Any] = [
            "type": "modal",
            "callback_id": SlackAction.denyNoteModal,
            "private_metadata": promptId,
            "title": ["type": "plain_text", "text": "Deny with note"],
            "submit": ["type": "plain_text", "text": "Deny"],
            "close": ["type": "plain_text", "text": "Cancel"],
            "blocks": [[
                "type": "input", "block_id": "note", "optional": true,
                "label": ["type": "plain_text", "text": "What should it do instead?"],
                "element": ["type": "plain_text_input", "action_id": "text", "multiline": true,
                            "placeholder": ["type": "plain_text",
                                            "text": "e.g. don't run it, just write the do-file"]]
            ]]
        ]
        await openModal(triggerId: triggerId, view: view)
    }

    /// Open the edit-plan modal (3.3). meta = promptId.
    private func openEditPlanModal(promptId: String, triggerId: String) async {
        guard !triggerId.isEmpty, let prompt = validParked(promptId) else { return }
        let view: [String: Any] = [
            "type": "modal",
            "callback_id": SlackAction.editPlanModal,
            "private_metadata": promptId,
            "title": ["type": "plain_text", "text": "Edit plan"],
            "submit": ["type": "plain_text", "text": "Send edits"],
            "close": ["type": "plain_text", "text": "Cancel"],
            "blocks": [[
                "type": "input", "block_id": "edits",
                "label": ["type": "plain_text", "text": "How should the plan change?"],
                "element": ["type": "plain_text_input", "action_id": "text", "multiline": true,
                            "initial_value": SlackBlocks.truncate(prompt.request.planText, 2000)]
            ]]
        ]
        await openModal(triggerId: triggerId, view: view)
    }

    /// Append an allow rule to the project's `.claude/settings.local.json` — the
    /// ONLY sanctioned writer of that file (S2). Best-effort; the operator already
    /// approved, so a failure to persist the rule just means a future re-prompt.
    private func writeAlwaysAllowRule(cwd: String, toolName: String) {
        guard !cwd.isEmpty else { return }
        let fm = FileManager.default
        let dir = "\(cwd)/.claude"
        let path = "\(dir)/settings.local.json"
        try? fm.createDirectory(atPath: dir, withIntermediateDirectories: true)
        var settings: [String: Any] = [:]
        if let data = fm.contents(atPath: path),
           let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            settings = json
        }
        var permissions = settings["permissions"] as? [String: Any] ?? [:]
        var allow = permissions["allow"] as? [String] ?? []
        // Bash gets a broad rule here; file tools allow the bare tool name.
        let rule = toolName == "Bash" ? "Bash" : toolName
        if !allow.contains(rule) {
            allow.append(rule)
            permissions["allow"] = allow
            settings["permissions"] = permissions
            if let out = try? JSONSerialization.data(withJSONObject: settings,
                                                     options: [.prettyPrinted, .sortedKeys]) {
                try? out.write(to: URL(fileURLWithPath: path))
                SlackFileLog.log("always-allow rule '\(rule)' written to \(path)")
            }
        }
    }

    // MARK: - Phase 3: per-turn MCP config

    /// Write the per-turn mcp-config that points `claude` at the bundled supervisory
    /// MCP server, carrying the channel + thread + generation + cwd + relay dir +
    /// timeout as env so each parked request is stamped for PER-THREAD routing.
    /// Returns its path, or nil if the bundled script is missing (caller then falls
    /// back to the skip path).
    private func writeMcpConfig(conv: Conversation, generation: Int, cwd: String) -> String? {
        guard let script = mcpScriptPath else {
            SlackFileLog.log("mcp-config: bundled hud-slack-mcp.py not found; falling back")
            return nil
        }
        let config: [String: Any] = [
            "mcpServers": [
                "hud": [
                    "command": "/usr/bin/python3",
                    "args": [script],
                    "env": [
                        "HUD_SLACK_RELAY_DIR": Self.relayDir,
                        "HUD_SLACK_CHANNEL": conv.channelId,
                        "HUD_SLACK_THREAD": conv.threadRootTs,
                        "HUD_SLACK_GENERATION": String(generation),
                        "HUD_SLACK_CWD": cwd,
                        "HUD_SLACK_TIMEOUT": String(Int(Self.parkedPromptTimeout))
                    ]
                ]
            ]
        ]
        let dir = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/ClaudeHUD")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        // Name by a filesystem-safe conversation token so parallel same-channel
        // threads never clobber each other's per-turn config.
        let safe = "\(conv.channelId)-\(conv.threadRootTs)".replacingOccurrences(of: ".", with: "-")
        let url = dir.appendingPathComponent("slack-mcp-\(safe).json")
        guard let data = try? JSONSerialization.data(withJSONObject: config, options: [.prettyPrinted]) else {
            return nil
        }
        do {
            try data.write(to: url)
            return url.path
        } catch {
            SlackFileLog.log("mcp-config write failed: \(error.localizedDescription)")
            return nil
        }
    }

    // MARK: - Phase 2.1/2.2: activity trail driving

    /// Lazily create (or fetch) the conversation's live trail. Needs the turn's
    /// root ts; returns nil until the root is posted. Keyed by `Conversation.key`;
    /// the trail stores the real channel id for its own Slack posts.
    private func ensureTrail(convKey: String) -> TurnTrail? {
        if let t = trails[convKey] { return t }
        guard let turn = inFlightTurns[convKey], let root = turn.rootTs else { return nil }
        let t = TurnTrail(channelId: turn.channelId, rootTs: root)
        trails[convKey] = t
        return t
    }

    /// Fold one stream event into the live trail, then schedule a debounced
    /// render. Only tool_use / tool_result / thinking land here (the answer text
    /// promotes to the root, never the trail).
    private func recordTrailEvent(convKey: String, event: CLIStreamEvent) {
        guard let trail = ensureTrail(convKey: convKey) else { return }
        switch event {
        case .toolUse(let t):
            trail.addToolUse(t)
            scheduleTrailRender(convKey)
        case .toolResult(let r):
            trail.closeResult(r)
            scheduleTrailRender(convKey)
        case .assistant(let a) where a.isThinking:
            if let th = a.thinkingText { trail.addThinking(th); scheduleTrailRender(convKey) }
        default:
            break
        }
        // Fan the same event into the subagent tree (§4.1) — independent of the
        // flat trail, only materializes when the turn actually spawns subagents.
        feedSubagentTree(convKey: convKey, event: event)
    }

    // MARK: - Phase 4.1: subagent tree driving

    /// Lazily create (or fetch) the conversation's subagent tree. Needs the turn's
    /// root ts; returns nil until the root is posted.
    private func ensureTree(convKey: String) -> SubagentTree? {
        if let t = subagentTrees[convKey] { return t }
        guard let turn = inFlightTurns[convKey], let root = turn.rootTs else { return nil }
        let t = SubagentTree(channelId: turn.channelId, rootTs: root)
        subagentTrees[convKey] = t
        return t
    }

    /// Fold one stream event into the subagent tree (§4.1). A `Task` tool_use
    /// opens a branch (and lazily births the tree — most turns never get here); a
    /// child tool call (carrying `parent_tool_use_id`) rolls up to its branch; a
    /// `tool_result` keyed by a branch's Task id closes it. Only re-renders when
    /// the event actually touched the tree, so a non-fan-out turn is untouched.
    private func feedSubagentTree(convKey: String, event: CLIStreamEvent) {
        switch event {
        case .toolUse(let t):
            if t.toolName == "Task" {
                guard let tree = ensureTree(convKey: convKey) else { return }
                tree.addTask(t)
                SlackFileLog.log("subagent tree: \(convKey) spawned '\(SubagentTree.taskTitle(t.input))' (\(tree.total) total)")
                scheduleTreeRender(convKey)
            } else if t.parentToolUseId != nil {
                // A subagent's own tool call — only meaningful once its tree exists.
                guard let tree = subagentTrees[convKey], tree.recordChild(t) else { return }
                scheduleTreeRender(convKey)
            }
        case .toolResult(let r):
            guard let tree = subagentTrees[convKey], tree.closeBranch(r) else { return }
            SlackFileLog.log("subagent tree: \(convKey) branch closed (\(tree.doneCount)/\(tree.total) done)")
            scheduleTreeRender(convKey)
        default:
            break
        }
    }

    /// The live 5-hour usage-window headroom as a terse string for the tree header
    /// (Plan cost rule: tokens + usage window, NO dollars). Nil when there is no
    /// reading at all (degrade to no cost line, never block).
    private func usageWindowHint() -> String? {
        guard let w = usageService.usage?.fiveHour else { return nil }
        return "usage window \(Int(w.utilization.rounded()))%"
    }

    /// Debounce tree re-renders to ~1/2s (shares the trail's budget, within
    /// chat.update's 1/3s ceiling). Mirrors `scheduleTrailRender`.
    private func scheduleTreeRender(_ convKey: String) {
        guard let tree = subagentTrees[convKey] else { return }
        tree.dirty = true
        let since = Date().timeIntervalSince(tree.lastRenderedAt)
        if since >= Self.trailDebounce {
            Task { await renderTree(convKey) }
        } else if !tree.flushScheduled {
            tree.flushScheduled = true
            let delay = Self.trailDebounce - since
            Task { @MainActor in
                try? await Task.sleep(nanoseconds: UInt64(max(delay, 0) * 1_000_000_000))
                tree.flushScheduled = false
                if tree.dirty { await renderTree(convKey) }
            }
        }
    }

    /// Render the tree's single thread message — posting it the first time,
    /// `chat.update`-ing it in place thereafter (one message, never N). Reentrancy
    /// guarded so two near-simultaneous renders can't double-post the thread reply.
    private func renderTree(_ convKey: String) async {
        guard let tree = subagentTrees[convKey], tree.hasBranches else { return }
        if tree.rendering { tree.dirty = true; return }
        tree.rendering = true
        tree.dirty = false
        tree.lastRenderedAt = Date()

        let blocks = tree.blocks(usageHint: usageWindowHint())
        if let ts = tree.threadTs {
            await chatUpdate(channel: tree.channelId, ts: ts, text: "Subagent tree", blocks: blocks)
        } else {
            let ts = await postMessage(channel: tree.channelId, text: "Subagent tree",
                                       threadTs: tree.rootTs, blocks: blocks)
            tree.threadTs = ts
            SlackFileLog.log("subagent tree: posted thread message ts=\(ts ?? "nil") root=\(tree.rootTs)")
        }

        tree.rendering = false
        if tree.dirty { await renderTree(convKey) }
    }

    /// Final tree render on turn resolution: flip lingering running branches to
    /// done, fold in the whole-turn token total (NO dollars), force one last
    /// update, then retire it. No-op when the turn never spawned a subagent.
    private func finalizeTree(_ convKey: String, tokens: Int = 0) async {
        guard let tree = subagentTrees[convKey], tree.hasBranches else {
            subagentTrees.removeValue(forKey: convKey)
            return
        }
        tree.finished = true
        if tokens > 0 { tree.finalTokens = tokens }
        tree.markRunningDone()
        tree.dirty = true
        tree.lastRenderedAt = .distantPast   // bypass debounce for the final paint
        await renderTree(convKey)
        subagentTrees.removeValue(forKey: convKey)
    }

    /// Debounce trail re-renders to ~1/2s (Plan §L4, within chat.update's 1/3s).
    /// Renders immediately if the debounce window has elapsed; otherwise arms a
    /// single deferred flush. The heartbeat tick is the backstop for the final
    /// batch when the stream falls silent before the window elapses.
    private func scheduleTrailRender(_ convKey: String) {
        guard let trail = trails[convKey] else { return }
        trail.dirty = true
        let since = Date().timeIntervalSince(trail.lastRenderedAt)
        if since >= Self.trailDebounce {
            Task { await renderTrail(convKey) }
        } else if !trail.flushScheduled {
            trail.flushScheduled = true
            let delay = Self.trailDebounce - since
            Task { @MainActor in
                try? await Task.sleep(nanoseconds: UInt64(max(delay, 0) * 1_000_000_000))
                trail.flushScheduled = false
                if trail.dirty { await renderTrail(convKey) }
            }
        }
    }

    /// Fold the trail's latest state into the SINGLE turn message: the trail no
    /// longer owns its own thread message — its counts-only summary + Show-details
    /// /Show-reasoning buttons live in the root tile, so a trail render just
    /// repaints that root (`workingBlocks` reads the trail). Reentrancy + debounce
    /// bookkeeping preserved. No-op once the turn is resolved/stopping (the
    /// terminal card owns the root then).
    private func renderTrail(_ convKey: String) async {
        guard let trail = trails[convKey], !trail.isEmpty else { return }
        if trail.rendering { trail.dirty = true; return }
        trail.rendering = true
        trail.dirty = false
        trail.lastRenderedAt = Date()

        if let turn = inFlightTurns[convKey], let ts = turn.rootTs,
           !turn.resolved, !turn.stopping {
            let now = Date()
            let warning = now.timeIntervalSince(turn.lastEventAt) >= 45
            await chatUpdate(channel: turn.channelId, ts: ts, text: "Working…",
                             blocks: workingBlocks(turn: turn, now: now, warning: warning, stopping: false))
        }

        trail.rendering = false
        // Coalesce any changes that arrived mid-render.
        if trail.dirty { await renderTrail(convKey) }
    }

    /// Retire the trail on turn resolution: flip lingering running lines to done
    /// and move it to `trailsByRoot` so its Show-details / Show-reasoning buttons
    /// (now carried on the single terminal card) keep resolving after the turn
    /// leaves the active map. No separate trail message to repaint — the terminal
    /// render owns the root. No-op when the turn produced no trail-worthy events.
    private func finalizeTrail(_ convKey: String) async {
        guard let trail = trails[convKey] else { return }
        trail.finished = true
        trail.markRunningDone()
        trailsByRoot[trail.rootTs] = trail
        pruneTrailsByRoot()
        trails.removeValue(forKey: convKey)
    }

    private func pruneTrailsByRoot() {
        guard trailsByRoot.count > Self.maxTrailsByRoot else { return }
        // Drop the oldest by root ts (Slack ts sorts chronologically as a string
        // prefix is monotone, but parse to be safe).
        let sorted = trailsByRoot.keys.sorted { (Double($0) ?? 0) < (Double($1) ?? 0) }
        for key in sorted.prefix(trailsByRoot.count - Self.maxTrailsByRoot) {
            trailsByRoot.removeValue(forKey: key)
        }
    }

    /// Look up a trail by its root ts (live first, then the retired map) for the
    /// Show-details / Show-reasoning button handlers.
    private func trail(forRoot rootTs: String) -> TurnTrail? {
        if let live = trails.values.first(where: { $0.rootTs == rootTs }) { return live }
        return trailsByRoot[rootTs]
    }

    // MARK: - Phase 2.1/2.2: Show details / Show reasoning handlers

    /// Open the raw-I/O modal for a turn (§2.1): the bytes the thread keeps
    /// collapsed, secret-redacted and size-capped inside `TurnTrail`.
    private func showTrailDetails(rootTs: String, triggerId: String) async {
        guard let trail = trail(forRoot: rootTs) else {
            SlackFileLog.log("show-details: no trail for root \(rootTs)")
            return
        }
        guard !triggerId.isEmpty else {
            SlackFileLog.log("show-details: missing trigger_id")
            return
        }
        SlackFileLog.log("show-details: root=\(rootTs)")
        await openModal(triggerId: triggerId, view: trail.detailsModalView())
    }

    /// Open the reasoning MODAL (§2.2). With the one-message turn there is no
    /// separate trail message to expand inline, so reasoning lives ONLY in the
    /// modal now — short or long, it always opens there.
    private func toggleReasoning(rootTs: String, triggerId: String) async {
        guard let trail = trail(forRoot: rootTs) else {
            SlackFileLog.log("show-reasoning: no trail for root \(rootTs)")
            return
        }
        guard !triggerId.isEmpty else {
            SlackFileLog.log("show-reasoning: missing trigger_id")
            return
        }
        SlackFileLog.log("show-reasoning: opening modal root=\(rootTs)")
        await openModal(triggerId: triggerId, view: trail.reasoningModalView())
    }

    /// Context preamble prepended to the first message of a FRESH channel
    /// session: points Claude at the project's Obsidian notes and tells it to
    /// read them for current context before answering. Reads are permitted in
    /// every mode (Read is never disallowed), so the model can fetch them.
    private static func contextPreamble(projectName: String, cwd: String,
                                        obsidianPath: String, userText: String) -> String {
        // The "[ClaudeHUD Slack session." prefix is ALSO the ingest marker:
        // vault-ingest.sh::is_machine_transcript and SessionHistoryService.
        // classifyHead treat a first user message with this prefix as a real
        // (human-driven) session. Both branches below must keep it.
        if projectName == "DM" {
            return """
            [ClaudeHUD Slack session. Generic DM surface — no project bound. You are \
            a general-purpose assistant working in a scratch directory (\(cwd)): quick \
            questions, small tasks, cross-project lookups. Vault projects live under \
            ~/Documents/Obsidian/<Project>/ — read a project's Tasks.md only when the \
            user names one. Keep any file writes inside the working directory unless \
            the user directs otherwise.]

            User message: \(userText)
            """
        }
        return """
        [ClaudeHUD Slack session. Project: \(projectName). This is a FOCUSED \
        single-project session — you already know the project, so do NOT run the \
        vault-wide bootstrap: do NOT read Obsidian HOME.md, index.md, schema.md, \
        Daily Notes, or any other project's folder. You're running in this project's \
        working directory (\(cwd)). For context, read ONLY this project's own Obsidian \
        folder: \(obsidianPath)/Tasks.md (the authoritative active-task list), plus \
        \(obsidianPath)/Technical Notes.md and \(obsidianPath)/Dashboard.md if they \
        exist. Stay within \(obsidianPath)/ and the working directory; do not wander \
        the rest of the vault. Read what's relevant, then address the user's message. \
        Tasks.md is the authoritative task list — maintain it as you work: when your \
        work completes one of its ## Active tasks, move that bullet (with its \
        indented detail) to ## Completed with today's date appended in parentheses \
        and set the frontmatter `updated:` to today; when you discover new work, \
        append a `- **Title**: summary` bullet to ## Active. Never delete tasks, \
        never touch ## Triage (unreviewed intake), never edit frontmatter keys other \
        than `updated:`. \
        When you write Markdown into Obsidian vault notes, always put a BLANK LINE \
        before any table and keep each table row on a SINGLE line (never hard-wrap a \
        row) so the table renders correctly in Obsidian.]

        User message: \(userText)
        """
    }

    // MARK: - Markdown → Slack mrkdwn

    /// Convert standard Markdown to Slack "mrkdwn". Conversion is applied ONLY
    /// outside code spans — inline `` `code` `` and fenced ``` ``` blocks pass
    /// through verbatim (the string is split on those first). Rules: `**b**`/
    /// `__b__` → `*b*`; `# header` lines → `*header*`; `- `/`* ` bullets → `• `;
    /// `[t](u)` → `<u|t>`. Inline `_italic_`, blockquotes, numbered lists, and
    /// tables are left as-is.
    static func toSlackMrkdwn(_ md: String) -> String {
        let chars = Array(md)
        var out = ""
        var text = ""
        var i = 0

        func flush() {
            if !text.isEmpty { out += convertNonCode(text); text = "" }
        }

        while i < chars.count {
            // Fenced code block ``` … ``` (passes through, fences included).
            if chars[i] == "`", i + 2 < chars.count, chars[i + 1] == "`", chars[i + 2] == "`" {
                flush()
                var j = i + 3
                var closed = false
                while j + 2 < chars.count {
                    if chars[j] == "`", chars[j + 1] == "`", chars[j + 2] == "`" {
                        closed = true
                        break
                    }
                    j += 1
                }
                let end = closed ? j + 3 : chars.count
                out += String(chars[i..<end])
                i = end
                continue
            }
            // Inline code `…` (passes through, backticks included).
            if chars[i] == "`" {
                flush()
                var j = i + 1
                var closed = false
                while j < chars.count {
                    if chars[j] == "`" { closed = true; break }
                    j += 1
                }
                if closed {
                    out += String(chars[i...j])
                    i = j + 1
                } else {
                    // Unterminated backtick — treat as literal text.
                    text.append(chars[i])
                    i += 1
                }
                continue
            }
            text.append(chars[i])
            i += 1
        }
        flush()
        return out
    }

    /// Apply the inline + line conversions to a non-code segment. GFM tables
    /// (a row of `|` cells whose SECOND line is a `-`/`:`/`|`/space separator)
    /// are reformatted as an aligned fixed-width monospace table wrapped in a
    /// ``` fence; all other lines get the usual link/bold/header/bullet rules.
    private static func convertNonCode(_ s: String) -> String {
        let rawLines = s.components(separatedBy: "\n")
        var out: [String] = []
        var idx = 0
        while idx < rawLines.count {
            // GFM table: this line has cells, the next is a separator row,
            // and the header parses to >= 2 columns.
            if idx + 1 < rawLines.count,
               rawLines[idx].contains("|"),
               isTableSeparator(rawLines[idx + 1]),
               parseTableRow(rawLines[idx]).count >= 2 {
                var blockEnd = idx + 2
                while blockEnd < rawLines.count, rawLines[blockEnd].contains("|") {
                    blockEnd += 1
                }
                let body = Array(rawLines[(idx + 2)..<blockEnd])
                out.append(formatTableBlock(header: rawLines[idx], body: body))
                idx = blockEnd
                continue
            }
            out.append(convertLine(rawLines[idx]))
            idx += 1
        }
        return out.joined(separator: "\n")
    }

    /// Inline + line conversions for a single (non-table) line.
    private static func convertLine(_ line: String) -> String {
        var l = line
        // Links [text](url) -> <url|text> (before bold, so bold inside link
        // text still converts afterward).
        l = regexReplace(l, #"\[([^\]]+)\]\(([^)\s]+)\)"#, "<$2|$1>")
        // Bold **x** / __x__ -> *x*.
        l = regexReplace(l, #"\*\*(.+?)\*\*"#, "*$1*")
        l = regexReplace(l, #"__(.+?)__"#, "*$1*")
        // # … ###### header -> bold the line text, drop hashes.
        l = regexReplace(l, #"^\s*#{1,6}[ \t]+(.*\S)[ \t]*$"#, "*$1*")
        // "- " / "* " bullet -> "• " (preserve leading indent).
        l = regexReplace(l, #"^([ \t]*)[-*] (.*)$"#, "$1• $2")
        return l
    }

    /// True for a GFM separator row: non-empty after trimming, contains a `-`,
    /// and is made up only of `-`, `:`, `|`, and whitespace.
    private static func isTableSeparator(_ line: String) -> Bool {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty, trimmed.contains("-") else { return false }
        return trimmed.allSatisfy { "-:| \t".contains($0) }
    }

    /// Split a table row on `|`, trim each cell, and drop the leading/trailing
    /// empty cells produced by surrounding pipes.
    private static func parseTableRow(_ line: String) -> [String] {
        var cells = line.components(separatedBy: "|")
            .map { $0.trimmingCharacters(in: .whitespaces) }
        if cells.first == "" { cells.removeFirst() }
        if cells.last == "" { cells.removeLast() }
        return cells
    }

    /// Render a header row + body rows as an aligned fixed-width monospace
    /// table inside a single ``` fence. Columns are padded to their max width
    /// and joined with " | "; a dashed underline separates header from body.
    private static func formatTableBlock(header: String, body: [String]) -> String {
        let headerCells = parseTableRow(header)
        let bodyRows = body.map { parseTableRow($0) }
        let colCount = max(headerCells.count, bodyRows.map { $0.count }.max() ?? 0)
        func pad(_ row: [String]) -> [String] {
            var r = row
            while r.count < colCount { r.append("") }
            return r
        }
        let h = pad(headerCells)
        let rows = bodyRows.map(pad)
        var widths = [Int](repeating: 0, count: colCount)
        for c in 0..<colCount {
            widths[c] = h[c].count
            for r in rows { widths[c] = max(widths[c], r[c].count) }
        }
        func render(_ row: [String]) -> String {
            (0..<colCount)
                .map { c in row[c].padding(toLength: widths[c], withPad: " ", startingAt: 0) }
                .joined(separator: " | ")
        }
        var lines: [String] = [render(h)]
        lines.append((0..<colCount)
            .map { String(repeating: "-", count: widths[$0]) }
            .joined(separator: " | "))
        lines.append(contentsOf: rows.map(render))
        return "```\n" + lines.joined(separator: "\n") + "\n```"
    }

    private static func regexReplace(_ s: String, _ pattern: String, _ template: String) -> String {
        guard let re = try? NSRegularExpression(pattern: pattern) else { return s }
        let range = NSRange(s.startIndex..., in: s)
        return re.stringByReplacingMatches(in: s, range: range, withTemplate: template)
    }

    /// One-line tool summary like `(ran Read, Edit x2)`, or "" if no tools.
    private static func toolSummary(_ counts: [String: Int]) -> String {
        guard !counts.isEmpty else { return "" }
        let parts = counts.sorted { $0.key < $1.key }
            .map { $0.value > 1 ? "\($0.key) x\($0.value)" : $0.key }
        return "(ran \(parts.joined(separator: ", ")))"
    }

    /// Post `text` to a channel, split into <=3800-char messages.
    private func postChunked(channel: String, text: String) async {
        for chunk in Self.splitChunks(text) {
            await postMessage(channel: channel, text: chunk)
        }
    }

    /// Split `text` into <=`limit`-char chunks, preferring to break on a
    /// newline so long replies fit Slack's per-message limit. Empty input → [].
    private static func splitChunks(_ text: String, limit: Int = 3800) -> [String] {
        if text.isEmpty { return [] }
        if text.count <= limit { return [text] }
        // Group lines into blocks where each ``` … ``` fenced block (e.g. a
        // converted table) is one atomic unit, then greedily pack blocks into
        // chunks. A fenced block is only split if it alone exceeds `limit`.
        let lines = text.components(separatedBy: "\n")
        var blocks: [String] = []
        var i = 0
        while i < lines.count {
            if lines[i].hasPrefix("```") {
                var j = i + 1
                while j < lines.count, !lines[j].hasPrefix("```") { j += 1 }
                let end = min(j, lines.count - 1)
                blocks.append(lines[i...end].joined(separator: "\n"))
                i = end + 1
            } else {
                blocks.append(lines[i])
                i += 1
            }
        }
        var chunks: [String] = []
        var current = ""
        for b in blocks {
            let addition = current.isEmpty ? b : "\n" + b
            if current.count + addition.count <= limit {
                current += addition
            } else {
                if !current.isEmpty { chunks.append(current); current = "" }
                if b.count <= limit {
                    current = b
                } else {
                    chunks.append(contentsOf: hardSplitChunks(b, limit: limit))
                }
            }
        }
        if !current.isEmpty { chunks.append(current) }
        return chunks
    }

    /// Char-based fallback split (breaks at the last newline before `limit`,
    /// else mid-line) for a single block that alone exceeds `limit`.
    private static func hardSplitChunks(_ text: String, limit: Int) -> [String] {
        var chunks: [String] = []
        var remaining = Substring(text)
        while !remaining.isEmpty {
            let hardEnd = remaining.index(remaining.startIndex, offsetBy: limit, limitedBy: remaining.endIndex) ?? remaining.endIndex
            var chunkEnd = hardEnd
            if hardEnd != remaining.endIndex,
               let nl = remaining[remaining.startIndex..<hardEnd].lastIndex(of: "\n"),
               nl > remaining.startIndex {
                chunkEnd = remaining.index(after: nl)
            }
            chunks.append(String(remaining[remaining.startIndex..<chunkEnd]))
            remaining = remaining[chunkEnd...]
        }
        return chunks
    }

    // MARK: - Per-conversation session persistence

    private static var sessionsFileURL: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/ClaudeHUD/slack-sessions.json")
    }
    private static var defaultsFileURL: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/ClaudeHUD/slack-defaults.json")
    }

    /// The conversation-key separator. Persisted keys that contain it are
    /// per-conversation; keys without it are LEGACY per-channel entries.
    private static let convKeySeparator = "\u{0001}"

    private func loadChannelSessions() {
        // Channel-level config defaults (mode/effort/followup/maxTurns).
        if let data = try? Data(contentsOf: Self.defaultsFileURL),
           let map = try? JSONDecoder().decode([String: ChannelSession].self, from: data) {
            channelDefaults = map
            SlackFileLog.log("loaded \(map.count) channel defaults")
        }
        guard let data = try? Data(contentsOf: Self.sessionsFileURL),
              let map = try? JSONDecoder().decode([String: ChannelSession].self, from: data) else { return }
        // MIGRATION: this file used to be keyed by channel id (per-channel model).
        // Per-conversation keys carry the U+0001 separator; any key WITHOUT it is a
        // legacy per-channel entry. Migrate its CONFIG into channelDefaults (so the
        // operator's mode/effort survive) and drop its sessionId/cwd (stranded — a
        // per-channel session id has no thread to resume into in the new model).
        var migrated = 0
        for (key, session) in map {
            if key.contains(Self.convKeySeparator) {
                channelSessions[key] = session
            } else {
                // Legacy per-channel entry → seed channel defaults (config only).
                if channelDefaults[key] == nil {
                    channelDefaults[key] = ChannelSession(sessionId: nil,
                                                          permissionMode: session.permissionMode,
                                                          cwd: nil, effort: session.effort,
                                                          followup: session.followup,
                                                          maxTurns: session.maxTurns)
                }
                migrated += 1
            }
        }
        SlackFileLog.log("loaded \(channelSessions.count) conversation sessions (migrated \(migrated) legacy per-channel)")
        if migrated > 0 {
            saveChannelSessions()
            saveChannelDefaults()
        }
    }

    private func saveChannelDefaults() {
        Self.writeJSON(channelDefaults, to: Self.defaultsFileURL, label: "saveChannelDefaults")
    }

    private func saveChannelSessions() {
        guard let data = try? JSONEncoder().encode(channelSessions) else { return }
        let url = Self.sessionsFileURL
        try? FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        do {
            try data.write(to: url, options: [.atomic])
            try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
        } catch {
            SlackFileLog.log("saveChannelSessions failed: \(error.localizedDescription)")
        }
    }

    // MARK: - Channel → project resolution

    /// Match a channel name to a vault project using the same `normalize` +
    /// `fuzzyMatch` rule the rest of the app uses. The working directory comes
    /// from the project's first absolute `cwds:` entry (`primaryCwd`), falling
    /// back to the Obsidian folder path when no cwd is declared.
    private func resolveProject(forChannelName channelName: String) -> (name: String, cwd: String, obsidianPath: String)? {
        let target = ProjectService.normalize(channelName)
        for project in vaultProjects.projects {
            let candidate = ProjectService.normalize(project.name)
            if ProjectService.fuzzyMatch(target, candidate) {
                let obsidianPath = project.folder.path
                let cwd = project.primaryCwd ?? obsidianPath
                return (project.name, cwd, obsidianPath)
            }
        }
        return nil
    }

    /// Resolve a channel id to its name via `conversations.info`, caching the
    /// result (channel names are stable enough for a session).
    private func channelName(for channelId: String) async -> String? {
        if let cached = channelNameCache[channelId] { return cached }
        guard let botToken else { return nil }

        var req = URLRequest(url: URL(string: "https://slack.com/api/conversations.info")!)
        req.httpMethod = "POST"
        req.setValue("Bearer \(botToken)", forHTTPHeaderField: "Authorization")
        req.setValue("application/x-www-form-urlencoded; charset=utf-8", forHTTPHeaderField: "Content-Type")
        req.httpBody = "channel=\(channelId)".data(using: .utf8)

        do {
            let (data, _) = try await session.data(for: req)
            let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] ?? [:]
            guard json["ok"] as? Bool == true,
                  let channel = json["channel"] as? [String: Any],
                  let name = channel["name"] as? String else {
                let err = json["error"] as? String ?? "unknown"
                logger.error("conversations.info failed: \(err)")
                return nil
            }
            channelNameCache[channelId] = name
            return name
        } catch {
            logger.error("conversations.info request failed: \(error.localizedDescription)")
            return nil
        }
    }

    // MARK: - Outbound

    /// Post a message; returns the new message `ts` (for later `chat.update`),
    /// or nil on failure. `threadTs` posts into a thread (the turn's work lane,
    /// §1.2); `blocks` carries Block Kit (status lines, control bars). `text` is
    /// always sent as the notification/fallback string even when blocks present.
    @discardableResult
    private func postMessage(channel: String, text: String,
                             threadTs: String? = nil,
                             blocks: [[String: Any]]? = nil) async -> String? {
        guard let botToken else { return nil }

        var req = URLRequest(url: URL(string: "https://slack.com/api/chat.postMessage")!)
        req.httpMethod = "POST"
        req.setValue("Bearer \(botToken)", forHTTPHeaderField: "Authorization")
        req.setValue("application/json; charset=utf-8", forHTTPHeaderField: "Content-Type")
        var body: [String: Any] = ["channel": channel, "text": text]
        if let threadTs { body["thread_ts"] = threadTs }
        if let blocks { body["blocks"] = blocks }
        req.httpBody = try? JSONSerialization.data(withJSONObject: body)

        do {
            let (data, _) = try await session.data(for: req)
            let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] ?? [:]
            if json["ok"] as? Bool != true {
                let err = json["error"] as? String ?? "unknown"
                logger.error("chat.postMessage failed: \(err)")
                lastError = err
                return nil
            }
            return json["ts"] as? String
        } catch {
            logger.error("chat.postMessage request failed: \(error.localizedDescription)")
            lastError = error.localizedDescription
            return nil
        }
    }

    /// Post an ephemeral message visible only to `user` (2.4 Queue/Steer prompt).
    /// Uses `chat:write` (no extra scope). Returns the ephemeral `message_ts`,
    /// which is NOT a normal ts (can't be `chat.update`-d); use the interactive
    /// payload's `response_url` + `replaceEphemeral` to clear it after a choice.
    @discardableResult
    private func postEphemeral(channel: String, user: String, text: String,
                               blocks: [[String: Any]]? = nil) async -> String? {
        guard let botToken, !user.isEmpty else { return nil }
        var req = URLRequest(url: URL(string: "https://slack.com/api/chat.postEphemeral")!)
        req.httpMethod = "POST"
        req.setValue("Bearer \(botToken)", forHTTPHeaderField: "Authorization")
        req.setValue("application/json; charset=utf-8", forHTTPHeaderField: "Content-Type")
        var body: [String: Any] = ["channel": channel, "user": user, "text": text]
        if let blocks { body["blocks"] = blocks }
        req.httpBody = try? JSONSerialization.data(withJSONObject: body)
        do {
            let (data, _) = try await session.data(for: req)
            let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] ?? [:]
            if json["ok"] as? Bool != true {
                let err = json["error"] as? String ?? "unknown"
                SlackFileLog.log("chat.postEphemeral failed: \(err)")
                lastError = err
                return nil
            }
            return json["message_ts"] as? String
        } catch {
            SlackFileLog.log("chat.postEphemeral request failed: \(error.localizedDescription)")
            return nil
        }
    }

    /// Replace an ephemeral prompt with a short confirmation via its `response_url`
    /// (the only handle to an ephemeral message), so the Queue/Steer buttons don't
    /// linger after a choice. Best-effort; silent on failure.
    private func replaceEphemeral(responseUrl: String?, text: String) async {
        guard let responseUrl, let url = URL(string: responseUrl) else { return }
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("application/json; charset=utf-8", forHTTPHeaderField: "Content-Type")
        req.httpBody = try? JSONSerialization.data(withJSONObject: [
            "response_type": "ephemeral", "replace_original": true, "text": text
        ])
        _ = try? await session.data(for: req)
    }

    /// Edit an existing message in place — the root's working card becomes its
    /// terminal card (§1.3), swapped on the same ts so the anchor is stable.
    /// Passing `blocks` REPLACES the message's blocks (pass the full terminal
    /// block set); `text` is the fallback/notification string. Uses `chat:write`.
    private func chatUpdate(channel: String, ts: String, text: String,
                            blocks: [[String: Any]]? = nil) async {
        guard let botToken else { return }

        var req = URLRequest(url: URL(string: "https://slack.com/api/chat.update")!)
        req.httpMethod = "POST"
        req.setValue("Bearer \(botToken)", forHTTPHeaderField: "Authorization")
        req.setValue("application/json; charset=utf-8", forHTTPHeaderField: "Content-Type")
        var body: [String: Any] = ["channel": channel, "ts": ts, "text": text]
        // Always send `blocks` on an update so a text-only update CLEARS stale
        // blocks (omitting the key would leave the prior blocks rendered).
        body["blocks"] = blocks ?? []
        req.httpBody = try? JSONSerialization.data(withJSONObject: body)

        do {
            let (data, _) = try await session.data(for: req)
            let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] ?? [:]
            if json["ok"] as? Bool != true {
                let err = json["error"] as? String ?? "unknown"
                logger.error("chat.update failed: \(err)")
                SlackFileLog.log("chat.update failed: \(err)")
                lastError = err
            }
        } catch {
            logger.error("chat.update request failed: \(error.localizedDescription)")
            lastError = error.localizedDescription
        }
    }

    /// Open a Block Kit modal (`views.open`) against a fresh `trigger_id`. Used by
    /// the Resume-with-changes flow (1.4). Trigger ids expire ~3s after the click,
    /// so this is called promptly from the already-acked interactive dispatch.
    private func openModal(triggerId: String, view: [String: Any]) async {
        guard let botToken else { return }
        var req = URLRequest(url: URL(string: "https://slack.com/api/views.open")!)
        req.httpMethod = "POST"
        req.setValue("Bearer \(botToken)", forHTTPHeaderField: "Authorization")
        req.setValue("application/json; charset=utf-8", forHTTPHeaderField: "Content-Type")
        req.httpBody = try? JSONSerialization.data(withJSONObject: ["trigger_id": triggerId, "view": view])
        do {
            let (data, _) = try await session.data(for: req)
            let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] ?? [:]
            if json["ok"] as? Bool != true {
                let err = json["error"] as? String ?? "unknown"
                logger.error("views.open failed: \(err)")
                SlackFileLog.log("views.open failed: \(err)")
                lastError = err
            } else {
                SlackFileLog.log("views.open ok")
            }
        } catch {
            logger.error("views.open request failed: \(error.localizedDescription)")
            SlackFileLog.log("views.open request failed: \(error.localizedDescription)")
        }
    }

    // MARK: - Channel sync (project → channel, additive only)

    /// Ensure every (non-opted-out, non-excluded) vault project has a matching
    /// public Slack channel that the bot has joined. ADDITIVE ONLY — never
    /// archives, deletes, or renames. Returns (projects considered, channels
    /// created). Safe to call repeatedly (idempotent).
    @discardableResult
    func syncChannels() async -> (projects: Int, created: Int) {
        guard botToken != nil else { return (0, 0) }

        var existing = await listChannels()   // slug → channel id
        var considered = 0
        var created = 0

        for project in vaultProjects.projects {
            if ProjectService.excludedFolderNames.contains(project.name) { continue }
            if slackOptOut(project) {
                SlackFileLog.log("sync: project \(project.name) -> slack:false; skipped")
                continue
            }
            let slug = Self.slugify(project.name)
            guard !slug.isEmpty else {
                SlackFileLog.log("sync: project \(project.name) -> empty slug; skipped")
                continue
            }
            considered += 1

            if let id = existing[slug] {
                await joinChannel(id: id)
                SlackFileLog.log("sync: project \(project.name) -> #\(slug) [exists] [joined]")
                continue
            }

            if let id = await createChannel(name: slug) {
                existing[slug] = id
                created += 1
                await joinChannel(id: id)
                SlackFileLog.log("sync: project \(project.name) -> #\(slug) [created] [joined]")
            } else {
                SlackFileLog.log("sync: project \(project.name) -> #\(slug) [create failed]")
            }
        }
        return (considered, created)
    }

    /// Read a project's `Tasks.md` frontmatter for a `slack: false` (or `no`)
    /// opt-out. Absent key → opted in.
    private func slackOptOut(_ project: VaultProjectService.Project) -> Bool {
        guard let content = try? String(contentsOf: project.tasksPath, encoding: .utf8),
              content.hasPrefix("---\n") else { return false }
        let body = String(content.dropFirst(4))
        guard let end = body.range(of: "\n---\n") else { return false }
        for line in body[..<end.lowerBound].components(separatedBy: "\n") {
            guard !line.hasPrefix(" "), !line.hasPrefix("\t"),
                  let colon = line.firstIndex(of: ":") else { continue }
            let key = String(line[..<colon]).trimmingCharacters(in: .whitespaces)
            if key == "slack" {
                let val = String(line[line.index(after: colon)...])
                    .trimmingCharacters(in: CharacterSet(charactersIn: " '\""))
                    .lowercased()
                return val == "false" || val == "no"
            }
        }
        return false
    }

    /// Enumerate existing public channels (paginated), returning name → id.
    private func listChannels() async -> [String: String] {
        var out: [String: String] = [:]
        var cursor = ""
        repeat {
            var form = ["types": "public_channel", "limit": "200", "exclude_archived": "true"]
            if !cursor.isEmpty { form["cursor"] = cursor }
            guard let json = await slackForm(method: "conversations.list", form: form),
                  json["ok"] as? Bool == true,
                  let channels = json["channels"] as? [[String: Any]] else {
                break
            }
            for ch in channels {
                if let name = ch["name"] as? String, let id = ch["id"] as? String {
                    out[name] = id
                }
            }
            cursor = (json["response_metadata"] as? [String: Any])?["next_cursor"] as? String ?? ""
        } while !cursor.isEmpty
        SlackFileLog.log("sync: listed \(out.count) existing channels")
        return out
    }

    /// Create a public channel; returns its id (nil on failure).
    private func createChannel(name: String) async -> String? {
        guard let json = await slackForm(method: "conversations.create", form: ["name": name]),
              json["ok"] as? Bool == true,
              let channel = json["channel"] as? [String: Any],
              let id = channel["id"] as? String else {
            return nil
        }
        return id
    }

    /// Join a channel so the bot is a member (idempotent on Slack's side).
    private func joinChannel(id: String) async {
        _ = await slackForm(method: "conversations.join", form: ["channel": id])
    }

    /// Open (or create) a project's Slack channel and jump to it in the Slack
    /// desktop app via a `slack://channel` deep link. List-first (join if it
    /// exists, else create+join), so it doesn't spam create calls. No-op if the
    /// tokens are missing / not yet connected (no team id).
    func openInSlack(project: VaultProjectService.Project) {
        guard botToken != nil, let teamId else {
            SlackFileLog.log("open in slack: not connected; skipping \(project.name)")
            return
        }
        let slug = Self.slugify(project.name)
        guard !slug.isEmpty else { return }

        Task {
            var channelId = await listChannels()[slug]
            if channelId == nil {
                channelId = await createChannel(name: slug)
                // A create race (already exists) returns nil — re-list.
                if channelId == nil { channelId = await listChannels()[slug] }
            }
            guard let id = channelId else {
                SlackFileLog.log("open in slack: could not ensure #\(slug)")
                return
            }
            await joinChannel(id: id)
            SlackFileLog.log("open in slack: #\(slug) (\(id))")
            if let url = URL(string: "slack://channel?team=\(teamId)&id=\(id)") {
                NSWorkspace.shared.open(url)
            }
        }
    }

    /// Create + join the channel for a slug, looking it up if it already
    /// exists. Returns (name, id) or nil.
    private func ensureChannel(slug: String) async -> (name: String, id: String)? {
        if let id = await createChannel(name: slug) {
            await joinChannel(id: id)
            return (slug, id)
        }
        // name_taken (or similar) — find the existing one and join it.
        if let id = await listChannels()[slug] {
            await joinChannel(id: id)
            return (slug, id)
        }
        return nil
    }

    // MARK: - Slash commands

    /// Handle a `slash_commands` payload (already acked by SocketModeClient).
    /// Does the work async and posts the result back to the command's channel.
    private func handleSlashCommand(data: Data) async {
        guard let payload = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { return }
        let command = payload["command"] as? String ?? ""
        let text = (payload["text"] as? String ?? "").trimmingCharacters(in: .whitespaces)
        let channelId = payload["channel_id"] as? String ?? ""
        let responseUrl = payload["response_url"] as? String
        SlackFileLog.log("slash \(command) channel=\(channelId)")

        switch command {
        case "/claude-sync":
            let summary = await syncChannels()
            await respond(channel: channelId, responseUrl: responseUrl,
                          text: "Synced \(summary.projects) projects, created \(summary.created) channels.")
        case "/claude-project":
            await createProject(text: text, channelId: channelId, responseUrl: responseUrl)
        case "/claude-new":
            await newSession(channelId: channelId, responseUrl: responseUrl)
        case "/claude-skills":
            await reportSkills(channelId: channelId, responseUrl: responseUrl)
        case "/claude-agents":
            await reportAgents(channelId: channelId, responseUrl: responseUrl)
        case "/claude-mode":
            await setMode(arg: text, channelId: channelId, responseUrl: responseUrl)
        case "/claude-effort":
            await setEffort(arg: text, channelId: channelId, responseUrl: responseUrl)
        case "/claude-followup":
            await setFollowup(arg: text, channelId: channelId, responseUrl: responseUrl)
        case "/claude-budget":
            await setBudget(arg: text, channelId: channelId, responseUrl: responseUrl)
        case "/claude-stop":
            // Slash commands carry no thread context; stop the channel's current
            // (most-recent) conversation if it is live.
            if let conv = currentConv(channelId), inFlight.contains(conv.key) {
                await stopTurn(conv: conv)
                await respond(channel: channelId, responseUrl: responseUrl,
                              text: "Stopping the live turn…")
            } else {
                await respond(channel: channelId, responseUrl: responseUrl,
                              text: "No live turn to stop.")
            }
        case "/claude-status":
            await statusCard(channelId: channelId, responseUrl: responseUrl)
        case "/claude-help":
            await helpCard(channelId: channelId, responseUrl: responseUrl)
        case "/claude-log":
            await sessionLog(channelId: channelId, responseUrl: responseUrl)
        case "/claude-resume":
            await resumeSession(arg: text, channelId: channelId, responseUrl: responseUrl)
        // PM verbs (need the manifest's slash entries saved on api.slack.com;
        // the `!tasks` / `!brief` / `!add` bang forms work without that).
        case "/claude-tasks":
            if text.lowercased().hasPrefix("add ") {
                await addTriage(title: String(text.dropFirst(4)), body: nil,
                                channelId: channelId, user: payload["user_id"] as? String ?? "")
            } else {
                await tasksCard(channelId: channelId, responseUrl: responseUrl)
            }
        case "/claude-brief":
            await briefCard(channelId: channelId, responseUrl: responseUrl)
        case "/claude-search":
            // Declared in the manifest since Phase 4 but never implemented —
            // reply honestly instead of the old silent drop.
            await respond(channel: channelId, responseUrl: responseUrl,
                          text: "`/claude-search` isn't implemented yet — use `/claude-log` for recent turns, or the HUD's Sessions search.",
                          ephemeral: true)
        default:
            SlackFileLog.log("slash unknown command \(command)")
        }
    }

    // MARK: - Slash commands: status / help / log / resume (D2/D3, G24, E8)

    /// `/claude-status` (D3) — one ephemeral settings card: the channel's current
    /// `mode`, `effort`, `followup` default, turn budget, bound session id and
    /// cwd, plus any live turn and the 5-hour usage-window headroom (the
    /// subscription engine bills tokens not dollars, so "spend" is the usage
    /// window, never a money figure). Ephemeral so it never clutters the ledger.
    /// The channel's CURRENT conversation (most-recent thread), or nil if none has
    /// run. Channel-scoped slash commands (no thread context) act on this.
    private func currentConv(_ channelId: String) -> Conversation? {
        guard let root = lastConversation[channelId] else { return nil }
        return Conversation(channelId: channelId, threadRootTs: root)
    }

    /// The effective config for a channel-scoped slash command: the current
    /// conversation's session if one exists, else the channel defaults.
    private func effectiveConfig(_ channelId: String) -> ChannelSession {
        if let conv = currentConv(channelId), let s = channelSessions[conv.key] { return s }
        return channelDefaults[channelId] ?? ChannelSession(sessionId: nil, permissionMode: "default", cwd: nil)
    }

    /// Apply a config mutation to BOTH the channel defaults (so new conversations
    /// inherit it) and the current conversation's session (so it takes effect now).
    private func applyConfig(_ channelId: String, _ mutate: (inout ChannelSession) -> Void) {
        var d = channelDefaults[channelId] ?? ChannelSession(sessionId: nil, permissionMode: "default", cwd: nil)
        mutate(&d)
        channelDefaults[channelId] = d
        saveChannelDefaults()
        if let conv = currentConv(channelId) {
            var s = channelSessions[conv.key] ?? ChannelSession(sessionId: nil, permissionMode: "default", cwd: nil)
            mutate(&s)
            channelSessions[conv.key] = s
            saveChannelSessions()
        }
    }

    private func statusCard(channelId: String, responseUrl: String?) async {
        let cfg = effectiveConfig(channelId)
        let curConv = currentConv(channelId)
        let mode = cfg.permissionMode
        let effort = curConv.map { effortLevel($0.key) } ?? {
            let e = cfg.effort ?? Self.defaultEffort
            return ClaudeCLIClient.effortLevels.contains(e) ? e : Self.defaultEffort
        }()
        let followup = cfg.followup ?? Self.defaultFollowup
        let turns = cfg.maxTurns ?? Self.defaultMaxTurns
        let resolved = await resolvedContext(channelId: channelId)
        let sid = cfg.sessionId
        let cwd = cfg.cwd ?? resolved?.cwd

        var lines: [String] = []
        lines.append("*Config*")
        lines.append("• Mode: *\(mode)* — \(Self.modeLabel(mode))")
        lines.append("• Effort: *\(effort)* — \(Self.effortLabel(effort))")
        lines.append("• Follow-up: *\(followup)*")
        lines.append("• Turn budget: *\(turns)* turns / run")
        if let resolved {
            lines.append("• Project: *\(resolved.name)*")
        }
        lines.append("• Working dir: \(cwd.map { "`\($0)`" } ?? "_not bound — run `/claude-project`_")")
        lines.append("• Session: \(sid.map { "`\($0)`" } ?? "_fresh (next message starts a new one)_")")

        // Live turn (the current conversation's). Note: other threads in this
        // channel may be running in parallel; this shows the most-recent one.
        lines.append("")
        let liveKey = curConv?.key
        if let liveKey, let t = inFlightTurns[liveKey], inFlight.contains(liveKey) {
            let age = Int(Date().timeIntervalSince(t.startedAt))
            let stateWord = t.parked ? "Needs you (parked)" : (t.stopping ? "Stopping…" : "Working")
            lines.append("*Live turn:* \(stateWord) · \(Self.ago(age)) · \(t.toolCount) tools")
            lines.append("> \(SlackBlocks.truncate(Self.singleLine(t.request), 180))")
        } else if let liveKey, inFlight.contains(liveKey) {
            lines.append("*Live turn:* running")
        } else {
            lines.append("*Live turn:* none in this thread")
        }

        // Usage-window headroom (no dollars: subscription bills tokens).
        lines.append("")
        if let w = usageService.usage?.fiveHour {
            let headroom = max(0, 100 - Int(w.utilization.rounded()))
            let reset = Self.resetsHint(w.resetsAt)
            let resetTxt = reset.isEmpty ? "" : " · resets \(reset)"
            lines.append("*Usage window (5h):* \(headroom)% headroom (at \(Int(w.utilization.rounded()))%)\(resetTxt)")
        } else {
            lines.append("*Usage window (5h):* unavailable")
        }

        let blocks: [[String: Any]] = [
            SlackBlocks.section(":gear: *Channel status*"),
            SlackBlocks.section(lines.joined(separator: "\n"))
        ]
        SlackFileLog.log("claude-status: \(channelId) mode=\(mode) effort=\(effort)")
        await respond(channel: channelId, responseUrl: responseUrl,
                      text: "Channel status", ephemeral: true, blocks: blocks)
    }

    /// `/claude-help` (D2) — reprint the interaction grammar + the full slash
    /// command list. Ephemeral so it is a private reference, not channel noise.
    private func helpCard(channelId: String, responseUrl: String?) async {
        let grammar = """
        *How this channel works*
        Each THREAD = one project session. A top-level message starts a NEW thread (a fresh session); a reply in a thread continues that thread's session. Different threads run in PARALLEL.
        • *Thread root* = the task + its status line (Working → Done/Failed/Stopped/Needs-you).
        • *Thread under it* = the live work: activity trail, thinking, plan, questions, approvals.
        • *Buttons* = control (Stop, Approve/Deny, Answer, Resume, Show diff, Undo). Never typed from memory.

        *Mid-turn messages*
        Reply in a thread while its turn is running → AUTO-QUEUED (an :hourglass: ack) and run after the current turn finishes, like the terminal CLI's typed-ahead queue. To interrupt instead, use the Stop button or `/claude-stop`.

        *Thread-reply precedence*
        1. A question is pending → your next reply is its answer.
        2. Otherwise → a follow-up, auto-queued if the thread is busy.
        """
        let commands = """
        *Slash commands* (act on this channel's most-recent thread)
        • `/claude-new` — start a fresh session for the current thread
        • `/claude-mode <plan|default|skip>` — permission tier
        • `/claude-effort <low|medium|high|xhigh|max>` — reasoning dial
        • `/claude-budget <turns>` — per-turn turn cap (no dollars; tokens bill the subscription)
        • `/claude-stop` — kill the live turn (same as the Stop button)
        • `/claude-status` — config + live turn + usage-window headroom
        • `/claude-resume [sid]` — re-attach the most recent (or given) session
        • `/claude-log` — recent session activity from the transcript
        • `/claude-help` — this message
        • `/claude-skills` · `/claude-agents` — what this session loaded
        • `/claude-project <dir> [name]` — bind a project · `/claude-sync` — reconcile channels

        *Project management* (host-side vault reads/writes — no engine turn, no tokens)
        • `!tasks [project]` (or `/claude-tasks`) — interactive task card: ✓ Done moves the task to ## Completed with today's date; ➕ Add captures to ## Triage
        • `!brief [project]` (or `/claude-brief`) — the project's briefing (Now / Next / Recently done)
        • `!add <task>` — capture a task to this project's ## Triage
        • `!digest` — post the cross-project morning digest now
        • 📥/📌 reaction on any message — capture it to ## Triage

        *DM the app* for a generic session (no project): plain messages run in a scratch workspace; PM verbs there take the project by name (`!tasks claudehud`, `!add claudehud: fix the header`).
        """
        let blocks: [[String: Any]] = [
            SlackBlocks.section(grammar),
            SlackBlocks.divider(),
            SlackBlocks.section(commands)
        ]
        SlackFileLog.log("claude-help: \(channelId)")
        await respond(channel: channelId, responseUrl: responseUrl,
                      text: "ClaudeHUD help", ephemeral: true, blocks: blocks)
    }

    /// `/claude-log` (G24) — summarize this channel's recent session activity from
    /// the `~/.claude/projects` JSONL transcript. Reads the channel's bound
    /// session id (else the most recent session under the cwd's store) and renders
    /// the last several user/assistant turns. Ephemeral.
    private func sessionLog(channelId: String, responseUrl: String?) async {
        guard let resolved = await resolvedContext(channelId: channelId) else {
            await respond(channel: channelId, responseUrl: responseUrl,
                          text: "This channel isn't bound to a project yet. Run `/claude-project <absolute-dir> [name]`.",
                          ephemeral: true)
            return
        }
        let storeDir = Self.projectStoreDir(forCwd: resolved.cwd)
        let sid = effectiveConfig(channelId).sessionId
        let filePath: String?
        if let sid {
            let p = "\(storeDir)/\(sid).jsonl"
            filePath = FileManager.default.fileExists(atPath: p) ? p : Self.mostRecentSessionFile(in: storeDir)
        } else {
            filePath = Self.mostRecentSessionFile(in: storeDir)
        }
        guard let filePath else {
            await respond(channel: channelId, responseUrl: responseUrl,
                          text: "No session transcript yet for *\(resolved.name)*. Post a message to start one.",
                          ephemeral: true)
            return
        }
        let entries = Self.recentTranscript(filePath: filePath, limit: 10)
        guard !entries.isEmpty else {
            await respond(channel: channelId, responseUrl: responseUrl,
                          text: "The transcript for this session has no readable turns yet.",
                          ephemeral: true)
            return
        }
        let body = entries.map { entry -> String in
            let icon = entry.role == "user" ? ":bust_in_silhouette:" : ":robot_face:"
            return "\(icon) \(SlackBlocks.truncate(Self.singleLine(entry.text), 240))"
        }.joined(separator: "\n")
        let fileName = (filePath as NSString).lastPathComponent
        let sidShort = (fileName as NSString).deletingPathExtension
        let blocks: [[String: Any]] = [
            SlackBlocks.section(":scroll: *Recent session activity* — *\(resolved.name)*"),
            SlackBlocks.section(body),
            SlackBlocks.context("session `\(sidShort)` · last \(entries.count) turns")
        ]
        SlackFileLog.log("claude-log: \(channelId) session=\(sidShort) turns=\(entries.count)")
        await respond(channel: channelId, responseUrl: responseUrl,
                      text: "Recent session activity", ephemeral: true, blocks: blocks)
    }

    /// `/claude-resume [sid]` — re-attach the channel to the most recent session
    /// (or the given session id), so the next message continues it via `--resume`
    /// rather than starting fresh. With a sid argument the id is validated against
    /// the cwd's `~/.claude/projects` store before binding (E8: resume only works
    /// inside the cwd that created the session).
    private func resumeSession(arg: String, channelId: String, responseUrl: String?) async {
        guard let conv = currentConv(channelId) else {
            await respond(channel: channelId, responseUrl: responseUrl,
                          text: "No thread to resume in this channel yet. Post a message to start one, then `/claude-resume`.",
                          ephemeral: true)
            return
        }
        guard !inFlight.contains(conv.key) else {
            await respond(channel: channelId, responseUrl: responseUrl,
                          text: "A turn is already running in this thread — `/claude-stop` it first, then resume.",
                          ephemeral: true)
            return
        }
        guard let resolved = await resolvedContext(channelId: channelId) else {
            await respond(channel: channelId, responseUrl: responseUrl,
                          text: "This channel isn't bound to a project yet. Run `/claude-project <absolute-dir> [name]`.",
                          ephemeral: true)
            return
        }
        let storeDir = Self.projectStoreDir(forCwd: resolved.cwd)
        let wanted = arg.trimmingCharacters(in: .whitespaces)

        let targetSid: String?
        if !wanted.isEmpty {
            let p = "\(storeDir)/\(wanted).jsonl"
            guard FileManager.default.fileExists(atPath: p) else {
                await respond(channel: channelId, responseUrl: responseUrl,
                              text: "No session `\(wanted)` found under `\(resolved.cwd)`. A session id only resumes in the cwd that created it.",
                              ephemeral: true)
                return
            }
            targetSid = wanted
        } else if let recent = Self.mostRecentSessionFile(in: storeDir) {
            targetSid = ((recent as NSString).lastPathComponent as NSString).deletingPathExtension
        } else {
            targetSid = nil
        }

        guard let sid = targetSid else {
            await respond(channel: channelId, responseUrl: responseUrl,
                          text: "No prior session to resume for *\(resolved.name)*. Post a message to start a fresh one.",
                          ephemeral: true)
            return
        }

        var state = channelSessions[conv.key] ?? ChannelSession(sessionId: nil, permissionMode: "default", cwd: nil)
        state.sessionId = sid
        state.cwd = resolved.cwd
        channelSessions[conv.key] = state
        saveChannelSessions()
        SlackFileLog.log("claude-resume: \(conv.key) -> \(sid) (cwd=\(resolved.cwd))")
        await respond(channel: channelId, responseUrl: responseUrl,
                      text: "Re-attached to session `\(sid)` in *\(resolved.name)*. Your next message continues it.",
                      ephemeral: false)
    }

    // MARK: - Slash command helpers (status/log/resume support)

    /// Best-effort resolve of a channel's project context: prefer the live/last
    /// turn, then the persisted session cwd, then a fresh project lookup by
    /// channel name. Returns nil only when the channel maps to no project.
    private func resolvedContext(channelId: String) async -> (name: String, cwd: String, obsidianPath: String)? {
        if let conv = currentConv(channelId), let lt = lastTurns[conv.key] {
            return (lt.projectName, lt.cwd, lt.obsidianPath)
        }
        if let name = await channelName(for: channelId),
           let r = resolveProject(forChannelName: name) {
            return r
        }
        return nil
    }

    /// The `~/.claude/projects` store directory for a cwd. Claude Code encodes a
    /// project path by replacing `/`, `_`, and `.` with `-` (see
    /// SessionHistoryService.decodeProjectDir for the inverse).
    private static func projectStoreDir(forCwd cwd: String) -> String {
        let encoded = cwd
            .replacingOccurrences(of: "/", with: "-")
            .replacingOccurrences(of: "_", with: "-")
            .replacingOccurrences(of: ".", with: "-")
        return "\(NSHomeDirectory())/.claude/projects/\(encoded)"
    }

    /// Most recently modified `.jsonl` session file under a store dir, or nil.
    private static func mostRecentSessionFile(in storeDir: String) -> String? {
        let fm = FileManager.default
        guard let files = try? fm.contentsOfDirectory(atPath: storeDir) else { return nil }
        let jsonls = files.filter { $0.hasSuffix(".jsonl") }
        var best: (path: String, date: Date)?
        for f in jsonls {
            let p = "\(storeDir)/\(f)"
            guard let attrs = try? fm.attributesOfItem(atPath: p),
                  let mod = attrs[.modificationDate] as? Date else { continue }
            if best == nil || mod > best!.date { best = (p, mod) }
        }
        return best?.path
    }

    /// A transcript turn surfaced by `/claude-log`.
    private struct TranscriptEntry { let role: String; let text: String }

    /// Parse the tail of a session JSONL into the last `limit` user/assistant
    /// turns (most-recent last). Lightweight, secret-agnostic display of the
    /// operator's own session — never the raw tool I/O.
    private static func recentTranscript(filePath: String, limit: Int) -> [TranscriptEntry] {
        guard let raw = try? String(contentsOfFile: filePath, encoding: .utf8) else { return [] }
        var entries: [TranscriptEntry] = []
        for line in raw.split(separator: "\n") {
            guard let data = line.data(using: .utf8),
                  let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { continue }
            guard let (role, text) = transcriptLine(from: json), !text.isEmpty else { continue }
            entries.append(TranscriptEntry(role: role, text: text))
        }
        return Array(entries.suffix(limit))
    }

    /// Pull a (role, text) pair out of one JSONL record across the schema
    /// variants Claude Code has emitted. Returns nil for non-message records.
    private static func transcriptLine(from json: [String: Any]) -> (String, String)? {
        // {"type":"user"/"assistant","message":{"role":...,"content":...}}
        if let msg = json["message"] as? [String: Any],
           let role = msg["role"] as? String, role == "user" || role == "assistant" {
            return (role, flattenContent(msg["content"]))
        }
        // {"role":"user"/"assistant","content":...}
        if let role = json["role"] as? String, role == "user" || role == "assistant" {
            return (role, flattenContent(json["content"]))
        }
        return nil
    }

    /// Flatten a message `content` (string or array of blocks) into display text,
    /// skipping tool_use / tool_result blocks (those are the thread trail's job).
    private static func flattenContent(_ content: Any?) -> String {
        if let s = content as? String { return s }
        guard let blocks = content as? [[String: Any]] else { return "" }
        var parts: [String] = []
        for b in blocks {
            let type = b["type"] as? String ?? ""
            if type == "text", let t = b["text"] as? String { parts.append(t) }
            else if type == "thinking" { parts.append("(thinking)") }
            else if type == "tool_use", let name = b["name"] as? String { parts.append("→ \(name)") }
        }
        return parts.joined(separator: " ")
    }

    /// Outcome-labelled name for a permission mode (mirrors `effortLabel`).
    private static func modeLabel(_ mode: String) -> String {
        switch mode {
        case "plan":             return "read-only (no Edit/Write/Bash)"
        case "default":          return "Edit/Write allowed, Bash gated"
        case "dangerously-skip": return "everything allowed (incl. Bash)"
        default:                 return mode
        }
    }

    /// Compact "Ns/Nm ago"-style age string for a seconds count.
    private static func ago(_ secs: Int) -> String {
        if secs < 60 { return "\(secs)s" }
        let m = secs / 60, s = secs % 60
        return s == 0 ? "\(m)m" : "\(m)m\(s)s"
    }

    /// `/claude-effort <low|medium|high|xhigh|max>` — set + persist the channel's
    /// reasoning-effort dial (2.3), passed to the engine as `--effort` on the next
    /// turn. Labelled by outcome, not jargon.
    private func setEffort(arg: String, channelId: String, responseUrl: String?) async {
        let level = arg.lowercased()
        guard ClaudeCLIClient.effortLevels.contains(level) else {
            let cur = effectiveConfig(channelId).effort ?? Self.defaultEffort
            let current = ClaudeCLIClient.effortLevels.contains(cur) ? cur : Self.defaultEffort
            await respond(channel: channelId, responseUrl: responseUrl,
                          text: "Usage: `/claude-effort <low|medium|high|xhigh|max>` — currently *\(current)* (\(Self.effortLabel(current))).")
            return
        }
        applyConfig(channelId) { $0.effort = level }
        SlackFileLog.log("claude-effort: \(channelId) -> \(level)")
        await respond(channel: channelId, responseUrl: responseUrl,
                      text: "Reasoning effort set to *\(level)* — \(Self.effortLabel(level)). Applies to the current and new threads.")
    }

    /// `/claude-followup` — retained for compatibility. Mid-turn messages now
    /// AUTO-QUEUE per-thread (no Queue/Steer/Cancel prompt), so this is
    /// informational; the stored value has no runtime effect.
    private func setFollowup(arg: String, channelId: String, responseUrl: String?) async {
        await respond(channel: channelId, responseUrl: responseUrl,
                      text: "Mid-turn messages now *auto-queue* per thread (an :hourglass: ack) and run after the current turn finishes — like the terminal CLI. To interrupt instead, use the Stop button or `/claude-stop`.")
    }

    /// `/claude-budget <turns>` — set + persist the channel's per-turn turn-count
    /// guardrail (3.5, REFRAMED to NO dollars: the subscription engine bills no
    /// dollars, so the cap is on agentic TURNS, surfaced alongside live token
    /// usage). On hitting it, the engine stops with `error_max_turns` and the
    /// operator gets a Continue/Stop card rather than a silent failure.
    private func setBudget(arg: String, channelId: String, responseUrl: String?) async {
        let trimmed = arg.trimmingCharacters(in: .whitespaces)
        guard let turns = Int(trimmed), turns > 0, turns <= 1000 else {
            let current = effectiveConfig(channelId).maxTurns ?? Self.defaultMaxTurns
            await respond(channel: channelId, responseUrl: responseUrl,
                          text: "Usage: `/claude-budget <turns>` (1–1000) — currently *\(current)* turns per run. No dollar cap: the subscription engine bills tokens, not dollars, so this caps agentic turns and the usage-window headroom guard does the rest.")
            return
        }
        applyConfig(channelId) { $0.maxTurns = turns }
        SlackFileLog.log("claude-budget: \(channelId) -> \(turns) turns")
        await respond(channel: channelId, responseUrl: responseUrl,
                      text: "Turn budget set to *\(turns)* turns per run. On hitting it, the turn pauses with a Continue/Stop choice — partial work is always kept.")
    }

    /// `/claude-new` — start a fresh session for the CURRENT thread: clear that
    /// conversation's session id and reset its CLI engine resume state, so the next
    /// message in the thread begins anew. (A top-level message already starts a
    /// fresh session in its own thread, so this is for resetting an active thread.)
    private func newSession(channelId: String, responseUrl: String?) async {
        let name = await channelName(for: channelId) ?? channelId
        guard let conv = currentConv(channelId) else {
            await respond(channel: channelId, responseUrl: responseUrl,
                          text: "No active thread to reset in #\(name) — your next top-level message starts a fresh session.")
            return
        }
        var state = channelSessions[conv.key] ?? ChannelSession(sessionId: nil, permissionMode: "default", cwd: nil)
        state.sessionId = nil
        channelSessions[conv.key] = state
        clients[conv.key]?.newSession()
        saveChannelSessions()
        SlackFileLog.log("claude-new: cleared session for \(conv.key)")
        await respond(channel: channelId, responseUrl: responseUrl,
                      text: "Started a fresh session for the current thread in #\(name).")
    }

    /// `/claude-skills` — reply with the skills the engine reported for this
    /// channel's current session (Phase 0 init event). This is the authoritative
    /// per-session list Claude loads, not a static catalog. If no turn has run in
    /// the channel yet there is nothing to read, so ask the operator to post first.
    private func reportSkills(channelId: String, responseUrl: String?) async {
        guard let key = currentConv(channelId)?.key, let skills = channelSkills[key] else {
            await respond(channel: channelId, responseUrl: responseUrl,
                          text: "Post a message first so I can read this session's skills.")
            return
        }
        if skills.isEmpty {
            await respond(channel: channelId, responseUrl: responseUrl,
                          text: "This session reports no skills.")
            return
        }
        let list = skills.sorted().map { "• `\($0)`" }.joined(separator: "\n")
        SlackFileLog.log("claude-skills: \(channelId) -> \(skills.count) skills")
        await respond(channel: channelId, responseUrl: responseUrl,
                      text: "*Skills this session can use* (\(skills.count)):\n\(list)")
    }

    /// `/claude-agents` — reply with the agents/subagents the engine reported for
    /// this channel's current session (Phase 0 init event). Authoritative
    /// per-session list. Same empty/no-session handling as `/claude-skills`.
    private func reportAgents(channelId: String, responseUrl: String?) async {
        guard let key = currentConv(channelId)?.key, let agents = channelAgents[key] else {
            await respond(channel: channelId, responseUrl: responseUrl,
                          text: "Post a message first so I can read this session's agents.")
            return
        }
        if agents.isEmpty {
            await respond(channel: channelId, responseUrl: responseUrl,
                          text: "This session reports no agents (subagents are spawned on demand via the Task tool).")
            return
        }
        let list = agents.sorted().map { "• `\($0)`" }.joined(separator: "\n")
        SlackFileLog.log("claude-agents: \(channelId) -> \(agents.count) agents")
        await respond(channel: channelId, responseUrl: responseUrl,
                      text: "*Agents available to this session* (\(agents.count)):\n\(list)")
    }

    /// `/claude-mode <plan|default|skip>` — set + persist the channel's
    /// permission mode. plan = read-only; default = Edit/Write but no Bash;
    /// skip = everything including Bash (warned).
    private func setMode(arg: String, channelId: String, responseUrl: String?) async {
        let mapped: String?
        switch arg.lowercased() {
        case "plan": mapped = "plan"
        case "default": mapped = "default"
        case "skip", "dangerously-skip": mapped = "dangerously-skip"
        default: mapped = nil
        }
        guard let mode = mapped else {
            await respond(channel: channelId, responseUrl: responseUrl,
                          text: "Usage: `/claude-mode <plan|default|skip>`")
            return
        }
        applyConfig(channelId) { $0.permissionMode = mode }
        SlackFileLog.log("claude-mode: \(channelId) -> \(mode)")

        let reply: String
        switch mode {
        case "plan":
            reply = "Permission mode set to *plan* — read-only; a plan card must be approved before anything executes."
        case "default":
            reply = supervisedMode
                ? "Permission mode set to *default* — reads and in-project edits run; Bash, network, and risky writes park an approval card."
                : "Permission mode set to *default* — Edit/Write allowed, Bash blocked."
        default:
            reply = supervisedMode
                ? ":warning: Permission mode set to *skip* — under supervision, gated tools (Bash, network) still park approval cards; the hard-deny floor stays."
                : ":warning: Permission mode set to *skip* — everything allowed, *including Bash*. Use with care."
        }
        await respond(channel: channelId, responseUrl: responseUrl, text: reply)
    }

    /// `/claude-project <absolute-dir> [name]` — create a vault project folder
    /// (Tasks.md per schema.md) for an existing absolute directory, then create
    /// + join its Slack channel. Non-destructive: refuses to overwrite an
    /// existing folder.
    private func createProject(text: String, channelId: String, responseUrl: String?) async {
        let parts = text.split(separator: " ", maxSplits: 1, omittingEmptySubsequences: true)
        guard let first = parts.first else {
            await respond(channel: channelId, responseUrl: responseUrl,
                          text: "Usage: `/claude-project <absolute-dir> [name]`")
            return
        }
        let dir = String(first)
        let nameArg = parts.count > 1 ? String(parts[1]).trimmingCharacters(in: .whitespaces) : ""

        guard dir.hasPrefix("/") else {
            SlackFileLog.log("claude-project: not absolute: \(dir)")
            await respond(channel: channelId, responseUrl: responseUrl,
                          text: "Directory must be an absolute path. Got: `\(dir)`")
            return
        }
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: dir, isDirectory: &isDir), isDir.boolValue else {
            SlackFileLog.log("claude-project: dir not found: \(dir)")
            await respond(channel: channelId, responseUrl: responseUrl,
                          text: "Directory does not exist: `\(dir)`")
            return
        }

        let name = nameArg.isEmpty ? URL(fileURLWithPath: dir).lastPathComponent : nameArg
        guard let vaultRoot = vaultProjects.vaultPath else {
            SlackFileLog.log("claude-project: vault root unavailable")
            await respond(channel: channelId, responseUrl: responseUrl,
                          text: "Vault root unavailable; cannot create project.")
            return
        }

        let folder = vaultRoot.appendingPathComponent(name, isDirectory: true)
        if FileManager.default.fileExists(atPath: folder.path) {
            SlackFileLog.log("claude-project: folder exists: \(name)")
            await respond(channel: channelId, responseUrl: responseUrl,
                          text: "Project *\(name)* already exists. Nothing created.")
            return
        }

        do {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            let tasks = Self.tasksMarkdown(projectName: name, cwd: dir)
            try tasks.write(to: folder.appendingPathComponent("Tasks.md"), atomically: true, encoding: .utf8)
            SlackFileLog.log("claude-project: created folder \(name) Tasks.md cwds=[\(dir), \(dir)/**]")
        } catch {
            SlackFileLog.log("claude-project: create failed \(error.localizedDescription)")
            await respond(channel: channelId, responseUrl: responseUrl,
                          text: "Failed to create project *\(name)*: \(error.localizedDescription)")
            return
        }

        // Re-scan so the inbound resolver sees the new project immediately.
        vaultProjects.refresh()

        let slug = Self.slugify(name)
        let channelInfo = await ensureChannel(slug: slug)
        let channelMsg = channelInfo.map { "#\($0.name)" } ?? "#\(slug) (channel creation failed)"
        await respond(channel: channelId, responseUrl: responseUrl,
                      text: "Created project *\(name)* → \(channelMsg) → cwd `\(dir)`.")
    }

    /// Reply to a slash command — prefer the `response_url` (works without
    /// channel membership), else `chat.postMessage` to the channel.
    private func respond(channel: String, responseUrl: String?, text: String,
                         ephemeral: Bool = false, blocks: [[String: Any]]? = nil) async {
        if let responseUrl, let url = URL(string: responseUrl) {
            var req = URLRequest(url: url)
            req.httpMethod = "POST"
            req.setValue("application/json; charset=utf-8", forHTTPHeaderField: "Content-Type")
            var body: [String: Any] = [
                "response_type": ephemeral ? "ephemeral" : "in_channel", "text": text
            ]
            if let blocks { body["blocks"] = blocks }
            req.httpBody = try? JSONSerialization.data(withJSONObject: body)
            do {
                _ = try await session.data(for: req)
                SlackFileLog.log("slash response posted via response_url")
            } catch {
                SlackFileLog.log("slash response_url failed: \(error.localizedDescription)")
                if !channel.isEmpty { await postMessage(channel: channel, text: text, blocks: blocks) }
            }
        } else if !channel.isEmpty {
            await postMessage(channel: channel, text: text, blocks: blocks)
        }
    }

    // MARK: - PM verbs (Slack as project-management hub)
    //
    // Host-side vault reads/writes keyed off the channel's bound project — no
    // engine turn, no tokens. Writes are limited to the two sanctioned
    // machine paths (schema.md): the Active→Completed move
    // (`VaultManager.completeActiveTask`) and the `## Triage` append
    // (`VaultManager.appendTriageItem`). Everything else is a read.

    /// PM verbs typed as `!command` in a bound channel. The bang prefix is
    /// unambiguous (a real prompt never starts with `!`), so these work in
    /// every channel today; the slash twins need a one-time manifest save.
    private func handleBangCommand(text: String, channelId: String, user: String,
                                   threadTs: String?, isDM: Bool = false) async {
        let trimmed = text.trimmingCharacters(in: .whitespaces)
        let parts = trimmed.dropFirst().split(separator: " ", maxSplits: 1)
        let verb = parts.first.map { String($0).lowercased() } ?? ""
        let arg = parts.count > 1 ? String(parts[1]).trimmingCharacters(in: .whitespaces) : ""
        SlackFileLog.log("bang !\(verb) channel=\(channelId) dm=\(isDM ? "Y" : "N")")
        // In a channel the project defaults to the channel's binding; an
        // argument overrides it. In a DM there is no binding — tasks/brief
        // REQUIRE the argument, and !add takes a "<project>: <task>" prefix.
        let projectArg = arg.isEmpty ? nil : arg
        switch verb {
        case "tasks", "task":
            if arg.lowercased().hasPrefix("add ") {
                await addTriage(title: String(arg.dropFirst(4)), body: nil,
                                channelId: channelId, user: user, projectArg: nil)
            } else if isDM, projectArg == nil {
                await postMessage(channel: channelId,
                                  text: "In a DM, name the project: `!tasks <project>` (e.g. `!tasks claudehud`).",
                                  threadTs: threadTs)
            } else {
                await tasksCard(channelId: channelId, responseUrl: nil, threadTs: threadTs,
                                projectArg: projectArg)
            }
        case "brief", "briefing":
            if isDM, projectArg == nil {
                await postMessage(channel: channelId,
                                  text: "In a DM, name the project: `!brief <project>`.",
                                  threadTs: threadTs)
            } else {
                await briefCard(channelId: channelId, responseUrl: nil, threadTs: threadTs,
                                projectArg: projectArg)
            }
        case "add", "todo":
            if isDM {
                guard let colon = arg.firstIndex(of: ":"), colon != arg.startIndex else {
                    await postMessage(channel: channelId,
                                      text: "In a DM: `!add <project>: <task>` (e.g. `!add claudehud: fix the header`).",
                                      threadTs: threadTs)
                    return
                }
                let proj = String(arg[arg.startIndex..<colon]).trimmingCharacters(in: .whitespaces)
                let task = String(arg[arg.index(after: colon)...]).trimmingCharacters(in: .whitespaces)
                await addTriage(title: task, body: nil, channelId: channelId, user: user,
                                projectArg: proj)
            } else {
                await addTriage(title: arg, body: nil, channelId: channelId, user: user,
                                projectArg: nil)
            }
        case "digest":
            await postMorningDigest(force: true)
        case "help":
            await postEphemeral(channel: channelId, user: user, text: Self.bangHelp)
        default:
            await postEphemeral(channel: channelId, user: user,
                                text: "Unknown command `!\(verb)`. " + Self.bangHelp)
        }
    }

    /// Project context for a PM verb: an explicit project argument (fuzzy-
    /// matched like a channel name) wins; else the channel's binding.
    private func resolvedPMContext(channelId: String, projectArg: String?) async
        -> (name: String, cwd: String, obsidianPath: String)? {
        if let arg = projectArg, !arg.isEmpty, let r = resolveProject(forChannelName: arg) {
            return r
        }
        return await resolvedContext(channelId: channelId)
    }

    private static let bangHelp = "PM verbs: `!tasks [project]` task card · `!brief [project]` briefing · `!add <task>` capture to ## Triage (DM form: `!add <project>: <task>`) · `!digest` morning digest now · `!help`. Start a message without `!` to talk to Claude — in a project channel that drives the project's session; in this DM it's a generic session."

    // MARK: - DM: the generic (no-project) surface

    /// A DM with the bot is the GENERIC Claude surface: no project binding.
    /// Bang verbs work with an explicit project argument (`!tasks estonia-qbs`);
    /// anything else runs a real turn in the scratch workspace. Scratch
    /// transcripts are ingest-eligible but claimed by no project, so their
    /// digests land in Misc/Session Inbox — the vault's designed catch-all.
    private func handleDirectMessage(channelId: String, text: String, user: String,
                                     inboundThreadTs: String?, messageTs: String) async {
        SlackFileLog.log("rx DM (\(channelId))")
        if !user.isEmpty { operatorUserId[channelId] = user }
        if text.trimmingCharacters(in: .whitespaces).hasPrefix("!") {
            await handleBangCommand(text: text, channelId: channelId, user: user,
                                    threadTs: inboundThreadTs, isDM: true)
            return
        }
        let resolved = (name: "DM", cwd: Self.dmScratchCwd(),
                        obsidianPath: vaultProjects.vaultPath
                            .map { $0.appendingPathComponent("Misc").path } ?? Self.dmScratchCwd())
        // Same threading rules as channels: a reply continues its thread's
        // session; a top-level message starts a fresh thread.
        if let threadRoot = inboundThreadTs {
            let conv = Conversation(channelId: channelId, threadRootTs: threadRoot)
            if captureThreadReplyAnswer(conv: conv, text: text) { return }
            let busy = inFlight.contains(conv.key)
                || !(followupQueue[conv.key]?.isEmpty ?? true)
            if busy {
                await autoQueueFollowup(conv: conv, text: text, resolved: resolved)
                return
            }
            inFlight.insert(conv.key)
            await runTurn(conv: conv, channelId: channelId, projectName: resolved.name,
                          cwd: resolved.cwd, obsidianPath: resolved.obsidianPath, text: text,
                          lockAlreadyHeld: true)
            return
        }
        let conv = messageTs.isEmpty ? nil : Conversation(channelId: channelId, threadRootTs: messageTs)
        await runTurn(conv: conv, channelId: channelId, projectName: resolved.name,
                      cwd: resolved.cwd, obsidianPath: resolved.obsidianPath, text: text)
    }

    /// Scratch workspace for DM (generic) sessions — a real directory under
    /// ~/Projects, so transcripts stay ingest-eligible (home-dotfile cwds are
    /// excluded by the ingest's cwd gate).
    private static func dmScratchCwd() -> String {
        let path = NSHomeDirectory() + "/Projects/scratch"
        try? FileManager.default.createDirectory(atPath: path, withIntermediateDirectories: true)
        return path
    }

    /// `/claude-tasks` + `!tasks` — the channel project's `Tasks.md ## Active`
    /// as an interactive card: one row per actionable task with a ✓ Done
    /// button (the sanctioned Active→Completed move: date-stamped, `updated:`
    /// bumped, provenance `via Slack`), ➕ Add opening a Triage-capture modal,
    /// and 🔄 Refresh. Posted as a regular message so taps `chat.update` it
    /// in place (an ephemeral has no stable ts to update).
    private func tasksCard(channelId: String, responseUrl: String?,
                           threadTs: String? = nil, updateTs: String? = nil,
                           projectArg: String? = nil) async {
        guard let resolved = await resolvedPMContext(channelId: channelId, projectArg: projectArg) else {
            await respond(channel: channelId, responseUrl: responseUrl,
                          text: "No project matched. In a channel, bind one with `/claude-project <absolute-dir> [name]`; in a DM, name it: `!tasks <project>`.",
                          ephemeral: true)
            return
        }
        let taskFile = (resolved.obsidianPath as NSString).appendingPathComponent("Tasks.md")
        guard let content = try? String(contentsOfFile: taskFile, encoding: .utf8) else {
            await respond(channel: channelId, responseUrl: responseUrl,
                          text: "*\(resolved.name)* has no readable Tasks.md at `\(taskFile)`.",
                          ephemeral: true)
            return
        }
        let blocks = Self.taskCardBlocks(projectName: resolved.name,
                                         taskFile: taskFile, content: content)
        if let updateTs {
            await chatUpdate(channel: channelId, ts: updateTs,
                             text: "Tasks — \(resolved.name)", blocks: blocks)
            SlackFileLog.log("tasks card updated ts=\(updateTs) project=\(resolved.name)")
        } else {
            let ts = await postMessage(channel: channelId, text: "Tasks — \(resolved.name)",
                                       threadTs: threadTs, blocks: blocks)
            SlackFileLog.log("tasks card posted ts=\(ts ?? "nil") project=\(resolved.name)")
        }
    }

    /// Build the interactive task-card blocks from a Tasks.md body. A row is
    /// rendered for every actionable (not-done) task the ✓ button can target:
    /// flat top-level tasks, and the children of `###` heading groups (each a
    /// top-level `- [ ]` bullet in the source). Rows cap at 10 — Slack's
    /// 50-block ceiling and phone ergonomics; the rest folds into a count.
    static func taskCardBlocks(projectName: String, taskFile: String,
                               content: String) -> [[String: Any]] {
        let tasks = VaultProjectService.parseActiveTasks(from: content)
        var blocks: [[String: Any]] = [
            SlackBlocks.section(":ballot_box_with_check: *Tasks — \(projectName)*")
        ]
        let rowCap = 10
        var rendered = 0
        var skipped = 0

        // The vault folder rides in every button value so taps resolve from
        // DM-posted cards too (and survive channel renames).
        let folder = ((taskFile as NSString).deletingLastPathComponent as NSString).lastPathComponent

        func doneButton(title: String, line: Int) -> [String: Any] {
            // Printable separators: Slack strips control chars from button
            // values (a \u{0001} separator arrives fused). Line is digits-only
            // and folder names carry no pipes, so the first two `|` are
            // structural; pipes inside the title are harmless.
            SlackBlocks.button(text: "✓ Done", actionId: SlackAction.taskDone,
                               value: "\(line)|\(folder)|\(String(title.prefix(280)))")
        }
        func addRow(title: String, detail: String, line: Int) {
            let label = detail.isEmpty
                ? "☐ *\(SlackBlocks.truncate(title, 200))*"
                : "☐ *\(SlackBlocks.truncate(title, 200))*  \(SlackBlocks.truncate(detail, 160))"
            blocks.append(SlackBlocks.sectionWithButton(label,
                                                        button: doneButton(title: title, line: line)))
            rendered += 1
        }

        for task in tasks where !task.isDone {
            if task.isHeading {
                let open = task.subBullets.filter { !$0.isDone && $0.line >= 0 }
                guard !open.isEmpty else { continue }
                if rendered >= rowCap { skipped += open.count; continue }
                blocks.append(SlackBlocks.context("*\(SlackBlocks.truncate(task.title, 140))*"))
                for child in open {
                    if rendered >= rowCap { skipped += 1; continue }
                    let split = VaultProjectService.splitBullet(child.text)
                    addRow(title: split.title, detail: split.body, line: child.line)
                }
            } else if let line = task.line {
                if rendered >= rowCap { skipped += 1; continue }
                addRow(title: task.title, detail: "", line: line)
            }
        }

        if rendered == 0 {
            blocks.append(SlackBlocks.section("_No open tasks in ## Active._"))
        }
        if skipped > 0 {
            blocks.append(SlackBlocks.context("+\(skipped) more in Tasks.md"))
        }
        blocks.append(SlackBlocks.actions([
            SlackBlocks.button(text: "➕ Add task", actionId: SlackAction.taskAdd, value: folder),
            SlackBlocks.button(text: "🔄 Refresh", actionId: SlackAction.taskRefresh, value: folder)
        ]))
        let triage = VaultManager.triageCount(taskFile: taskFile)
        blocks.append(SlackBlocks.context(
            "\(rendered + skipped) open · \(triage) in triage · ✓ moves to ## Completed with today's date"))
        return blocks
    }

    /// ✓ Done tap: the sanctioned Active→Completed move, then re-render the
    /// card in place and confirm in its thread. `value` = "<line>␁<title>"
    /// from render time; the primitive verifies the line still matches before
    /// writing (a stale card falls back to title search, then refuses).
    private func onTaskDone(channelId: String, messageTs: String?, value: String,
                            user: String) async {
        // Value = "<line>|<project-folder>|<title>" (current cards); the
        // folder resolves taps from DM-posted cards and survives channel
        // renames. A legacy "<line>|<title>" value (or a folder that no
        // longer exists) falls back to the channel's binding.
        let parts = value.split(separator: "|", maxSplits: 2,
                                omittingEmptySubsequences: false).map(String.init)
        let lineHint = parts.first.flatMap(Int.init)
        var resolved: (name: String, cwd: String, obsidianPath: String)?
        var title: String
        var projectArg: String? = nil
        if parts.count == 3,
           let p = vaultProjects.projects.first(where: { $0.folder.lastPathComponent == parts[1] }) {
            resolved = (p.name, p.primaryCwd ?? p.folder.path, p.folder.path)
            title = parts[2]
            projectArg = parts[1]
        } else {
            resolved = await resolvedContext(channelId: channelId)
            title = parts.count > 1 ? parts[1...].joined(separator: "|") : ""
        }
        guard let resolved else {
            SlackFileLog.log("task done: channel \(channelId) unresolved")
            await postEphemeral(channel: channelId, user: user,
                                text: "Couldn't resolve this card's project — tap 🔄 Refresh or use `!tasks <project>`.")
            return
        }
        let taskFile = (resolved.obsidianPath as NSString).appendingPathComponent("Tasks.md")

        let result = VaultManager.completeActiveTask(taskFile: taskFile,
                                                     expectedTitle: title.isEmpty ? nil : title,
                                                     lineHint: lineHint,
                                                     provenance: "via Slack")
        switch result {
        case .moved(let moved):
            SlackFileLog.log("task done: \(moved.prefix(60)) (\(resolved.name))")
            if let messageTs {
                await tasksCard(channelId: channelId, responseUrl: nil, updateTs: messageTs,
                                projectArg: projectArg)
            }
            await postMessage(channel: channelId,
                              text: ":white_check_mark: *\(SlackBlocks.truncate(moved, 140))* → ## Completed",
                              threadTs: messageTs)
        case .notFound:
            await postEphemeral(channel: channelId, user: user,
                                text: "Couldn't find that task in ## Active anymore — Tasks.md changed since this card rendered. Tap 🔄 Refresh.")
            if let messageTs {
                await tasksCard(channelId: channelId, responseUrl: nil, updateTs: messageTs,
                                projectArg: projectArg)
            }
        case .ambiguous(let n):
            await postEphemeral(channel: channelId, user: user,
                                text: "\(n) Active tasks share that title — not guessing. Complete it in Tasks.md directly.")
        case .failed(let why):
            await postEphemeral(channel: channelId, user: user,
                                text: "Couldn't update Tasks.md: \(why)")
        }
    }

    /// ➕ Add task → a small staged modal (title + optional detail) writing to
    /// `## Triage` on submit. Triage, not Active: machine intake is quarantined
    /// until the human promotes it (schema.md §Email ingestion — same contract).
    private func openTaskAddModal(channelId: String, triggerId: String,
                                  projectArg: String? = nil) async {
        guard !triggerId.isEmpty else { return }
        let view: [String: Any] = [
            "type": "modal",
            "callback_id": SlackAction.taskAddModal,
            // "<channel>|<project-folder>" — the folder makes the submit
            // resolvable from DM-opened modals.
            "private_metadata": "\(channelId)|\(projectArg ?? "")",
            "title": ["type": "plain_text", "text": "Add task"],
            "submit": ["type": "plain_text", "text": "Add to Triage"],
            "close": ["type": "plain_text", "text": "Cancel"],
            "blocks": [
                ["type": "input", "block_id": "title",
                 "label": ["type": "plain_text", "text": "Task"],
                 "element": ["type": "plain_text_input", "action_id": "text",
                             "placeholder": ["type": "plain_text",
                                             "text": "Short imperative title"]] as [String: Any]],
                ["type": "input", "block_id": "note", "optional": true,
                 "label": ["type": "plain_text", "text": "Detail (optional)"],
                 "element": ["type": "plain_text_input", "action_id": "text",
                             "multiline": true] as [String: Any]]
            ]
        ]
        await openModal(triggerId: triggerId, view: view)
    }

    /// Append a task to the project's `## Triage` with Slack provenance.
    private func addTriage(title: String, body: String?, channelId: String,
                           user: String, projectArg: String? = nil) async {
        let cleanTitle = title.trimmingCharacters(in: .whitespaces)
        guard !cleanTitle.isEmpty else {
            await postEphemeral(channel: channelId, user: user, text: "Usage: `!add <task>`")
            return
        }
        guard let resolved = await resolvedPMContext(channelId: channelId, projectArg: projectArg) else {
            await postEphemeral(channel: channelId, user: user,
                                text: "No project matched — in a DM use `!add <project>: <task>`.")
            return
        }
        let taskFile = (resolved.obsidianPath as NSString).appendingPathComponent("Tasks.md")
        let fmt = DateFormatter()
        fmt.dateFormat = "yyyy-MM-dd"
        let provenance = "via Slack, \(fmt.string(from: Date()))"
        if VaultManager.appendTriageItem(taskFile: taskFile, title: cleanTitle,
                                         body: body, provenance: provenance) {
            SlackFileLog.log("triage add: \(cleanTitle.prefix(60)) -> \(resolved.name)")
            await postEphemeral(channel: channelId, user: user,
                                text: ":inbox_tray: Added to *\(resolved.name)* ## Triage — promote it to ## Active when reviewed.")
        } else {
            await postEphemeral(channel: channelId, user: user,
                                text: "Couldn't write to `\(taskFile)`.")
        }
    }

    /// `/claude-brief` + `!brief` — the project's cleaner-written briefing
    /// (`Dashboard.md` `<!-- gen:briefing -->`: Now / Next / Recently done /
    /// Later) as a card with freshness + counts. Read-only; the content is at
    /// most one cleaner cycle (~24h) old.
    private func briefCard(channelId: String, responseUrl: String?,
                           threadTs: String? = nil, projectArg: String? = nil) async {
        guard let resolved = await resolvedPMContext(channelId: channelId, projectArg: projectArg) else {
            await respond(channel: channelId, responseUrl: responseUrl,
                          text: "No project matched. In a channel, bind one with `/claude-project <absolute-dir> [name]`; in a DM, name it: `!brief <project>`.",
                          ephemeral: true)
            return
        }
        let dashboardPath = (resolved.obsidianPath as NSString).appendingPathComponent("Dashboard.md")
        let taskFile = (resolved.obsidianPath as NSString).appendingPathComponent("Tasks.md")
        let briefing = Self.extractBriefing(dashboardPath: dashboardPath)
            ?? "_No briefing block yet — the overnight cleaner writes one for active projects._"

        var meta: [String] = []
        if let p = vaultProjects.projects.first(where: { $0.folder.path == resolved.obsidianPath }) {
            meta.append("status \(p.status)")
            if !p.updatedRaw.isEmpty { meta.append("updated \(p.updatedRaw)") }
        }
        let content = (try? String(contentsOfFile: taskFile, encoding: .utf8)) ?? ""
        meta.append("\(Self.openTaskCount(content: content)) active · \(VaultManager.triageCount(taskFile: taskFile)) triage")

        let blocks: [[String: Any]] = [
            SlackBlocks.section(":compass: *\(resolved.name)*"),
            SlackBlocks.section(Self.toSlackMrkdwn(briefing)),
            SlackBlocks.context(meta.joined(separator: " · "))
        ]
        await postMessage(channel: channelId, text: "Briefing — \(resolved.name)",
                          threadTs: threadTs, blocks: blocks)
    }

    /// The delimited `<!-- gen:briefing -->` block body from a Dashboard.md.
    static func extractBriefing(dashboardPath: String) -> String? {
        guard let content = try? String(contentsOfFile: dashboardPath, encoding: .utf8),
              let start = content.range(of: "<!-- gen:briefing -->"),
              let end = content.range(of: "<!-- /gen:briefing -->",
                                      range: start.upperBound..<content.endIndex) else { return nil }
        let block = String(content[start.upperBound..<end.lowerBound])
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return block.isEmpty ? nil : block
    }

    /// Count of actionable (not-done) tasks in an `## Active` body — flat tasks
    /// plus heading-group children, matching what the task card renders.
    static func openTaskCount(content: String) -> Int {
        VaultProjectService.parseActiveTasks(from: content).reduce(0) { acc, task in
            guard !task.isDone else { return acc }
            return acc + (task.isHeading
                          ? task.subBullets.filter { !$0.isDone }.count
                          : 1)
        }
    }

    // MARK: - PM capture via emoji reaction

    /// 📥/📌 on any message in a bound channel captures it into the project's
    /// `## Triage` with a permalink. Ships DORMANT: `reactions:read` is already
    /// granted but `reaction_added` still needs adding to the app manifest's
    /// event subscriptions (a save on api.slack.com — no reinstall, the scope
    /// is held); the moment it is, this handler goes live.
    private func handleReactionAdded(_ event: [String: Any]) {
        let reaction = event["reaction"] as? String ?? ""
        guard reaction == "inbox_tray" || reaction == "pushpin" else { return }
        let user = event["user"] as? String ?? ""
        if !user.isEmpty, user == botUserId { return }
        guard let item = event["item"] as? [String: Any],
              let channel = item["channel"] as? String,
              let ts = item["ts"] as? String else { return }
        Task { await self.captureMessageToTriage(channelId: channel, messageTs: ts, user: user) }
    }

    private func captureMessageToTriage(channelId: String, messageTs: String,
                                        user: String) async {
        guard let name = await channelName(for: channelId),
              let resolved = resolveProject(forChannelName: name) else { return }
        let json = await slackForm(method: "conversations.history",
                                   form: ["channel": channelId, "latest": messageTs,
                                          "inclusive": "true", "limit": "1"])
        let text = ((json?["messages"] as? [[String: Any]])?.first?["text"] as? String) ?? ""
        guard !text.isEmpty else {
            await postEphemeral(channel: channelId, user: user,
                                text: "Couldn't read that message to capture it.")
            return
        }
        let oneLine = text.replacingOccurrences(of: "\n", with: " ")
        let title = String(oneLine.prefix(140))
        let overflow = oneLine.count > 140 ? String(oneLine.prefix(500).dropFirst(140)) : ""
        let fmt = DateFormatter()
        fmt.dateFormat = "yyyy-MM-dd"
        var provenance = "via Slack reaction, \(fmt.string(from: Date()))"
        if let permalink = await messagePermalink(channelId: channelId, messageTs: messageTs) {
            provenance += " · \(permalink)"
        }
        let taskFile = (resolved.obsidianPath as NSString).appendingPathComponent("Tasks.md")
        if VaultManager.appendTriageItem(taskFile: taskFile, title: title,
                                         body: overflow.isEmpty ? nil : "…\(overflow)",
                                         provenance: provenance) {
            SlackFileLog.log("reaction capture -> \(resolved.name) triage")
            await postEphemeral(channel: channelId, user: user,
                                text: ":inbox_tray: Captured to *\(resolved.name)* ## Triage.")
        }
    }

    private func messagePermalink(channelId: String, messageTs: String) async -> String? {
        let json = await slackForm(method: "chat.getPermalink",
                                   form: ["channel": channelId, "message_ts": messageTs])
        guard json?["ok"] as? Bool == true else { return nil }
        return json?["permalink"] as? String
    }

    // MARK: - PM ambient layer: morning digest

    /// Persisted digest bookkeeping: the day last posted (so a relaunch never
    /// double-posts) and the cached DM channel.
    private struct DigestState: Codable {
        var lastPostedDay: String = ""
        var dmChannelId: String? = nil
    }
    private var digestState = DigestState()
    private static var digestFileURL: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/ClaudeHUD/slack-digest.json")
    }
    private func loadDigestState() {
        if let data = try? Data(contentsOf: Self.digestFileURL),
           let s = try? JSONDecoder().decode(DigestState.self, from: data) {
            digestState = s
        }
    }
    private func saveDigestState() {
        Self.writeJSON(digestState, to: Self.digestFileURL, label: "saveDigestState")
    }

    /// Fire the once-daily digest on the first 5-min tick at/after the
    /// configured local time (default 07:45, keys `slack.digestHour` /
    /// `slack.digestMinute`). Laptop-sleep-safe: a missed window posts on the
    /// first tick after wake, once. Disable with
    /// `defaults write com.claudehud slack.digestEnabled -bool NO`.
    private func startDigestLoop() {
        loadDigestState()
        Task { [weak self] in
            while true {
                guard let self else { return }
                await self.maybePostMorningDigest()
                try? await Task.sleep(nanoseconds: 5 * 60 * 1_000_000_000)
            }
        }
    }

    private func maybePostMorningDigest() async {
        let ud = UserDefaults.standard
        if ud.object(forKey: "slack.digestEnabled") != nil,
           !ud.bool(forKey: "slack.digestEnabled") { return }
        let hour = ud.object(forKey: "slack.digestHour") as? Int ?? 7
        let minute = ud.object(forKey: "slack.digestMinute") as? Int ?? 45

        let fmt = DateFormatter()
        fmt.dateFormat = "yyyy-MM-dd"
        let today = fmt.string(from: Date())
        guard digestState.lastPostedDay != today else { return }
        let comps = Calendar.current.dateComponents([.hour, .minute], from: Date())
        let nowMinutes = (comps.hour ?? 0) * 60 + (comps.minute ?? 0)
        guard nowMinutes >= hour * 60 + minute else { return }
        await postMorningDigest(force: false)
    }

    /// One cross-project morning digest, DM'd to the operator: per active
    /// project (newest `updated:` first, cap 12) the briefing's "Now" line +
    /// open/triage counts, plus any turns parked on you right now. The Slack
    /// analog of Claude Tag's ambient layer, sourced entirely from what the
    /// cleaner and the vault already wrote — no model call.
    func postMorningDigest(force: Bool) async {
        let fmt = DateFormatter()
        fmt.dateFormat = "yyyy-MM-dd"
        let today = fmt.string(from: Date())
        if !force, digestState.lastPostedDay == today { return }
        guard let dm = await ensureDMChannel() else {
            SlackFileLog.log("digest: no DM channel (users.list/conversations.open failed)")
            return
        }

        let active = vaultProjects.projects.filter { $0.isActive }
        var lines: [String] = []
        for project in active.sorted(by: { ($0.updated ?? .distantPast) > ($1.updated ?? .distantPast) }).prefix(12) {
            let taskFile = project.tasksPath.path
            let content = (try? String(contentsOfFile: taskFile, encoding: .utf8)) ?? ""
            let open = Self.openTaskCount(content: content)
            let triage = VaultManager.triageCount(taskFile: taskFile)
            var line = "*\(project.name)* · \(open) open"
            if triage > 0 { line += " · \(triage) triage" }
            if let briefing = Self.extractBriefing(dashboardPath: project.dashboardPath.path),
               let nowLine = briefing.components(separatedBy: "\n")
                   .first(where: { $0.hasPrefix("**Now**") }) {
                var t = nowLine.replacingOccurrences(of: "**Now**", with: "")
                t = t.trimmingCharacters(in: CharacterSet(charactersIn: " \t—–-:"))
                if !t.isEmpty { line += "\n        _\(SlackBlocks.truncate(t, 180))_" }
            }
            lines.append(line)
        }

        var header = ":sunrise: *Morning digest · \(today)*"
        let parked = parkedPrompts.count
        if parked > 0 {
            header += "\n:raising_hand: \(parked) question\(parked == 1 ? "" : "s") waiting on you"
        }
        let blocks: [[String: Any]] = [
            SlackBlocks.section(header),
            SlackBlocks.section(SlackBlocks.truncate(lines.joined(separator: "\n"),
                                                     SlackBlocks.sectionLimit)),
            SlackBlocks.context("\(active.count) active projects · `!tasks <project>` right here for a card · plain messages here run a generic session · `!digest` reposts this")
        ]
        await postMessage(channel: dm, text: "Morning digest \(today)", blocks: blocks)
        digestState.lastPostedDay = today
        saveDigestState()
        SlackFileLog.log("digest posted: \(lines.count) projects -> \(dm)")
    }

    /// The operator's DM channel, resolved once and cached: in this solo
    /// workspace the human is the only non-bot, non-deleted member.
    private func ensureDMChannel() async -> String? {
        if let dm = digestState.dmChannelId { return dm }
        guard let json = await slackForm(method: "users.list", form: ["limit": "200"]),
              json["ok"] as? Bool == true,
              let members = json["members"] as? [[String: Any]] else { return nil }
        let human = members.first {
            ($0["is_bot"] as? Bool) != true &&
            ($0["deleted"] as? Bool) != true &&
            ($0["id"] as? String) != "USLACKBOT"
        }
        guard let userId = human?["id"] as? String else { return nil }
        guard let open = await slackForm(method: "conversations.open", form: ["users": userId]),
              open["ok"] as? Bool == true,
              let channel = (open["channel"] as? [String: Any])?["id"] as? String else { return nil }
        digestState.dmChannelId = channel
        saveDigestState()
        return channel
    }

    // MARK: - Helpers

    /// Generic Slack web API POST (form-encoded) with tier-2 rate-limit
    /// handling: on HTTP 429 (or `ok:false error:ratelimited`), honor
    /// Retry-After and retry; returns the parsed JSON, or nil on transport
    /// error / exhausted retries. Errors are logged, never the token.
    private func slackForm(method: String, form: [String: String]) async -> [String: Any]? {
        guard let botToken else { return nil }
        let url = URL(string: "https://slack.com/api/\(method)")!
        let body = form
            .map { "\($0.key)=\($0.value.addingPercentEncoding(withAllowedCharacters: .slackURLQueryAllowed) ?? $0.value)" }
            .joined(separator: "&")

        for _ in 0..<6 {
            var req = URLRequest(url: url)
            req.httpMethod = "POST"
            req.setValue("Bearer \(botToken)", forHTTPHeaderField: "Authorization")
            req.setValue("application/x-www-form-urlencoded; charset=utf-8", forHTTPHeaderField: "Content-Type")
            req.httpBody = body.data(using: .utf8)

            do {
                let (data, resp) = try await session.data(for: req)
                if let http = resp as? HTTPURLResponse, http.statusCode == 429 {
                    let retry = Double(http.value(forHTTPHeaderField: "Retry-After") ?? "1") ?? 1
                    SlackFileLog.log("\(method): HTTP 429, retry after \(String(format: "%.0f", retry))s")
                    try? await Task.sleep(nanoseconds: UInt64(max(retry, 1) * 1_000_000_000))
                    continue
                }
                let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] ?? [:]
                if json["ok"] as? Bool != true {
                    let err = json["error"] as? String ?? "unknown"
                    if err == "ratelimited" {
                        SlackFileLog.log("\(method): ratelimited; retry after 1s")
                        try? await Task.sleep(nanoseconds: 1_000_000_000)
                        continue
                    }
                    SlackFileLog.log("\(method) error=\(err)")
                }
                return json
            } catch {
                SlackFileLog.log("\(method) request failed: \(error.localizedDescription)")
                return nil
            }
        }
        SlackFileLog.log("\(method): gave up after rate-limit retries")
        return nil
    }

    /// Slugify a project name into a valid Slack channel name: lowercase,
    /// every char outside `[a-z0-9]` becomes `-`, runs of `-` collapse, leading/
    /// trailing `-` are stripped, truncated to 80 chars. (Underscores and
    /// punctuation all map to `-`.) This is slug-compatible with the inbound
    /// resolver's `ProjectService.normalize`, so resolution is unaffected.
    static func slugify(_ name: String) -> String {
        var slug = ""
        var lastDash = false
        for scalar in name.lowercased().unicodeScalars {
            let c = Character(scalar)
            if (c >= "a" && c <= "z") || (c >= "0" && c <= "9") {
                slug.append(c)
                lastDash = false
            } else if !lastDash {
                slug.append("-")
                lastDash = true
            }
        }
        while slug.hasPrefix("-") { slug.removeFirst() }
        while slug.hasSuffix("-") { slug.removeLast() }
        if slug.count > 80 { slug = String(slug.prefix(80)) }
        while slug.hasSuffix("-") { slug.removeLast() }
        return slug
    }

    /// Minimal `Tasks.md` for a new project, following schema.md §Canonical
    /// project model: frontmatter `project/status/updated/cwds/migrated-from/aka`
    /// (matching the existing projects' convention), with `cwds` owning the
    /// directory and its subtree, plus an empty `## Active` section.
    static func tasksMarkdown(projectName: String, cwd: String) -> String {
        let today = isoDateFormatter.string(from: Date())
        return """
        ---
        project: \(projectName)
        status: active
        updated: \(today)
        cwds:
          - \(cwd)
          - \(cwd)/**
        migrated-from: []
        aka: []
        ---

        # \(projectName) Tasks

        ## Active

        ## Completed

        """
    }

    private static let isoDateFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd"
        f.locale = Locale(identifier: "en_US_POSIX")
        return f
    }()
}

private extension CharacterSet {
    /// URL-query-value-safe set (excludes `&`, `=`, `+`, etc. that have meaning
    /// in `application/x-www-form-urlencoded` bodies).
    static let slackURLQueryAllowed: CharacterSet = {
        var set = CharacterSet.alphanumerics
        set.insert(charactersIn: "-._~/*")
        return set
    }()
}
