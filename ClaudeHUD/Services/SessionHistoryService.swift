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
}

// MARK: - Session History Service

@MainActor
class SessionHistoryService: ObservableObject {
    @Published var sessions: [SessionInfo] = []
    @Published var isLoading = false

    private let claudeProjectsDir = "\(NSHomeDirectory())/.claude/projects"

    func refresh() async {
        isLoading = true
        defer { isLoading = false }

        let result = await Task.detached(priority: .userInitiated) { [claudeProjectsDir] in
            Self.scanSessions(in: claudeProjectsDir)
        }.value

        sessions = result
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

                found.append(SessionInfo(
                    id: sessionId,
                    projectPath: projectPath,
                    projectName: projectName,
                    preview: preview,
                    timestamp: modDate
                ))
            }
        }

        return found.sorted { $0.timestamp > $1.timestamp }
    }

    // MARK: - Project Path Decoding

    /// Decode a directory name like `-Users-bbdaniels-GitHub-ClaudeHUD` back to `/Users/bbdaniels/GitHub/ClaudeHUD`.
    /// Handles project names containing dashes by probing the filesystem.
    nonisolated private static func decodeProjectDir(_ dirName: String) -> (path: String, name: String) {
        let fm = FileManager.default
        let home = NSHomeDirectory()
        // "/Users/bbdaniels" → "-Users-bbdaniels"
        let homeEncoded = home.replacingOccurrences(of: "/", with: "-")

        if dirName.hasPrefix(homeEncoded + "-") {
            let remainder = String(dirName.dropFirst(homeEncoded.count + 1))
            let parts = remainder.split(separator: "-").map(String.init)

            // Try joining rightmost segments with dashes to handle names like "claude-push"
            for i in stride(from: parts.count - 1, through: 1, by: -1) {
                let prefix = parts[0..<i].joined(separator: "/")
                let suffix = parts[i...].joined(separator: "-")
                let candidate = "\(home)/\(prefix)/\(suffix)"
                if fm.fileExists(atPath: candidate) {
                    return (candidate, suffix)
                }
            }

            // Simple case: all dashes are slashes
            let simplePath = "\(home)/\(remainder.replacingOccurrences(of: "-", with: "/"))"
            if fm.fileExists(atPath: simplePath) {
                return (simplePath, URL(fileURLWithPath: simplePath).lastPathComponent)
            }

            // Fallback
            return (simplePath, parts.last ?? remainder)
        }

        // Non-home path (e.g. /tmp)
        let path = "/" + String(dirName.dropFirst()).replacingOccurrences(of: "-", with: "/")
        return (path, URL(fileURLWithPath: path).lastPathComponent)
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

            // Format 1: {"role": "user", "content": "..."}
            if let role = json["role"] as? String, role == "user" {
                if let content = extractTextContent(json["content"]) {
                    return String(content.prefix(100))
                }
            }

            // Format 2: {"type": "human", "message": {...}}
            if let type = json["type"] as? String, type == "human" {
                if let msg = json["message"] as? [String: Any],
                   let content = extractTextContent(msg["content"]) {
                    return String(content.prefix(100))
                }
            }

            // Format 3: {"message": {"role": "user", ...}}
            if let msg = json["message"] as? [String: Any],
               let role = msg["role"] as? String, role == "user" {
                if let content = extractTextContent(msg["content"]) {
                    return String(content.prefix(100))
                }
            }
        }

        return "Session"
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
