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

                let preview = readPreview(from: filePath)

                // Skip automated skill-selector invocations — these are Claude Code's
                // internal haiku-model queries that run a skill catalog selector as if
                // it were a user prompt. They clutter the history with identical content.
                if isSkillSelectorPreview(preview) { continue }

                // Skip abandoned sessions that never produced a real user/assistant turn
                // (file contains only queue-operation or file-history-snapshot records).
                if preview == "Session" { continue }

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

    /// Detect Claude Code's internal skill-selector prompts that are logged as user
    /// messages but are not real user input.
    nonisolated private static func isSkillSelectorPreview(_ preview: String) -> Bool {
        preview.hasPrefix("You select the single most relevant skill")
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

    // MARK: - Preview Extraction

    /// Read the first user message from a session JSONL file.
    nonisolated private static func readPreview(from path: String) -> String {
        guard let handle = FileHandle(forReadingAtPath: path) else { return "Session" }
        defer { handle.closeFile() }

        let data = handle.readData(ofLength: 16384)
        guard let text = String(data: data, encoding: .utf8) else { return "Session" }

        for line in text.components(separatedBy: "\n").prefix(50) {
            guard !line.isEmpty,
                  let lineData = line.data(using: .utf8),
                  let json = try? JSONSerialization.jsonObject(with: lineData) as? [String: Any]
            else { continue }

            if let content = extractMessageContent(from: json), let role = messageRole(from: json),
               role == "user" {
                return String(content.prefix(100))
            }
        }

        return "Session"
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
    var relativeString: String {
        let diff = Date().timeIntervalSince(self)
        if diff < 60 { return "just now" }
        if diff < 3600 { return "\(Int(diff / 60))m ago" }
        if diff < 86400 { return "\(Int(diff / 3600))h ago" }
        if diff < 604800 { return "\(Int(diff / 86400))d ago" }
        let fmt = DateFormatter()
        fmt.dateFormat = "MMM d"
        return fmt.string(from: self)
    }
}
