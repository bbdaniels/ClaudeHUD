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

    /// Returns variants of a path component with dashes replaced by underscore / dot.
    nonisolated private static func componentVariants(_ component: String) -> [String] {
        guard component.contains("-") else { return [component] }
        return [
            component,
            component.replacingOccurrences(of: "-", with: "_"),
            component.replacingOccurrences(of: "-", with: "."),
        ]
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
