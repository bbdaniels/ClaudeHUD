import AppKit
import Foundation
import os
import SQLite3

private let logger = Logger(subsystem: "com.claudehud", category: "SessionHistory")

// MARK: - Session Info Model

struct SessionInfo: Identifiable {
    let id: String           // session UUID (filename without .jsonl)
    let projectPath: String  // decoded absolute path
    let projectName: String  // last component (e.g. "ClaudeHUD")
    let preview: String      // first user message preview
    let timestamp: Date      // file modification time
    let filePath: String     // full path to .jsonl file (for on-demand search)

    /// Worktree subdirectory name when this session lives under
    /// `<project>/.claude/worktrees/<name>/...`, otherwise nil.
    var worktreeName: String? {
        guard let range = projectPath.range(of: "/.claude/worktrees/") else { return nil }
        let after = projectPath[range.upperBound...]
        let name = after.split(separator: "/").first.map(String.init) ?? ""
        return name.isEmpty ? nil : name
    }
}

// MARK: - Search Result

struct SessionSearchResult: Identifiable {
    let id: String           // session ID
    let snippet: String      // ~80 chars around the match
}

// MARK: - Session History Service

@MainActor
class SessionHistoryService: ObservableObject {
    @Published var sessions: [SessionInfo] = []
    @Published var isLoading = false
    @Published var searchResults: [String: SessionSearchResult] = [:]  // sessionId -> result
    @Published var isSearching = false

    private let claudeProjectsDir = "\(NSHomeDirectory())/.claude/projects"
    private var searchTask: Task<Void, Never>?

    /// Persistent full-text index over listed transcripts (user + assistant
    /// text only). Updated incrementally after every scan; the ONLY search path.
    private let transcriptIndex = TranscriptIndex()
    private var indexTask: Task<Void, Never>?
    private var currentQuery = ""

    /// Coalesces overlapping refreshes (launch, History appear, Projects
    /// appear) into one scan.
    private var refreshTask: Task<Void, Never>?

    func refresh() async {
        if let inFlight = refreshTask { return await inFlight.value }
        let task = Task { await performRefresh() }
        refreshTask = task
        await task.value
        refreshTask = nil
    }

    private func performRefresh() async {
        isLoading = true
        defer { isLoading = false }

        let started = Date()
        let index = transcriptIndex
        let headCache = await index.loadHeads()
        let scan = await Task.detached(priority: .userInitiated) { [claudeProjectsDir] in
            Self.scanSessions(in: claudeProjectsDir, headCache: headCache)
        }.value
        let ms = Int(Date().timeIntervalSince(started) * 1000)
        logger.info("session scan: \(scan.sessions.count, privacy: .public) sessions, \(scan.changedHeads.count, privacy: .public) heads classified, in \(ms, privacy: .public) ms")

        sessions = scan.sessions
        await index.saveHeads(changed: scan.changedHeads, removed: scan.removedPaths)
        updateIndex()
        updateTitles()
    }

    // MARK: - Titles

    private let titler = SessionTitler()
    private var titleTask: Task<Void, Never>?

    /// Title untitled sessions in the background, one Haiku call at a time,
    /// and relabel each row as its title lands. One pass at a time; a
    /// refresh during a pass is picked up by the next refresh.
    private func updateTitles() {
        guard titleTask == nil else { return }
        let candidates = sessions.map { (id: $0.id, path: $0.filePath, modified: $0.timestamp) }
        let titler = titler
        titleTask = Task { [weak self] in
            await titler.titleUntitled(candidates) { id, title in
                await MainActor.run { self?.relabel(id: id, title: title) }
            }
            await MainActor.run { self?.titleTask = nil }
        }
    }

    private func relabel(id: String, title: String) {
        guard let i = sessions.firstIndex(where: { $0.id == id }) else { return }
        let s = sessions[i]
        sessions[i] = SessionInfo(id: s.id, projectPath: s.projectPath, projectName: s.projectName,
                                  preview: title, timestamp: s.timestamp, filePath: s.filePath)
    }

    /// Bring the index up to date with the listed sessions, off the main
    /// actor. One pass at a time: a refresh during a pass is picked up by the
    /// next refresh (only changed/grown files are read, so passes are cheap
    /// once the first build is done). A live query re-runs when the pass ends
    /// so results filled in by a first build appear without retyping.
    private func updateIndex() {
        guard indexTask == nil else { return }
        let files = sessions.map { (id: $0.id, path: $0.filePath) }
        let index = transcriptIndex
        indexTask = Task { [weak self] in
            await index.update(files: files)
            guard let self else { return }
            self.indexTask = nil
            if !self.currentQuery.isEmpty { self.search(query: self.currentQuery) }
        }
    }

    /// Full-text search: an FTS5 prefix query against the transcript index,
    /// published in ONE batch (a per-match @Published mutation re-rendered the
    /// non-lazy history list once per hit). The view orders hits by recency.
    func search(query: String) {
        searchTask?.cancel()
        currentQuery = query

        guard !query.isEmpty else {
            searchResults = [:]
            isSearching = false
            return
        }

        isSearching = true
        let index = transcriptIndex
        searchTask = Task { [weak self] in
            let collected = await index.search(query)
            guard let self, !Task.isCancelled else { return }
            self.searchResults = collected
            self.isSearching = false
        }
    }

    /// Delete a session's JSONL file and remove it from the list.
    func deleteSession(id: String) {
        guard sessions.contains(where: { $0.id == id }) else { return }

        // Find and delete the JSONL file
        let fm = FileManager.default
        let projectDirs = (try? fm.contentsOfDirectory(atPath: claudeProjectsDir)) ?? []
        for dir in projectDirs {
            let filePath = "\(claudeProjectsDir)/\(dir)/\(id).jsonl"
            if fm.fileExists(atPath: filePath) {
                try? fm.removeItem(atPath: filePath)
                break
            }
        }

        sessions.removeAll { $0.id == id }
        let index = transcriptIndex
        Task { await index.remove(sessionID: id) }
    }

    // MARK: - Scanning (off main thread)

