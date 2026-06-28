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

    private var client: SocketModeClient?
    private var botToken: String?
    private var botUserId: String?
    private var botId: String?
    private var teamId: String?

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
    }
    private var channelSessions: [String: ChannelSession] = [:]

    /// One dedicated `ClaudeCLIClient` per channel — deliberately NOT the
    /// shared `AppState.cliClient` the chat tab owns. Per-channel instances
    /// give each channel its own `currentProcess` (so different channels can
    /// run concurrently) and isolate Slack's resume state from the chat tab.
    private var clients: [String: ClaudeCLIClient] = [:]

    /// Channels with a turn currently in flight (single-writer per channel).
    private var inFlight: Set<String> = []

    /// Model used for Slack-driven turns.
    private static let slackModel = "sonnet"

    init(projectService: ProjectService, vaultProjects: VaultProjectService) {
        self.projectService = projectService
        self.vaultProjects = vaultProjects
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
            self.client = client
            await client.start()
            self.isConnected = true
            logger.info("Slack Socket Mode started")
            SlackFileLog.log("Slack Socket Mode started")

            // Additive channel provisioning on startup: ensure every project
            // has a matching public channel the bot has joined. Never destructive.
            let summary = await self.syncChannels()
            SlackFileLog.log("startup sync: \(summary.projects) projects, \(summary.created) channels created")
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
        default:
            break
        }
    }

    /// Filter to genuine human messages. Skips edits/deletes (any `subtype`),
    /// bot posts (`bot_id`), and the bot's own `user` id — all of which would
    /// otherwise create reply loops.
    private func handleMessageEvent(_ event: [String: Any]) {
        guard event["subtype"] == nil else { return }
        guard event["bot_id"] == nil else { return }
        if let user = event["user"] as? String, user == botUserId { return }
        guard let channel = event["channel"] as? String else { return }
        let text = event["text"] as? String ?? ""

        Task { await self.handleMessage(channel: channel, text: text) }
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

    private func handleMessage(channel: String, text: String) async {
        guard let name = await channelName(for: channel) else {
            logger.debug("Could not resolve channel name for \(channel)")
            SlackFileLog.log("rx message in \(channel); channel name unresolved")
            return
        }
        SlackFileLog.log("rx message in #\(name) (\(channel))")

        if let resolved = resolveProject(forChannelName: name) {
            SlackFileLog.log("resolved -> \(resolved.name)/\(resolved.cwd)")
            await runTurn(channelId: channel, projectName: resolved.name, cwd: resolved.cwd,
                          obsidianPath: resolved.obsidianPath, text: text)
        } else {
            SlackFileLog.log("no match for #\(name)")
            await postMessage(
                channel: channel,
                text: "No ClaudeHUD project matches #\(name). Rename the channel to a project name (later this becomes the ~ catch-all)."
            )
        }
    }

    // MARK: - Phase 2: turn driving

    /// Drive one Claude turn for a channel by reusing `ClaudeCLIClient` (the
    /// same engine `ConversationManager` uses). Resumes the channel's session
    /// if present, runs in the project's cwd with the channel's permission
    /// mode, accumulates the streamed assistant text, persists the (new)
    /// session id, and posts the final text back. Single-writer per channel.
    private func runTurn(channelId: String, projectName: String, cwd: String,
                         obsidianPath: String, text: String) async {
        guard !inFlight.contains(channelId) else {
            await postMessage(channel: channelId,
                              text: "Busy with the current turn in this channel — resend once it finishes.")
            return
        }
        inFlight.insert(channelId)
        defer { inFlight.remove(channelId) }

        var state = channelSessions[channelId] ?? ChannelSession(sessionId: nil, permissionMode: "default", cwd: nil)

        // CWD-AWARE SESSIONS: a session id only resumes in the cwd's own
        // `~/.claude/projects` store. If the project's resolved cwd changed
        // since the session was created (or no cwd was recorded), the stored
        // session is stranded — drop it and start fresh.
        if state.sessionId != nil, state.cwd != cwd {
            SlackFileLog.log("cwd changed (\(state.cwd ?? "none") -> \(cwd)); starting fresh session")
            state.sessionId = nil
        }

        let isFresh = state.sessionId == nil
        SlackFileLog.log("turn: #\(channelId) project=\(projectName) resume=\(isFresh ? "N" : "Y") mode=\(state.permissionMode)")

        // On a FRESH session, prime Claude with the project's Obsidian context
        // so a cold opener ("and now?") doesn't make it ask what we were
        // working on. Resumed turns carry context in-session, so the bare
        // message is sent (no re-injection every turn). The primed form is also
        // what the empty-resume retry below uses (it's a fresh session then).
        let freshOutgoing = Self.contextPreamble(projectName: projectName, cwd: cwd,
                                                 obsidianPath: obsidianPath, userText: text)
        if isFresh {
            SlackFileLog.log("fresh session: primed with obsidian context for \(projectName) (\(obsidianPath))")
        }

        // Immediate feedback: post a "working…" placeholder and capture its ts
        // so we can edit it in place when the turn finishes. Reads can take
        // ~45s; this avoids dead air. If the post fails (no ts), we fall back
        // to posting the final text fresh.
        let placeholderTs = await postMessage(channel: channelId, text: ":hourglass_flowing_sand: _working…_")
        SlackFileLog.log("working placeholder ts=\(placeholderTs ?? "nil")")

        do {
            var run = try await runEngine(
                channelId: channelId,
                message: isFresh ? freshOutgoing : text,
                permissionMode: state.permissionMode,
                sessionId: state.sessionId,
                cwd: cwd
            )

            // EMPTY-RESUME AUTO-RETRY: a resumed turn that comes back empty
            // (chars==0) usually means the session was missing/stranded in this
            // cwd's store. Retry ONCE as a fresh session (primed, no --resume).
            if !isFresh, run.text.isEmpty {
                SlackFileLog.log("empty resume result; retried fresh")
                state.sessionId = nil
                run = try await runEngine(
                    channelId: channelId,
                    message: freshOutgoing,
                    permissionMode: state.permissionMode,
                    sessionId: nil,
                    cwd: cwd
                )
            }

            // Claude replies in standard Markdown; Slack renders its own
            // "mrkdwn", so convert before posting (and before chunking).
            let finalText = Self.toSlackMrkdwn(run.text)
            let toolCounts = run.tools

            if !run.sessionId.isEmpty {
                state.sessionId = run.sessionId
                state.cwd = cwd
                channelSessions[channelId] = state
                saveChannelSessions()
            }

            let toolTotal = toolCounts.values.reduce(0, +)
            SlackFileLog.log("turn done: session=\(run.sessionId.prefix(8)) tools=\(toolTotal) chars=\(finalText.count)")

            let summary = Self.toolSummary(toolCounts)
            let body: String
            if finalText.isEmpty {
                body = summary.isEmpty ? "(no output)" : summary
            } else {
                body = summary.isEmpty ? finalText : "\(summary)\n\n\(finalText)"
            }

            // Turn the "working…" placeholder INTO the answer: chat.update it
            // with the first chunk, post any further chunks as new messages.
            // No placeholder ts → post fresh (fallback).
            let chunks = Self.splitChunks(body)
            if let ts = placeholderTs, let first = chunks.first {
                await chatUpdate(channel: channelId, ts: ts, text: first)
                for extra in chunks.dropFirst() {
                    await postMessage(channel: channelId, text: extra)
                }
            } else {
                await postChunked(channel: channelId, text: body)
            }
        } catch {
            SlackFileLog.log("turn error: \(error.localizedDescription)")
            let errText = "Turn failed: \(error.localizedDescription)"
            if let ts = placeholderTs {
                await chatUpdate(channel: channelId, ts: ts, text: errText)
            } else {
                await postMessage(channel: channelId, text: errText)
            }
        }
    }

    /// Run one engine invocation for a channel and collect the result. When
    /// `sessionId` is nil this is a fresh run — the client's stale
    /// `currentSessionId` is cleared first so `send()` can't fall back to it.
    /// Returns the final assistant text, per-tool counts, and the (new) session
    /// id. Repeatable, so the empty-resume retry can call it twice.
    private func runEngine(channelId: String, message: String, permissionMode: String,
                           sessionId: String?, cwd: String) async throws
        -> (text: String, tools: [String: Int], sessionId: String) {
        let client = clientFor(channelId)
        if sessionId == nil { client.newSession() }

        var assistantText = ""
        var toolCounts: [String: Int] = [:]
        let result = try await client.send(
            message: message,
            model: Self.slackModel,
            permissionMode: permissionMode,
            systemPrompt: nil,
            sessionId: sessionId,
            workingDirectory: cwd
        ) { event in
            switch event {
            case .assistant(let msg):
                if let t = msg.text { assistantText = t }
            case .toolUse(let tool):
                toolCounts[tool.toolName, default: 0] += 1
            case .result(let r):
                if !r.result.isEmpty { assistantText = r.result }
            default:
                break
            }
        }
        return (result.result.isEmpty ? assistantText : result.result, toolCounts, result.sessionId)
    }

    /// The channel's dedicated CLI engine (created on first use).
    private func clientFor(_ channelId: String) -> ClaudeCLIClient {
        if let existing = clients[channelId] { return existing }
        let client = ClaudeCLIClient()
        clients[channelId] = client
        return client
    }

    /// Context preamble prepended to the first message of a FRESH channel
    /// session: points Claude at the project's Obsidian notes and tells it to
    /// read them for current context before answering. Reads are permitted in
    /// every mode (Read is never disallowed), so the model can fetch them.
    private static func contextPreamble(projectName: String, cwd: String,
                                        obsidianPath: String, userText: String) -> String {
        return """
        [ClaudeHUD Slack session. Project: \(projectName). You're running in this \
        project's working directory (\(cwd)). Before answering, read this project's \
        Obsidian notes for current context: \(obsidianPath)/Tasks.md (the authoritative \
        active-task list), plus \(obsidianPath)/Technical Notes.md and \
        \(obsidianPath)/Dashboard.md if they exist. Read what's relevant, then address \
        the user's message.]

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

    /// Apply the inline + line conversions to a non-code segment.
    private static func convertNonCode(_ s: String) -> String {
        var t = s
        // Links [text](url) -> <url|text> (before bold, so bold inside link
        // text still converts afterward).
        t = regexReplace(t, #"\[([^\]]+)\]\(([^)\s]+)\)"#, "<$2|$1>")
        // Bold **x** / __x__ -> *x* (single-line; `.` doesn't span newlines).
        t = regexReplace(t, #"\*\*(.+?)\*\*"#, "*$1*")
        t = regexReplace(t, #"__(.+?)__"#, "*$1*")
        // Line-anchored: headers and bullets.
        let lines = t.components(separatedBy: "\n").map { line -> String in
            var l = line
            // # … ###### header -> bold the line text, drop hashes.
            l = regexReplace(l, #"^\s*#{1,6}[ \t]+(.*\S)[ \t]*$"#, "*$1*")
            // "- " / "* " bullet -> "• " (preserve leading indent).
            l = regexReplace(l, #"^([ \t]*)[-*] (.*)$"#, "$1• $2")
            return l
        }
        return lines.joined(separator: "\n")
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

    // MARK: - Phase 2: per-channel session persistence

    private static var sessionsFileURL: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/ClaudeHUD/slack-sessions.json")
    }

    private func loadChannelSessions() {
        guard let data = try? Data(contentsOf: Self.sessionsFileURL),
              let map = try? JSONDecoder().decode([String: ChannelSession].self, from: data) else { return }
        channelSessions = map
        SlackFileLog.log("loaded \(map.count) channel sessions")
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
    /// or nil on failure.
    @discardableResult
    private func postMessage(channel: String, text: String) async -> String? {
        guard let botToken else { return nil }

        var req = URLRequest(url: URL(string: "https://slack.com/api/chat.postMessage")!)
        req.httpMethod = "POST"
        req.setValue("Bearer \(botToken)", forHTTPHeaderField: "Authorization")
        req.setValue("application/json; charset=utf-8", forHTTPHeaderField: "Content-Type")
        let body: [String: Any] = ["channel": channel, "text": text]
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

    /// Edit an existing message in place (the "working…" placeholder becomes
    /// the answer). Uses `chat:write`.
    private func chatUpdate(channel: String, ts: String, text: String) async {
        guard let botToken else { return }

        var req = URLRequest(url: URL(string: "https://slack.com/api/chat.update")!)
        req.httpMethod = "POST"
        req.setValue("Bearer \(botToken)", forHTTPHeaderField: "Authorization")
        req.setValue("application/json; charset=utf-8", forHTTPHeaderField: "Content-Type")
        let body: [String: Any] = ["channel": channel, "ts": ts, "text": text]
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
        case "/claude-mode":
            await setMode(arg: text, channelId: channelId, responseUrl: responseUrl)
        default:
            SlackFileLog.log("slash unknown command \(command)")
        }
    }

    /// `/claude-new` — clear the channel's session id so the next message
    /// starts fresh. Also resets the channel's CLI engine resume state.
    private func newSession(channelId: String, responseUrl: String?) async {
        var state = channelSessions[channelId] ?? ChannelSession(sessionId: nil, permissionMode: "default", cwd: nil)
        state.sessionId = nil
        channelSessions[channelId] = state
        clients[channelId]?.newSession()
        saveChannelSessions()
        SlackFileLog.log("claude-new: cleared session for \(channelId)")
        let name = await channelName(for: channelId) ?? channelId
        await respond(channel: channelId, responseUrl: responseUrl,
                      text: "Started a fresh session in #\(name).")
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
        var state = channelSessions[channelId] ?? ChannelSession(sessionId: nil, permissionMode: "default", cwd: nil)
        state.permissionMode = mode
        channelSessions[channelId] = state
        saveChannelSessions()
        SlackFileLog.log("claude-mode: \(channelId) -> \(mode)")

        let reply: String
        switch mode {
        case "plan":
            reply = "Permission mode set to *plan* — read-only (no Edit/Write/Bash)."
        case "default":
            reply = "Permission mode set to *default* — Edit/Write allowed, Bash blocked."
        default:
            reply = ":warning: Permission mode set to *skip* — everything allowed, *including Bash*. Use with care."
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
    private func respond(channel: String, responseUrl: String?, text: String) async {
        if let responseUrl, let url = URL(string: responseUrl) {
            var req = URLRequest(url: url)
            req.httpMethod = "POST"
            req.setValue("application/json; charset=utf-8", forHTTPHeaderField: "Content-Type")
            req.httpBody = try? JSONSerialization.data(withJSONObject: [
                "response_type": "in_channel", "text": text
            ])
            do {
                _ = try await session.data(for: req)
                SlackFileLog.log("slash response posted via response_url")
            } catch {
                SlackFileLog.log("slash response_url failed: \(error.localizedDescription)")
                if !channel.isEmpty { await postMessage(channel: channel, text: text) }
            }
        } else if !channel.isEmpty {
            await postMessage(channel: channel, text: text)
        }
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
