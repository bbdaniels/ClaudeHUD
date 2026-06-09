import AppKit
import Foundation
import os

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

    func refresh() async {
        isLoading = true
        defer { isLoading = false }

        let result = await Task.detached(priority: .userInitiated) { [claudeProjectsDir] in
            Self.scanSessions(in: claudeProjectsDir)
        }.value

        sessions = result
    }

    /// Full-text search across all session files. Binary pre-filter then targeted parse.
    func search(query: String) {
        searchTask?.cancel()
        searchResults = [:]

        guard !query.isEmpty else {
            isSearching = false
            return
        }

        isSearching = true
        let sessions = self.sessions
        let q = query

        searchTask = Task { [weak self] in
            // Concurrent search with progressive results
            await withTaskGroup(of: (String, SessionSearchResult)?.self) { group in
                for session in sessions {
                    group.addTask {
                        // Phase 1: binary pre-filter — check raw bytes, no JSON parsing
                        guard let data = try? Data(contentsOf: URL(fileURLWithPath: session.filePath)) else { return nil }
                        guard let raw = String(data: data, encoding: .utf8) else { return nil }
                        guard raw.range(of: q, options: .caseInsensitive) != nil else { return nil }

                        // Phase 2: targeted parse — find snippet in actual message content
                        guard let snippet = Self.extractSnippet(from: raw, query: q) else { return nil }
                        return (session.id, SessionSearchResult(id: session.id, snippet: snippet))
                    }
                }

                // Stream results to UI as they arrive
                for await result in group {
                    if Task.isCancelled { return }
                    guard let (id, searchResult) = result else { continue }
                    await MainActor.run { [weak self] in
                        self?.searchResults[id] = searchResult
                    }
                }
            }

            await MainActor.run { [weak self] in
                guard let self, !Task.isCancelled else { return }
                self.isSearching = false
            }
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
    }

    // MARK: - Scanning (off main thread)

    nonisolated private static func scanSessions(in baseDir: String) -> [SessionInfo] {
        let fm = FileManager.default
        guard let projectDirs = try? fm.contentsOfDirectory(atPath: baseDir) else { return [] }

        // Close-out titles written by the vault-ingest pipeline at SessionEnd
        // (see loadSidecarTitles). When present they ARE the label — they
        // summarize what the session accomplished, which Claude Code's
        // ai-title never captures for magic-launched sessions.
        let sidecarTitles = loadSidecarTitles()

        var found: [SessionInfo] = []

        for dir in projectDirs {
            let dirPath = "\(baseDir)/\(dir)"
            var isDir: ObjCBool = false
            guard fm.fileExists(atPath: dirPath, isDirectory: &isDir), isDir.boolValue else { continue }

            let (projectPath, projectName) = decodeProjectDir(dir)

            guard let files = try? fm.contentsOfDirectory(atPath: dirPath) else { continue }

            for file in files where file.hasSuffix(".jsonl") {
                let filePath = "\(dirPath)/\(file)"
                let sessionId = String(file.dropLast(6)) // remove .jsonl

                guard let attrs = try? fm.attributesOfItem(atPath: filePath),
                      let modDate = attrs[.modificationDate] as? Date else { continue }

                // Classify every session from its transcript head FIRST — even
                // when a digest sidecar exists. Sidecars used to win outright,
                // which let machine one-shots that slipped past the digest's
                // NO_DURABLE_CONTENT rule surface in history under a plausible
                // title (Haiku digested a skill-selector query as real work:
                // "Skill-selection query re: patient risk scoring"). The 16 KB
                // head read is cheap and off the main thread.
                guard let head = classifyHead(from: filePath) else { continue }

                let preview: String
                if let title = sidecarTitles[sessionId] {
                    // Ingested, substantive session: the close-out digest title
                    // wins. Strip a leading "<project>: " — the list is already
                    // grouped under the project, and sidecars written before the
                    // ingest prompt's no-project-name title rule carry the
                    // prefix forever otherwise.
                    preview = stripProjectPrefix(title, projectName: projectName)
                } else {
                    switch head {
                    case .normal(let firstPrompt):
                        preview = firstPrompt
                    case .magicLaunch(let project):
                        // Claude Code's ai-title is generated from the opening
                        // turn and FROZEN, and every magic-launched session
                        // opens with the same bootstrap boilerplate — so its
                        // ai-title is always junk ("context load", "obsidian
                        // estonia-ecm project") no matter the work that
                        // followed. Label with the user's first real prompt
                        // instead; until one exists, a short project tag.
                        preview = firstRealPrompt(in: filePath) ?? "Vault session: \(project)"
                    }
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

        return found.sorted { $0.timestamp > $1.timestamp }
    }

    /// Close-out session titles written by the vault-ingest pipeline at
    /// SessionEnd (vault-ingest.sh → write_title_sidecar): the digest's
    /// "## <date> — <title>" heading, keyed by session id under
    /// ~/.claude/hud/session-titles/<id>.txt. These summarize what a session
    /// ACCOMPLISHED — far better than Claude Code's ai-title, which is
    /// generated from the opening turn and freezes at "context load" for every
    /// magic-launched vault session. Loaded once per scan; absent for
    /// un-ingested sessions, which fall back to readPreview (ai-title / first
    /// prompt). A sidecar is a LABEL, not a listing decision — machine
    /// one-shots are dropped by classifyHead even when a stray digest gave
    /// them a sidecar.
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
    /// list is already grouped under it), but sidecars written before the
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

    // MARK: - Snippet Extraction (for search results)

    /// Extract a snippet from raw JSONL text around the first message content match.
    nonisolated private static func extractSnippet(from raw: String, query: String) -> String? {
        for line in raw.components(separatedBy: "\n") {
            guard !line.isEmpty,
                  let lineData = line.data(using: .utf8),
                  let json = try? JSONSerialization.jsonObject(with: lineData) as? [String: Any]
            else { continue }

            let content = extractMessageContent(from: json)
            guard let content, !content.isEmpty else { continue }
            guard content.localizedCaseInsensitiveContains(query) else { continue }

            // Found a match — build snippet
            let lower = content.lowercased()
            let q = query.lowercased()
            guard let range = lower.range(of: q) else { continue }

            let center = lower.distance(from: lower.startIndex, to: range.lowerBound)
            let start = max(0, center - 40)
            let end = min(content.count, center + q.count + 40)
            let startIdx = content.index(content.startIndex, offsetBy: start)
            let endIdx = content.index(content.startIndex, offsetBy: end)
            var snippet = String(content[startIdx..<endIdx])
                .replacingOccurrences(of: "\n", with: " ")
            if start > 0 { snippet = "…" + snippet }
            if end < content.count { snippet += "…" }
            return snippet
        }
        return nil
    }

    /// Extract user/assistant text content from a JSONL line (any format).
    nonisolated private static func extractMessageContent(from json: [String: Any]) -> String? {
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
    /// the first genuine user prompt (preview-ready); `.magicLaunch` carries
    /// the project name parsed from the bootstrap boilerplate.
    private enum HeadClass {
        case normal(String)
        case magicLaunch(String)
    }

    /// Classify a session from the first 16 KB of its transcript, or return
    /// nil for sessions that should never appear in history:
    ///
    ///  * **Machine one-shots** — programmatic `claude -p` runs: skill-tip
    ///    catalog selectors, remote-control liveness probes (PONG /
    ///    SMOKE_OK), the vault-ingest digest pipeline. Detected
    ///    STRUCTURALLY: their first user record carries
    ///    `entrypoint: "sdk-cli"` / `promptSource: "sdk"`, while every kind
    ///    of real session (terminal, VSCode, desktop, magic-launch,
    ///    background job) records "cli"-family entrypoints and typed
    ///    prompts. ~7,000 of these litter ~/.claude/projects vs ~250 real
    ///    sessions. Prompt-prefix checks remain as a fallback for old
    ///    transcripts that predate the two fields.
    ///  * **Abandoned sessions** with no real user turn.
    ///
    /// Mirrors `vault-ingest.sh::is_machine_transcript` (the ingest skips
    /// the same sessions without spending a model call on them).
    nonisolated private static func classifyHead(from path: String) -> HeadClass? {
        guard let handle = FileHandle(forReadingAtPath: path) else { return nil }
        defer { handle.closeFile() }

        let data = handle.readData(ofLength: 16384)
        guard let text = String(data: data, encoding: .utf8) else { return nil }

        for line in text.components(separatedBy: "\n").prefix(50) {
            guard !line.isEmpty,
                  let lineData = line.data(using: .utf8),
                  let json = try? JSONSerialization.jsonObject(with: lineData) as? [String: Any]
            else { continue }

            guard let content = extractMessageContent(from: json),
                  let role = messageRole(from: json), role == "user" else { continue }

            if json["entrypoint"] as? String == "sdk-cli"
                || json["promptSource"] as? String == "sdk" { return nil }

            let trimmed = content.trimmingCharacters(in: .whitespacesAndNewlines)
            // Command/skill wrappers precede the real prompt in real
            // sessions: skip the MESSAGE, keep scanning.
            if trimmed.isEmpty || isPassThroughPrompt(trimmed) { continue }
            // Known machine first-prompts drop the SESSION.
            if isMachineFirstPrompt(trimmed) { return nil }
            if trimmed.hasPrefix(magicLaunchPrefix), let project = magicLaunchProject(trimmed) {
                return .magicLaunch(project)
            }
            return .normal(String(trimmed.prefix(100)))
        }

        return nil
    }

    /// The user's first genuine prompt AFTER the magic-launch bootstrap
    /// message — the session's actual topic. Bootstrap context loading (wiki
    /// reads, tool results) sits between the boilerplate and that prompt, so
    /// this scans a 1 MB window rather than the 16 KB head, but only parses
    /// lines carrying promptSource "typed" — present in every transcript new
    /// enough to be magic-launched. Called only for magic-launch sessions
    /// with no digest sidecar yet (the handful of live ones), so the bigger
    /// read stays off the hot path.
    nonisolated private static func firstRealPrompt(in path: String) -> String? {
        guard let handle = FileHandle(forReadingAtPath: path) else { return nil }
        defer { handle.closeFile() }

        let data = handle.readData(ofLength: 1_048_576)
        // Lenient decode: garbled bytes can only land in a truncated last
        // line, which fails to parse and is skipped.
        let text = String(decoding: data, as: UTF8.self)

        for line in text.components(separatedBy: "\n") {
            guard line.contains("\"promptSource\":\"typed\""),
                  let lineData = line.data(using: .utf8),
                  let json = try? JSONSerialization.jsonObject(with: lineData) as? [String: Any],
                  let role = messageRole(from: json), role == "user",
                  let content = extractMessageContent(from: json)
            else { continue }

            let trimmed = content.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.isEmpty || trimmed.hasPrefix(magicLaunchPrefix) { continue }
            if isPassThroughPrompt(trimmed) { continue }
            if trimmed.hasPrefix("Caveat: The messages below") { continue }  // local-command caveat
            if trimmed.hasPrefix("[Request interrupted") { continue }        // interrupt sentinel
            return String(trimmed.prefix(100))
        }
        return nil
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

    /// Exact opening of the magic-launch vault bootstrap prompt, generated
    /// verbatim by `magicLaunchInGhostty()` in HUDContentView. Recognising it
    /// lets history relabel these sessions with the user's first real prompt
    /// instead of the identical boilerplate. Keep in sync with the template
    /// there.
    nonisolated private static let magicLaunchPrefix = "Fresh session on the Obsidian vault project: "

    /// Project name carried by a magic-launch bootstrap prompt — the text
    /// between `magicLaunchPrefix` and the first period — or nil if absent.
    nonisolated private static func magicLaunchProject(_ s: String) -> String? {
        guard s.hasPrefix(magicLaunchPrefix) else { return nil }
        let rest = s.dropFirst(magicLaunchPrefix.count)
        guard let dot = rest.firstIndex(of: ".") else { return nil }
        let name = rest[..<dot].trimmingCharacters(in: .whitespaces)
        return name.isEmpty ? nil : name
    }

    /// Get the role from a JSONL message line.
    nonisolated private static func messageRole(from json: [String: Any]) -> String? {
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
        if let blocks = content as? [[String: Any]] {
            for block in blocks {
                if block["type"] as? String == "text",
                   let text = block["text"] as? String, !text.isEmpty {
                    return text
                }
            }
        }
        return nil
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