    /// List real sessions. ~/.claude/projects holds ~10,000 transcripts (almost
    /// all machine one-shots, each in its own project dir), so re-reading every
    /// 64 KB head and decoding every dir name on each scan cost ~12 s. Head
    /// verdicts are cached by path + mtime + size (a transcript that has not
    /// changed cannot change verdict), and a dir name is decoded only when it
    /// holds a listed session.
    nonisolated private static func scanSessions(
        in baseDir: String, headCache: [String: CachedHead]
    ) -> (sessions: [SessionInfo], changedHeads: [String: CachedHead], removedPaths: [String]) {
        let fm = FileManager.default
        guard let projectDirs = try? fm.contentsOfDirectory(atPath: baseDir) else { return ([], [:], []) }

        // Close-out titles written by the vault-ingest pipeline at SessionEnd
        // (see loadSidecarTitles). When present they ARE the label — they
        // summarize what the session accomplished, which Claude Code's
        // ai-title never captures for magic-launched sessions.
        let sidecarTitles = loadSidecarTitles()

        var found: [SessionInfo] = []
        var changedHeads: [String: CachedHead] = [:]
        var seenPaths = Set<String>()

        // mtime + size come back with the listing itself (bulk attribute
        // fetch), not one stat per transcript.
        let keys: [URLResourceKey] = [.contentModificationDateKey, .fileSizeKey]
        for dir in projectDirs {
            let dirPath = "\(baseDir)/\(dir)"
            // Fails for non-directories, so no separate isDirectory stat.
            guard let urls = try? fm.contentsOfDirectory(
                at: URL(fileURLWithPath: dirPath, isDirectory: true),
                includingPropertiesForKeys: keys, options: [.skipsHiddenFiles]) else { continue }
            var decodedDir: (path: String, name: String)?

            for url in urls where url.pathExtension == "jsonl" {
                let file = url.lastPathComponent
                let filePath = "\(dirPath)/\(file)"
                let sessionId = String(file.dropLast(6)) // remove .jsonl

                guard let values = try? url.resourceValues(forKeys: Set(keys)),
                      let modDate = values.contentModificationDate,
                      let fileSize = values.fileSize else { continue }
                let size = Int64(fileSize)
                seenPaths.insert(filePath)
                let mtime = modDate.timeIntervalSince1970

                // Classify every session from its transcript head FIRST — even
                // when a digest sidecar exists. Sidecars used to win outright,
                // which let machine one-shots that slipped past the digest's
                // NO_DURABLE_CONTENT rule surface in history under a plausible
                // title (Haiku digested a skill-selector query as real work:
                // "Skill-selection query re: patient risk scoring"). The head
                // read is off the main thread and cached per file version.
                let verdict: CachedHead
                if let cached = headCache[filePath], cached.mtime == mtime, cached.size == size {
                    verdict = cached
                } else {
                    verdict = headVerdict(for: filePath, mtime: mtime, size: size)
                    changedHeads[filePath] = verdict
                }
                if verdict.kind == .machine { continue }

                if decodedDir == nil { decodedDir = decodeProjectDir(dir) }
                let (projectPath, projectName) = decodedDir!

                let preview: String
                if let title = sidecarTitles[sessionId] {
                    // Ingested, substantive session: the close-out digest title
                    // wins. Strip a leading "<project>: " — every row already
                    // carries a project tag, and sidecars written before the
                    // ingest prompt's no-project-name title rule carry the
                    // prefix forever otherwise. A sidecar also rescues .unknown
                    // heads (e.g. a giant first record that overflows the head
                    // window): the digest itself proves the session had
                    // substance.
                    preview = stripProjectPrefix(title, projectName: projectName)
                } else if let label = verdict.label {
                    preview = label
                } else {
                    // No real user turn found in the head and never digested:
                    // abandoned shells and unparseable heads.
                    continue
                }

                found.append(SessionInfo(
                    id: sessionId,
                    projectPath: projectPath,
                    projectName: projectName,
                    preview: preview,
                    timestamp: modDate,
                    filePath: filePath
                ))
            }
        }

        let removed = headCache.keys.filter { !seenPaths.contains($0) }
        return (found.sorted { $0.timestamp > $1.timestamp }, changedHeads, removed)
    }

    /// Session titles, keyed by session id under
    /// ~/.claude/hud/session-titles/<id>.txt. Written by the one title
    /// generator, `SessionTitler`; sidecars from vault-ingest digests before
    /// 1.11.0 remain valid. Loaded once per scan; an untitled session falls
    /// back to its first real prompt. A sidecar is a LABEL, not a listing
    /// decision: machine one-shots are dropped by classifyHead even when a
    /// stray sidecar exists.
    nonisolated private static func loadSidecarTitles() -> [String: String] {
        let dir = "\(NSHomeDirectory())/.claude/hud/session-titles"
        let fm = FileManager.default
        guard let files = try? fm.contentsOfDirectory(atPath: dir) else { return [:] }
        var map: [String: String] = [:]
        map.reserveCapacity(files.count)
        for f in files where f.hasSuffix(".txt") {
            let sid = String(f.dropLast(4))
            guard let raw = try? String(contentsOfFile: "\(dir)/\(f)", encoding: .utf8) else { continue }
            let t = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            if !t.isEmpty { map[sid] = String(t.prefix(100)) }
        }
        return map
    }

    /// Strip a leading "<project>: " / "<project> — " from a digest title.
    /// The ingest prompt's title rule forbids the project name (the history
    /// row already carries a project tag), but sidecars written before the
    /// rule landed — and the occasional model slip since — still carry it.
    /// A display-level strip fixes the whole backlog without rewriting any
    /// vault history.
    nonisolated private static func stripProjectPrefix(_ title: String, projectName: String) -> String {
        guard !projectName.isEmpty, title.count > projectName.count,
              title.lowercased().hasPrefix(projectName.lowercased()) else { return title }
        let rest = title.dropFirst(projectName.count)
        guard let sep = rest.first, ":—–- ".contains(sep) else { return title }
        let stripped = rest.drop { ":—–- ".contains($0) }
        guard stripped.count >= 8 else { return title }  // never strip to a stub
        return stripped.prefix(1).uppercased() + String(stripped.dropFirst())
    }

    // MARK: - Message Content

    /// Extract user/assistant text content from a JSONL line (any format).
    nonisolated fileprivate static func extractMessageContent(from json: [String: Any]) -> String? {
        // Format 1: {"role": "user"/"assistant", "content": "..."}
        if let role = json["role"] as? String, role == "user" || role == "assistant" {
            return extractTextContent(json["content"])
        }
        // Format 2: {"type": "human"/"assistant", "message": {...}}
        if let type = json["type"] as? String, (type == "human" || type == "assistant") {
            if let msg = json["message"] as? [String: Any] {
                return extractTextContent(msg["content"])
            }
        }
        // Format 3: {"message": {"role": "user"/"assistant", ...}}
        if let msg = json["message"] as? [String: Any],
           let role = msg["role"] as? String, role == "user" || role == "assistant" {
            return extractTextContent(msg["content"])
        }
        return nil
    }

    // MARK: - Project Path Decoding

    /// Decode a directory name like `-Users-bbdaniels-GitHub-ClaudeHUD` back to `/Users/bbdaniels/GitHub/ClaudeHUD`.
    ///
    /// Claude Code encodes project paths by replacing `/`, `_`, and `.` with `-`.
    /// Decoding is ambiguous, so we probe the filesystem greedily: at each `-`,
    /// try treating it as a path separator (checking dash, underscore, and dot
    /// variants of the accumulated component). If no directory matches, keep the
    /// dash as a literal character in the current component.
    nonisolated private static func decodeProjectDir(_ dirName: String) -> (path: String, name: String) {
        let fm = FileManager.default
        let home = NSHomeDirectory()
        // "/Users/bbdaniels" → "-Users-bbdaniels"
        let homeEncoded = home.replacingOccurrences(of: "/", with: "-")

        let basePath: String
        let remainder: String

        if dirName.hasPrefix(homeEncoded + "-") {
            basePath = home
            remainder = String(dirName.dropFirst(homeEncoded.count + 1))
        } else {
            basePath = ""
            remainder = String(dirName.dropFirst(1))
        }

        var resolved = basePath
        var component = ""

        for c in remainder {
            if c == "-" {
                if !component.isEmpty {
                    // Try treating this dash as a path separator
                    for variant in componentVariants(component) {
                        let candidate = resolved + "/" + variant
                        var isDir: ObjCBool = false
                        if fm.fileExists(atPath: candidate, isDirectory: &isDir), isDir.boolValue {
                            resolved = candidate
                            component = ""
                            break
                        }
                    }
                    if component.isEmpty { continue }
                }
                // Not a separator — keep as literal dash (may represent '-', '_', or '.')
                component.append("-")
            } else {
                component.append(c)
            }
        }

        // Resolve the final component (file or directory)
        if !component.isEmpty {
            for variant in componentVariants(component) {
                let candidate = resolved + "/" + variant
                if fm.fileExists(atPath: candidate) {
                    return (candidate, variant)
                }
            }
        }

        let fallbackPath = component.isEmpty ? resolved : resolved + "/" + component
        return (fallbackPath, URL(fileURLWithPath: fallbackPath).lastPathComponent)
    }

    /// Returns variants of a path component, trying all combinations of dash/space/underscore/dot
    /// at each dash position.  Handles names like "26-1 Spring" where some dashes are literal and
    /// others represent spaces.  Falls back to uniform replacement when there are too many dashes.
    nonisolated private static func componentVariants(_ component: String) -> [String] {
        guard component.contains("-") else { return [component] }

        let parts = component.split(separator: "-", omittingEmptySubsequences: false).map(String.init)
        let dashCount = parts.count - 1

        // Too many dashes for combinatorial search → uniform replacement only
        guard dashCount <= 4 else {
            return [
                component,
                component.replacingOccurrences(of: "-", with: " "),
                component.replacingOccurrences(of: "-", with: "_"),
                component.replacingOccurrences(of: "-", with: "."),
            ]
        }

        let separators = ["-", " ", "_", "."]
        let total = Int(pow(4.0, Double(dashCount)))
        var results: [String] = []
        results.reserveCapacity(total)

        for i in 0..<total {
            var result = parts[0]
            var combo = i
            for j in 1..<parts.count {
                result += separators[combo % 4] + parts[j]
                combo /= 4
            }
            results.append(result)
        }

        return results
    }

    // MARK: - Head Classification

    /// What the head of a transcript says about a session. `.normal` carries
    /// the first genuine user prompt (preview-ready); `.magicLaunch` the
    /// project name parsed from the bootstrap boilerplate; `.machine` is a
    /// programmatic one-shot (never listed); `.unknown` means the head held
    /// no verdict (listed only if a digest sidecar vouches for it).
    private enum HeadClass {
        case machine
        case unknown
        case normal(String)
        case magicLaunch(String)
    }

    /// A transcript's listing verdict: its head class resolved to a label.
    /// Expensive (a 64 KB head read, plus up to 1 MB for a magic launch), so
    /// the scan caches it per file version.
    nonisolated private static func headVerdict(for path: String, mtime: Double, size: Int64) -> CachedHead {
        switch classifyHead(from: path) {
        case .machine:
            return CachedHead(mtime: mtime, size: size, kind: .machine, label: nil)
        case .unknown:
            return CachedHead(mtime: mtime, size: size, kind: .listed, label: nil)
        case .normal(let firstPrompt):
            return CachedHead(mtime: mtime, size: size, kind: .listed, label: firstPrompt)
        case .magicLaunch:
            // Claude Code's ai-title is generated from the opening turn and
            // FROZEN, and every magic-launched session opens with the same
            // bootstrap boilerplate, so its ai-title is always junk ("context
            // load", "obsidian estonia-ecm project") no matter the work that
            // followed. Label with the user's first real prompt instead. A
            // bootstrap the person never typed into is an abandoned shell,
            // listed only if a digest sidecar titles it (like .unknown).
            return CachedHead(mtime: mtime, size: size, kind: .listed, label: conversationOpening(in: path, promptLimit: 1, wantReply: false).prompts.first.map { String($0.prefix(100)) })
        }
    }

    /// Classify a session from the first 64 KB of its transcript.
    ///
    ///  * **.machine** — programmatic `claude -p` runs: skill-tip catalog
    ///    selectors, remote-control liveness probes (PONG / SMOKE_OK), the
    ///    vault-ingest digest pipeline. Detected STRUCTURALLY: an SDK
    ///    one-shot's user record carries `entrypoint: "sdk-cli"`, while every
    ///    kind of real session (terminal, VSCode, desktop, magic-launch,
    ///    background job) records "cli"-family entrypoints. ~7,000 of these
    ///    litter ~/.claude/projects vs ~250 real sessions. Prompt-prefix
    ///    checks cover old transcripts that predate the field.
    ///
    ///    A `promptSource: "sdk"` record alone is NOT condemning: a real
    ///    interactive session can carry an injected selector prompt as its
    ///    FIRST user record yet hold the person's typed work after it
    ///    (observed in the wild: 1 of 7,617 transcripts). Such records are
    ///    skipped; `<command>` wrappers count as interactive evidence; only
    ///    if sdk records were seen and nothing interactive followed does the
    ///    window end as .machine.
    ///
    /// Mirrors `vault-ingest.sh::is_machine_transcript` (canonical; the
    /// ingest skips the same sessions without spending a model call).
    nonisolated private static func classifyHead(from path: String) -> HeadClass {
        guard let handle = FileHandle(forReadingAtPath: path) else { return .unknown }
        defer { handle.closeFile() }

        let data = handle.readData(ofLength: 65536)
        guard let text = String(data: data, encoding: .utf8) else { return .unknown }

        var sawSdk = false
        var sawLive = false
        for line in text.components(separatedBy: "\n").prefix(400) {
            guard !line.isEmpty,
                  let lineData = line.data(using: .utf8),
                  let json = try? JSONSerialization.jsonObject(with: lineData) as? [String: Any]
            else { continue }

            guard let content = extractMessageContent(from: json),
                  let role = messageRole(from: json), role == "user" else { continue }

            // Human-driven RELAY sessions run as SDK processes (entrypoint
            // "sdk-cli") yet are a person's real work: the ClaudeHUD Slack
            // relay stamps its context preamble onto the first user message.
            // Match the marker BEFORE the sdk-cli drop or every Slack session
            // vanishes from history. Title = the user's own text after the
            // preamble. Mirror: vault-ingest.sh::is_machine_transcript REAL.
            if content.hasPrefix("[ClaudeHUD Slack session.") {
                let body = content.range(of: "User message: ")
                    .map { String(content[$0.upperBound...]) } ?? content
                let title = body.trimmingCharacters(in: .whitespacesAndNewlines)
                return .normal(title.isEmpty ? "Slack session" : String(title.prefix(100)))
            }
            if json["entrypoint"] as? String == "sdk-cli" { return .machine }
            if json["promptSource"] as? String == "sdk" { sawSdk = true; continue }

            let trimmed = content.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.isEmpty { continue }
            // Magic-launch bootstrap is delivered as the `/vault-bootstrap`
            // slash command, whose recorded first turn starts with the
            // `<command-name>…` wrapper — so it must be recognised BEFORE the
            // generic `<`-wrapper skip below, or it would be swallowed as a
            // pass-through and the session mislabelled as normal.
            if let project = magicLaunchProject(trimmed) {
                return .magicLaunch(project)
            }
            // Command/skill wrappers precede the real prompt in real
            // sessions: skip the MESSAGE, note the interactive evidence,
            // keep scanning.
            if isPassThroughPrompt(trimmed) { sawLive = true; continue }
            // Known machine first-prompts drop the SESSION.
            if isMachineFirstPrompt(trimmed) { return .machine }
            return .normal(String(trimmed.prefix(100)))
        }

        return (sawSdk && !sawLive) ? .machine : .unknown
    }

    /// The opening of the conversation as the person had it: their first
    /// `promptLimit` genuine prompts (after any magic-launch bootstrap) and
    /// the first assistant text that followed the first one. Bootstrap
    /// context loading can run past a megabyte, so the file is streamed in
    /// chunks until enough is found. Only records the person sent count:
    /// `promptSource` typed, queued (typed while Claude was busy), or
    /// suggestion_accepted; system-injected records (task notifications) and
    /// meta/skill expansions carry other sources or none. Read-only.
    nonisolated static func conversationOpening(in path: String, promptLimit: Int, wantReply: Bool)
        -> (prompts: [String], reply: String?) {
        guard let handle = FileHandle(forReadingAtPath: path) else { return ([], nil) }
        defer { handle.closeFile() }

        let sources = ["typed", "queued", "suggestion_accepted"]
            .map { Data("\"promptSource\":\"\($0)\"".utf8) }
        let assistantMarker = Data("\"type\":\"assistant\"".utf8)
        var prompts: [String] = []
        var reply: String?
        func done() -> Bool { prompts.count >= promptLimit && (!wantReply || reply != nil) }

        var pending = Data()
        while true {
            let chunk = handle.readData(ofLength: 1_048_576)
            let atEOF = chunk.isEmpty
            pending.append(chunk)
            // Complete lines only; keep a trailing partial line for the next chunk.
            let end = atEOF ? pending.endIndex : (pending.lastIndex(of: 0x0A).map { pending.index(after: $0) } ?? pending.startIndex)
            let complete = pending[pending.startIndex..<end]
            for line in complete.split(separator: 0x0A, omittingEmptySubsequences: true) {
                let isPrompt = prompts.count < promptLimit && sources.contains(where: { line.range(of: $0) != nil })
                let isReply = wantReply && reply == nil && !prompts.isEmpty && line.range(of: assistantMarker) != nil
                guard isPrompt || isReply,
                      let json = try? JSONSerialization.jsonObject(with: line) as? [String: Any],
                      let role = messageRole(from: json),
                      let content = extractMessageContent(from: json)
                else { continue }
                let trimmed = content.trimmingCharacters(in: .whitespacesAndNewlines)
                if trimmed.isEmpty { continue }

                if isReply, role == "assistant" {
                    reply = String(trimmed.prefix(400))
                } else if isPrompt, role == "user" {
                    if magicLaunchProject(trimmed) != nil || isPassThroughPrompt(trimmed) { continue }
                    if trimmed.hasPrefix("Caveat: The messages below") { continue }  // local-command caveat
                    if trimmed.hasPrefix("[Request interrupted") { continue }        // interrupt sentinel
                    prompts.append(String(trimmed.prefix(300)))
                }
                if done() { return (prompts, reply) }
            }
            if atEOF { return (prompts, reply) }
            pending = Data(pending[end...])
        }
    }

    /// Synthetic user messages that are commands passed through to Claude,
    /// not the user's actual topic — they precede the real prompt in a real
    /// session, so the scan skips past them. Explicit prefix (not a broad
    /// heuristic) so real prompts are never hidden.
    nonisolated private static func isPassThroughPrompt(_ s: String) -> Bool {
        s.hasPrefix("<")  // <command>/<skill>/<local-command-caveat> wrappers
    }

    /// First prompts that mark the whole SESSION as machine-generated — a
    /// programmatic one-shot, not the user's work. The structural sdk-cli
    /// check in classifyHead catches the modern ones; these prefixes cover
    /// transcripts that predate the entrypoint/promptSource fields. Extend
    /// as new probe forms appear.
    nonisolated private static func isMachineFirstPrompt(_ s: String) -> Bool {
        if s.hasPrefix("You select the single most relevant skill") { return true }  // skill-tip catalog selector
        if s.hasPrefix("# Session Ingest") { return true }                           // vault-ingest digest pipeline
        if s.hasPrefix("<!-- === Managed by ClaudeHUD") { return true }              // managed-prompt pipelines
        if s.hasPrefix("Reply with exactly") { return true }                         // liveness probes ("…the word: PONG", "…: SMOKE_OK")
        if s.hasPrefix("Return ONLY this JSON object") { return true }               // remote-control JSON echo probe
        return false
    }

    /// Project name carried by a magic-launch bootstrap, or nil if the message
    /// isn't one. The bootstrap is delivered as the `/vault-bootstrap` slash
    /// command (see `magicLaunchArg` in HUDContentView + the command file at
    /// ~/.claude/commands/vault-bootstrap.md). Handles both ways Claude Code
    /// may record that first turn: the usual `<command-name>/vault-bootstrap
    /// </command-name>…<command-args>…</command-args>` wrapper, and a raw
    /// `/vault-bootstrap <args>` line (fallback). The args are `<project>`
    /// optionally followed by ` :: <resolvedVaultPath>`; the project is the
    /// text before ` :: `. Recognising this lets history relabel these
    /// sessions by project + real prompt instead of the bootstrap boilerplate.
    ///
    /// The wrapper is matched ANYWHERE in the message, not at its start: Claude
    /// Code emits `<command-message>vault-bootstrap</command-message>` on the
    /// line ABOVE `<command-name>`, so a prefix test never fires on a real
    /// transcript (verified against one). That miss was invisible rather than
    /// loud — the message still begins with `<`, so `isPassThroughPrompt`
    /// swallowed it and the session was labelled `.normal` off the user's
    /// second message, which is exactly what recognising it here prevents.
    nonisolated private static func magicLaunchProject(_ s: String) -> String? {
        let args: String
        if let nameTag = s.range(of: "<command-name>/vault-bootstrap</command-name>") {
            guard let open = s.range(of: "<command-args>", range: nameTag.upperBound..<s.endIndex),
                  let close = s.range(of: "</command-args>", range: open.upperBound..<s.endIndex)
            else { return nil }
            args = String(s[open.upperBound..<close.lowerBound])
        } else if s.hasPrefix("/vault-bootstrap") {
            args = String(s.dropFirst("/vault-bootstrap".count))
        } else {
            return nil
        }
        var name = args.trimmingCharacters(in: .whitespacesAndNewlines)
        if let sep = name.range(of: " :: ") { name = String(name[..<sep.lowerBound]) }
        name = name.trimmingCharacters(in: .whitespaces)
        return name.isEmpty ? nil : name
    }

    /// Get the role from a JSONL message line.
    nonisolated fileprivate static func messageRole(from json: [String: Any]) -> String? {
        if let role = json["role"] as? String { return role }
        if let type = json["type"] as? String {
            if type == "human" { return "user" }
            if type == "assistant" { return "assistant" }
        }
        if let msg = json["message"] as? [String: Any],
           let role = msg["role"] as? String { return role }
        return nil
    }

    /// Extract text from content that may be a string or an array of content blocks.
    nonisolated private static func extractTextContent(_ content: Any?) -> String? {
        if let str = content as? String, !str.isEmpty {
            return str
        }
        // Every text block, joined: a message can carry several, and search
        // must see all of them. Tool payloads (tool_use / tool_result) and
        // thinking blocks are not text and are skipped.
        if let blocks = content as? [[String: Any]] {
            let texts = blocks.compactMap { block -> String? in
                guard block["type"] as? String == "text",
                      let text = block["text"] as? String, !text.isEmpty else { return nil }
                return text
            }
            return texts.isEmpty ? nil : texts.joined(separator: "\n")
        }
        return nil
    }
}

// MARK: - Transcript Text

/// THE extraction of a transcript's conversation text: user and assistant
/// text only; tool_use / tool_result payloads, thinking, attachments, and
/// base64 blobs are skipped. Used in-process by the search index, and by
/// vault-ingest.sh through the app binary's `--transcript-text` mode, so the
/// digest and the index read identical text from one implementation.
enum TranscriptText {
    private static let textBlockMarker = Data("\"type\":\"text\"".utf8)
    private static let stringContentMarker = Data("\"content\":\"".utf8)

    /// Visit each user/assistant text message in complete JSONL lines.
    static func forEachMessage<D: DataProtocol>(in data: D, _ body: (_ role: String, _ text: String) -> Void)
        where D.SubSequence == D {
        for line in data.split(separator: 0x0A, omittingEmptySubsequences: true) {
            let bytes = Data(line)
            // Cheap byte pre-filter: skip records with no text content
            // (tool results, progress, snapshots) before JSON parsing.
            guard bytes.range(of: textBlockMarker) != nil || bytes.range(of: stringContentMarker) != nil,
                  let json = try? JSONSerialization.jsonObject(with: bytes) as? [String: Any],
                  let role = SessionHistoryService.messageRole(from: json),
                  role == "user" || role == "assistant",
                  let text = SessionHistoryService.extractMessageContent(from: json)?
                    .trimmingCharacters(in: .whitespacesAndNewlines),
                  !text.isEmpty
            else { continue }
            body(role, text)
        }
    }

    /// The conversation as plain text for a model, capped at `maxChars`
    /// (a token-safe budget: text runs ~4 chars per token). Over the cap it
    /// keeps the opening (intent) and the ending (outcome) and elides the
    /// middle, marking the cut.
    static func conversation(atPath path: String, maxChars: Int) -> String? {
        guard let data = FileManager.default.contents(atPath: path) else { return nil }
        var parts: [String] = []
        forEachMessage(in: data) { role, text in
            parts.append("[\(role == "user" ? "User" : "Assistant")]\n\(text)")
        }
        let full = parts.joined(separator: "\n\n")
        guard full.count > maxChars else { return full }
        let headCount = maxChars * 3 / 10
        let tailCount = maxChars - headCount
        let elided = full.count - maxChars
        return String(full.prefix(headCount))
            + "\n\n[... \(elided) characters of mid-session conversation elided ...]\n\n"
            + String(full.suffix(tailCount))
    }
}

// MARK: - Session Titler

/// The one session-title generator. For a listed session with no sidecar
/// title, feeds a cheap Haiku call the conversation's opening (the first few
/// real user prompts plus a little of the first reply) and writes the result
/// to ~/.claude/hud/session-titles/<id>.txt, the label source the scan reads.
/// Transcripts are only read, never modified.
///
/// Cost control: only untitled sessions; a session is titled once it has
/// three real prompts or has been idle for 30 minutes (a one-word opener like
/// "yes" alone makes a poor title); calls run sequentially with a pause
/// between them and a cap per pass; a failed session is not retried until the
/// next launch.
actor SessionTitler {
    private static let titlesDir = "\(NSHomeDirectory())/.claude/hud/session-titles"
    private static let claudePath = "\(NSHomeDirectory())/.local/bin/claude"
    private static let perPass = 25
    private static let settleAge: TimeInterval = 30 * 60
    private var attempted = Set<String>()

    func titleUntitled(_ candidates: [(id: String, path: String, modified: Date)],
                       onTitle: (String, String) async -> Void) async {
        guard FileManager.default.isExecutableFile(atPath: Self.claudePath) else { return }
        var calls = 0
        for c in candidates where !attempted.contains(c.id) {
            if calls >= Self.perPass || Task.isCancelled { break }
            let sidecar = "\(Self.titlesDir)/\(c.id).txt"
            if FileManager.default.fileExists(atPath: sidecar) { continue }

            let opening = SessionHistoryService.conversationOpening(in: c.path, promptLimit: 5, wantReply: true)
            guard !opening.prompts.isEmpty else { continue }
            let settled = Date().timeIntervalSince(c.modified) > Self.settleAge
            guard settled || opening.prompts.count >= 3 else { continue }

            attempted.insert(c.id)
            calls += 1
            guard let title = await Self.generate(prompts: opening.prompts, reply: opening.reply) else {
                logger.error("session title: generation failed for \(c.id, privacy: .public)")
                continue
            }
            Self.writeSidecar(id: c.id, title: title)
            await onTitle(c.id, title)
            try? await Task.sleep(nanoseconds: 1_000_000_000)
        }
        if calls > 0 { logger.info("session titles: \(calls, privacy: .public) generated") }
    }

    private static func generate(prompts: [String], reply: String?) async -> String? {
        var prompt = """
            Write a title for this chat session so its owner can find it later in a list. \
            Name the concrete topic or task in 3 to 8 words, sentence case, no quotes, \
            no trailing period. Reply with the title only.

            The person's opening messages:
            """
        for (i, p) in prompts.enumerated() { prompt += "\n\(i + 1). \(p)" }
        if let reply { prompt += "\n\nStart of the assistant's first reply:\n\(reply)" }

        return await withCheckedContinuation { cont in
            DispatchQueue.global(qos: .utility).async {
                let process = Process()
                process.executableURL = URL(fileURLWithPath: claudePath)
                process.arguments = ["-p", "--model", "haiku", "--strict-mcp-config",
                                     "--tools", "", "--no-session-persistence", prompt]
                process.currentDirectoryURL = URL(fileURLWithPath: NSTemporaryDirectory())
                var env = ProcessInfo.processInfo.environment
                env["VAULT_INGEST"] = "1"  // the ingest hook's loop guard: never digest this call
                env.removeValue(forKey: "CLAUDECODE")
                process.environment = env
                let out = Pipe()
                process.standardOutput = out
                process.standardError = Pipe()
                do { try process.run() } catch { cont.resume(returning: nil); return }
                let timer = DispatchWorkItem { if process.isRunning { process.terminate() } }
                DispatchQueue.global().asyncAfter(deadline: .now() + 90, execute: timer)
                let data = out.fileHandleForReading.readDataToEndOfFile()
                process.waitUntilExit()
                timer.cancel()
                guard process.terminationStatus == 0,
                      let text = String(data: data, encoding: .utf8) else {
                    cont.resume(returning: nil); return
                }
                cont.resume(returning: sanitize(text))
            }
        }
    }

    private static func sanitize(_ raw: String) -> String? {
        guard let line = raw.split(whereSeparator: \.isNewline)
            .map({ $0.trimmingCharacters(in: .whitespaces) })
            .first(where: { !$0.isEmpty }) else { return nil }
        let t = line.trimmingCharacters(in: CharacterSet(charactersIn: "\"'`*#_ ."))
        guard !t.isEmpty, t.count <= 120 else { return nil }
        return String(t.prefix(90))
    }

    private static func writeSidecar(id: String, title: String) {
        let fm = FileManager.default
        try? fm.createDirectory(atPath: titlesDir, withIntermediateDirectories: true)
        let tmp = "\(titlesDir)/.tmp.\(id)"
        guard (try? (title + "\n").write(toFile: tmp, atomically: false, encoding: .utf8)) != nil else { return }
        _ = try? fm.replaceItemAt(URL(fileURLWithPath: "\(titlesDir)/\(id).txt"), withItemAt: URL(fileURLWithPath: tmp))
        if fm.fileExists(atPath: tmp) { try? fm.moveItem(atPath: tmp, toPath: "\(titlesDir)/\(id).txt") }
    }
}

// MARK: - Transcript Index

/// A transcript's cached listing verdict, valid while the file's mtime and
/// size are unchanged. A machine one-shot is never listed; a listed session
/// with no `label` (no real user turn in its head) shows only when a digest
/// sidecar titles it.
struct CachedHead {
    enum Kind: String { case machine, listed }
    let mtime: Double
    let size: Int64
    let kind: Kind
    let label: String?
}

/// Persistent session store in Application Support: the cached head verdicts
/// that make the session scan cheap, and an incremental full-text index of
/// listed session transcripts:
/// SQLite FTS5 in Application Support. Only user and assistant TEXT is
/// indexed (tool payloads, tool results, and thinking blocks are skipped), so
/// base64 blobs and file dumps cannot produce false hits. Transcripts are
/// append-only JSONL, so a grown file is read from the last indexed line
/// boundary; a shrunk or rewritten file is reindexed from zero.
///
/// All SQLite access runs on one private serial queue, never on the Swift
/// concurrency pool or the main actor: callers await a continuation. `update`
/// takes the queue once per file, so a search issued mid-build waits at most
/// one file.
final class TranscriptIndex: @unchecked Sendable {
    private let queue = DispatchQueue(label: "com.claudehud.transcript-index", qos: .utility)
    private var db: OpaquePointer?
    /// Bump when the schema or the extraction rule changes: a mismatch drops
    /// and rebuilds the index.
    private static let schemaVersion: Int32 = 3
    private static let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

    init() {
        queue.sync { openDatabase() }
    }

    deinit {
        if let db { sqlite3_close(db) }
    }

    // MARK: Public API

    /// Index every listed session's new bytes and drop sessions no longer
    /// listed (deleted, or reclassified as machine one-shots).
    func update(files: [(id: String, path: String)]) async {
        guard !files.isEmpty else { return }  // a failed scan must not wipe the index
        let started = Date()
        let listed = Set(files.map(\.id))
        await onQueue { self.pruneUnlisted(listed) }
        var changed = 0
        for f in files {
            if await onQueue({ self.indexFile(id: f.id, path: f.path) }) { changed += 1 }
        }
        let ms = Int(Date().timeIntervalSince(started) * 1000)
        logger.info("transcript index: \(changed, privacy: .public)/\(files.count, privacy: .public) files updated in \(ms, privacy: .public) ms")
    }

    /// Sessions whose text matches every query token (prefix match), each
    /// with a snippet around its best-ranked matching message.
    func search(_ query: String) async -> [String: SessionSearchResult] {
        let tokens = query.lowercased()
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { !$0.isEmpty }
        guard !tokens.isEmpty else { return [:] }
        let match = tokens.map { "\"\($0)\"*" }.joined(separator: " ")

        return await onQueue(qos: .userInitiated) { self.runSearch(match) }
    }

    func remove(sessionID: String) async {
        await onQueue { self.deleteSession(sessionID) }
    }

    /// Every cached head verdict, keyed by transcript path.
    func loadHeads() async -> [String: CachedHead] {
        await onQueue(qos: .userInitiated) {
            var out: [String: CachedHead] = [:]
            guard let stmt = self.prepare("SELECT path, mtime, size, kind, label FROM heads") else { return out }
            defer { sqlite3_finalize(stmt) }
            while sqlite3_step(stmt) == SQLITE_ROW {
                guard let p = sqlite3_column_text(stmt, 0), let k = sqlite3_column_text(stmt, 3),
                      let kind = CachedHead.Kind(rawValue: String(cString: k)) else { continue }
                out[String(cString: p)] = CachedHead(
                    mtime: sqlite3_column_double(stmt, 1),
                    size: sqlite3_column_int64(stmt, 2),
                    kind: kind,
                    label: sqlite3_column_text(stmt, 4).map { String(cString: $0) })
            }
            return out
        }
    }

    func saveHeads(changed: [String: CachedHead], removed: [String]) async {
        guard !changed.isEmpty || !removed.isEmpty else { return }
        await onQueue {
            self.exec("BEGIN")
            if let upsert = self.prepare("INSERT OR REPLACE INTO heads(path, mtime, size, kind, label) VALUES(?, ?, ?, ?, ?)") {
                for (path, h) in changed {
                    sqlite3_reset(upsert)
                    self.bind(upsert, 1, path)
                    sqlite3_bind_double(upsert, 2, h.mtime)
                    sqlite3_bind_int64(upsert, 3, h.size)
                    self.bind(upsert, 4, h.kind.rawValue)
                    if let t = h.label { self.bind(upsert, 5, t) } else { sqlite3_bind_null(upsert, 5) }
                    sqlite3_step(upsert)
                }
                sqlite3_finalize(upsert)
            }
            if let delete = self.prepare("DELETE FROM heads WHERE path = ?") {
                for path in removed {
                    sqlite3_reset(delete)
                    self.bind(delete, 1, path)
                    sqlite3_step(delete)
                }
                sqlite3_finalize(delete)
            }
            self.exec("COMMIT")
        }
    }

    /// Run `work` on the index queue and await its result without holding a
    /// concurrency-pool thread.
    private func onQueue<T>(qos: DispatchQoS = .utility, _ work: @escaping () -> T) async -> T {
        await withCheckedContinuation { cont in
            queue.async(qos: qos) { cont.resume(returning: work()) }
        }
    }

    // MARK: Search (queue-confined)

    private func runSearch(_ match: String) -> [String: SessionSearchResult] {
        guard db != nil else { return [:] }
        var ids: [String] = []
        if let stmt = prepare("SELECT DISTINCT session_id FROM messages WHERE messages MATCH ?") {
            bind(stmt, 1, match)
            while sqlite3_step(stmt) == SQLITE_ROW {
                if let c = sqlite3_column_text(stmt, 0) { ids.append(String(cString: c)) }
            }
            sqlite3_finalize(stmt)
        }
        var out: [String: SessionSearchResult] = [:]
        guard let stmt = prepare("""
            SELECT snippet(messages, 1, '', '', '…', 14) FROM messages
            WHERE messages MATCH ? AND session_id = ? ORDER BY rank LIMIT 1
            """) else { return out }
        defer { sqlite3_finalize(stmt) }
        for id in ids {
            sqlite3_reset(stmt)
            bind(stmt, 1, match)
            bind(stmt, 2, id)
            var snippet = ""
            if sqlite3_step(stmt) == SQLITE_ROW, let c = sqlite3_column_text(stmt, 0) {
                snippet = String(cString: c)
                    .replacingOccurrences(of: "\n", with: " ")
                    .trimmingCharacters(in: .whitespaces)
            }
            out[id] = SessionSearchResult(id: id, snippet: snippet)
        }
        return out
    }

    // MARK: Schema

    private func openDatabase() {
        let fm = FileManager.default
        guard let support = fm.urls(for: .applicationSupportDirectory, in: .userDomainMask).first else { return }
        let dir = support.appendingPathComponent("ClaudeHUD", isDirectory: true)
        try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
        let path = dir.appendingPathComponent("transcript-index.sqlite").path
        guard sqlite3_open(path, &db) == SQLITE_OK else {
            logger.error("transcript index: cannot open \(path, privacy: .public)")
            if let db { sqlite3_close(db) }
            db = nil
            return
        }
        exec("PRAGMA journal_mode=WAL")
        exec("PRAGMA synchronous=NORMAL")

        var version: Int32 = 0
        if let stmt = prepare("PRAGMA user_version") {
            if sqlite3_step(stmt) == SQLITE_ROW { version = sqlite3_column_int(stmt, 0) }
            sqlite3_finalize(stmt)
        }
        guard version != Self.schemaVersion else { return }
        exec("DROP TABLE IF EXISTS heads")
        exec("DROP TABLE IF EXISTS files")
        exec("DROP TABLE IF EXISTS messages")
        exec("""
            CREATE TABLE heads(
                path TEXT PRIMARY KEY,
                mtime REAL NOT NULL,
                size INTEGER NOT NULL,
                kind TEXT NOT NULL,
                label TEXT)
            """)
        exec("""
            CREATE TABLE files(
                session_id TEXT PRIMARY KEY,
                mtime REAL NOT NULL,
                indexed_bytes INTEGER NOT NULL)
            """)
        exec("""
            CREATE VIRTUAL TABLE messages USING fts5(
                session_id UNINDEXED, body,
                tokenize = 'unicode61 remove_diacritics 2')
            """)
        exec("PRAGMA user_version = \(Self.schemaVersion)")
    }

    // MARK: Indexing (queue-confined)

    private func pruneUnlisted(_ listed: Set<String>) {
        var stale: [String] = []
        if let stmt = prepare("SELECT session_id FROM files") {
            while sqlite3_step(stmt) == SQLITE_ROW {
                if let c = sqlite3_column_text(stmt, 0) {
                    let id = String(cString: c)
                    if !listed.contains(id) { stale.append(id) }
                }
            }
            sqlite3_finalize(stmt)
        }
        guard !stale.isEmpty else { return }
        exec("BEGIN")
        for id in stale { deleteSession(id) }
        exec("COMMIT")
    }

    private func deleteSession(_ id: String) {
        for sql in ["DELETE FROM messages WHERE session_id = ?", "DELETE FROM files WHERE session_id = ?"] {
            if let stmt = prepare(sql) {
                bind(stmt, 1, id)
                sqlite3_step(stmt)
                sqlite3_finalize(stmt)
            }
        }
    }

    /// Index a file's unseen complete lines. Returns false when unchanged.
    @discardableResult
    private func indexFile(id: String, path: String) -> Bool {
        guard db != nil,
              let attrs = try? FileManager.default.attributesOfItem(atPath: path),
              let size = (attrs[.size] as? NSNumber)?.int64Value,
              let mtime = (attrs[.modificationDate] as? Date)?.timeIntervalSince1970
        else { return false }

        var from: Int64 = 0
        var reset = false
        if let stmt = prepare("SELECT mtime, indexed_bytes FROM files WHERE session_id = ?") {
            bind(stmt, 1, id)
            if sqlite3_step(stmt) == SQLITE_ROW {
                let storedMtime = sqlite3_column_double(stmt, 0)
                let storedBytes = sqlite3_column_int64(stmt, 1)
                if storedMtime == mtime && storedBytes <= size {
                    sqlite3_finalize(stmt)
                    return false  // unchanged
                }
                if size >= storedBytes { from = storedBytes } else { reset = true }
            }
            sqlite3_finalize(stmt)
        }

        guard let handle = FileHandle(forReadingAtPath: path) else { return false }
        defer { handle.closeFile() }
        handle.seek(toFileOffset: UInt64(from))
        let data = handle.readDataToEndOfFile()

        // Only complete lines: a transcript being written may end mid-record.
        let consumed: Int
        if let nl = data.lastIndex(of: 0x0A) {
            consumed = data.distance(from: data.startIndex, to: nl) + 1
        } else {
            consumed = 0
        }

        exec("BEGIN")
        if reset { deleteSession(id) }
        if consumed > 0, let insert = prepare("INSERT INTO messages(session_id, body) VALUES(?, ?)") {
            TranscriptText.forEachMessage(in: data.prefix(consumed)) { _, text in
                sqlite3_reset(insert)
                bind(insert, 1, id)
                bind(insert, 2, text)
                sqlite3_step(insert)
            }
            sqlite3_finalize(insert)
        }
        if let upsert = prepare("""
            INSERT INTO files(session_id, mtime, indexed_bytes) VALUES(?, ?, ?)
            ON CONFLICT(session_id) DO UPDATE SET mtime = excluded.mtime, indexed_bytes = excluded.indexed_bytes
            """) {
            bind(upsert, 1, id)
            sqlite3_bind_double(upsert, 2, mtime)
            sqlite3_bind_int64(upsert, 3, from + Int64(consumed))
            sqlite3_step(upsert)
            sqlite3_finalize(upsert)
        }
        exec("COMMIT")
        return true
    }


    // MARK: SQLite helpers

    private func exec(_ sql: String) {
        guard let db else { return }
        if sqlite3_exec(db, sql, nil, nil, nil) != SQLITE_OK {
            logger.error("transcript index: \(String(cString: sqlite3_errmsg(db)), privacy: .public)")
        }
    }

    private func prepare(_ sql: String) -> OpaquePointer? {
        guard let db else { return nil }
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
            logger.error("transcript index: \(String(cString: sqlite3_errmsg(db)), privacy: .public)")
            return nil
        }
        return stmt
    }

    private func bind(_ stmt: OpaquePointer, _ index: Int32, _ text: String) {
        sqlite3_bind_text(stmt, index, text, -1, Self.transient)
    }
}

// MARK: - Relative Date Formatting

extension Date {
    /// Shared formatter for week-plus-old dates. `DateFormatter` instantiation is
    /// expensive (ICU/locale setup); `relativeString` is read by every row in the
    /// Projects and Sessions lists, so allocating one per call made scrolling
    /// beach-ball as `LazyVStack` realized rows. A configured `DateFormatter` is
    /// safe to share for read-only formatting across threads.
    private static let monthDayFormatter: DateFormatter = {
        let fmt = DateFormatter()
        fmt.dateFormat = "MMM d"
        return fmt
    }()

    var relativeString: String {
        let diff = Date().timeIntervalSince(self)
        if diff < 60 { return "just now" }
        if diff < 3600 { return "\(Int(diff / 60))m ago" }
        if diff < 86400 { return "\(Int(diff / 3600))h ago" }
        if diff < 604800 { return "\(Int(diff / 86400))d ago" }
        return Self.monthDayFormatter.string(from: self)
    }
}
