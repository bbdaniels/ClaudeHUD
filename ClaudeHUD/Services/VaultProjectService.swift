import Foundation
import Combine
import os

private let logger = Logger(subsystem: "com.claudehud", category: "VaultProjectService")

/// Lists projects in the Obsidian vault and surfaces their canonical
/// per-project metadata (frontmatter + existence flags + file paths)
/// for the Vault tab. **Eager** on metadata (status, updated, cwds);
/// **lazy** on body content (Tasks.md, Dashboard.md, Technical Notes.md
/// are read on demand when a row expands), so refreshing the whole
/// list doesn't open 30 markdown files unnecessarily.
///
/// Architecture: see Documents/Obsidian/ClaudeHUD/Technical Notes.md
/// §Vault/Projects tab redistribution. The HUD is a window over the
/// archive; this service does no synthesis — every value rendered in
/// the Vault tab is a verbatim slice of a vault file.
@MainActor
final class VaultProjectService: ObservableObject {

    // MARK: - Public types

    struct Project: Identifiable, Hashable {
        var id: URL { folder }
        let folder: URL
        let name: String                  // folder basename
        let status: String                // raw frontmatter value (active, wrapping-up, …)
        let updated: Date?                // parsed from frontmatter `updated:`
        let updatedRaw: String            // raw frontmatter value, for display fallback
        let cwds: [String]                // first non-glob is used by "New session here"
        let hasDashboard: Bool
        let hasTechnicalNotes: Bool
        let hasSessions: Bool
        let hasSessionLog: Bool
        let otherMarkdownFiles: [URL]     // .md files in folder other than the canonical ones

        var tasksPath: URL { folder.appending(path: "Tasks.md") }
        var dashboardPath: URL { folder.appending(path: "Dashboard.md") }
        var technicalNotesPath: URL { folder.appending(path: "Technical Notes.md") }
        var sessionsPath: URL { folder.appending(path: "Sessions.md") }
        var sessionLogPath: URL { folder.appending(path: "Session Log.md") }

        /// First absolute non-glob `cwds:` entry (for "New session here").
        var primaryCwd: String? {
            cwds.first { $0.hasPrefix("/") && !$0.contains("*") }
        }

        /// `updated:` more than 30 days ago + status ∈ {active, wrapping-up}.
        var isStale: Bool {
            guard let updated, status == "active" || status == "wrapping-up" else { return false }
            return Date().timeIntervalSince(updated) > 30 * 24 * 3600
        }

        var isActive: Bool { status == "active" || status == "wrapping-up" }
        var isInactive: Bool { status == "done" || status == "archived" }
    }

    // MARK: - Published state

    @Published private(set) var projects: [Project] = []
    @Published private(set) var lastRefresh: Date = .distantPast

    // MARK: - Configuration

    private(set) var vaultPath: URL?

    /// Filenames the Notes section's "other files" listing excludes
    /// (they have their own dedicated subsections).
    private let canonicalFiles: Set<String> = [
        "Tasks.md", "Dashboard.md", "Technical Notes.md", "Sessions.md", "Session Log.md"
    ]

    // MARK: - Lifecycle

    func start(vaultPath: URL?) {
        self.vaultPath = vaultPath
        refresh()
    }

    /// Re-scan the vault. Call from view `onAppear` or explicitly after
    /// the vault changes. Cheap (just reads frontmatter), so safe.
    func refresh() {
        guard let vault = vaultPath else {
            projects = []
            return
        }
        let folders = (try? FileManager.default.contentsOfDirectory(
            at: vault, includingPropertiesForKeys: [.isDirectoryKey]
        )) ?? []
        var out: [Project] = []
        for folder in folders {
            guard let isDir = try? folder.resourceValues(forKeys: [.isDirectoryKey]).isDirectory, isDir,
                  !folder.lastPathComponent.hasPrefix(".") else { continue }
            if let p = parseProject(folder: folder) { out.append(p) }
        }
        // Sort: active+wrapping-up first (by updated desc), then everything else (by updated desc).
        out.sort { lhs, rhs in
            if lhs.isActive != rhs.isActive { return lhs.isActive }   // active first
            let l = lhs.updated ?? .distantPast
            let r = rhs.updated ?? .distantPast
            return l > r
        }
        projects = out
        lastRefresh = Date()
        logger.info("vault projects refreshed: \(out.count) total, \(out.filter { $0.isActive }.count) active")
    }

    // MARK: - Per-project parse

    private func parseProject(folder: URL) -> Project? {
        let tasks = folder.appending(path: "Tasks.md")
        guard let content = try? String(contentsOf: tasks, encoding: .utf8) else { return nil }
        let fm = parseFrontmatter(content)

        let status = fm["status"] ?? "unknown"
        let updatedRaw = fm["updated"] ?? ""
        let updated = ISO8601DateFormatter.dateOnly.date(from: updatedRaw)
            ?? DateFormatter.iso8601Date.date(from: updatedRaw)
        let cwds = parseFrontmatterList(content, key: "cwds")

        let dirContents = (try? FileManager.default.contentsOfDirectory(
            at: folder, includingPropertiesForKeys: nil
        )) ?? []
        let mdFiles = dirContents.filter { $0.pathExtension == "md" }
        let canonical = canonicalFiles
        let others = mdFiles.filter { !canonical.contains($0.lastPathComponent) }

        return Project(
            folder: folder,
            name: folder.lastPathComponent,
            status: status,
            updated: updated,
            updatedRaw: updatedRaw,
            cwds: cwds,
            hasDashboard: mdFiles.contains { $0.lastPathComponent == "Dashboard.md" },
            hasTechnicalNotes: mdFiles.contains { $0.lastPathComponent == "Technical Notes.md" },
            hasSessions: mdFiles.contains { $0.lastPathComponent == "Sessions.md" },
            hasSessionLog: mdFiles.contains { $0.lastPathComponent == "Session Log.md" },
            otherMarkdownFiles: others.sorted { $0.lastPathComponent < $1.lastPathComponent }
        )
    }

    // MARK: - Frontmatter (top-level scalars)

    private func parseFrontmatter(_ content: String) -> [String: String] {
        guard content.hasPrefix("---\n") else { return [:] }
        let body = String(content.dropFirst(4))
        guard let end = body.range(of: "\n---\n") else { return [:] }
        let block = String(body[..<end.lowerBound])
        var out: [String: String] = [:]
        for line in block.components(separatedBy: "\n") {
            // Top-level scalar: starts non-whitespace, contains `:`, value after `:`.
            // Skip lines that begin with whitespace (list items) and lines without `:`.
            guard !line.isEmpty, !line.hasPrefix(" "), !line.hasPrefix("\t") else { continue }
            guard let colon = line.firstIndex(of: ":") else { continue }
            let key = String(line[..<colon]).trimmingCharacters(in: .whitespaces)
            let val = String(line[line.index(after: colon)...]).trimmingCharacters(in: .whitespaces)
            if !key.isEmpty { out[key] = val }
        }
        return out
    }

    /// Parse a YAML-list value under a given key, e.g.
    /// `cwds:`
    /// `  - /Users/bbdaniels/Projects/ClaudeHUD`
    /// Returns the bare strings (quotes stripped).
    private func parseFrontmatterList(_ content: String, key: String) -> [String] {
        guard content.hasPrefix("---\n") else { return [] }
        let body = String(content.dropFirst(4))
        guard let end = body.range(of: "\n---\n") else { return [] }
        let block = String(body[..<end.lowerBound])
        var collecting = false
        var out: [String] = []
        for line in block.components(separatedBy: "\n") {
            // Begin collecting when we see `<key>:` at top level.
            if !collecting, !line.hasPrefix(" "), !line.hasPrefix("\t"),
               line.hasPrefix("\(key):") || line == "\(key):" {
                collecting = true
                // Inline scalar form (`key: [a, b]` or `key: ~`) is not list-shaped.
                let after = String(line.dropFirst("\(key):".count)).trimmingCharacters(in: .whitespaces)
                if !after.isEmpty && after != "~" && after != "[]" {
                    // Non-list value on the same line; ignore for list parsing.
                    collecting = false
                }
                continue
            }
            if collecting {
                // A new top-level key ends the list.
                if !line.isEmpty, !line.hasPrefix(" "), !line.hasPrefix("\t") {
                    collecting = false
                    continue
                }
                let trimmed = line.trimmingCharacters(in: .whitespaces)
                if trimmed.hasPrefix("- ") {
                    let v = trimmed.dropFirst(2).trimmingCharacters(in: CharacterSet(charactersIn: "'\""))
                    out.append(String(v))
                }
            }
        }
        return out
    }

    // MARK: - ActiveTask model

    /// A top-level entry in a `## Active` block. Title is the bold portion
    /// of `- **Title**:`; body is the rest of the bullet (continuation lines
    /// joined); sub-bullets are the nested `  - …` items, each with their
    /// own continuation text already joined.
    struct ActiveTask: Identifiable, Hashable {
        let id = UUID()
        let title: String
        let body: String
        let subBullets: [String]
        let isDone: Bool

        func hash(into hasher: inout Hasher) { hasher.combine(id) }
        static func == (lhs: ActiveTask, rhs: ActiveTask) -> Bool { lhs.id == rhs.id }
    }

    // MARK: - Lazy parsers (called by views when expanded)

    /// Drop a leading YAML frontmatter block, if any.
    static func stripFrontmatter(_ content: String) -> String {
        guard content.hasPrefix("---\n") else { return content }
        let body = String(content.dropFirst(4))
        guard let end = body.range(of: "\n---\n") else { return content }
        return String(body[end.upperBound...]).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Prose between `# <H1>` and the next `## ` heading. The H1 is what
    /// `Tasks.md` always opens with (`# <Project> Tasks`); the preamble
    /// after it is the user-authored project description. Returns nil
    /// if no preamble is present. Source-markdown soft line breaks (≤80
    /// char wrapping) are reflowed to spaces; blank lines preserved as
    /// paragraph separators, so the rendered text wraps to the panel
    /// width instead of the markdown source width.
    static func extractPreamble(from content: String) -> String? {
        let stripped = stripFrontmatter(content)
        var inPreamble = false
        var collected: [String] = []
        for line in stripped.components(separatedBy: "\n") {
            if !inPreamble {
                if line.hasPrefix("# ") { inPreamble = true }
                continue
            }
            if line.hasPrefix("## ") { break }
            collected.append(line)
        }
        let result = reflowProse(collected)
        return result.isEmpty ? nil : result
    }

    /// First non-empty paragraph of a markdown string. Skips frontmatter
    /// and any leading headings; "paragraph" = first run of consecutive
    /// non-empty lines, reflowed to a single line.
    static func extractFirstParagraph(from content: String) -> String? {
        let stripped = stripFrontmatter(content)
        var collected: [String] = []
        for line in stripped.components(separatedBy: "\n") {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if collected.isEmpty {
                if trimmed.isEmpty || trimmed.hasPrefix("#") { continue }
                collected.append(line)
            } else {
                if trimmed.isEmpty { break }
                collected.append(line)
            }
        }
        let result = reflowProse(collected)
        return result.isEmpty ? nil : result
    }

    /// Join consecutive non-empty lines with a single space; preserve
    /// blank lines as paragraph breaks (`\n\n`). Markdown convention:
    /// a single newline inside a paragraph is a soft break (= space).
    private static func reflowProse(_ lines: [String]) -> String {
        var paragraphs: [[String]] = [[]]
        for line in lines {
            if line.trimmingCharacters(in: .whitespaces).isEmpty {
                if !paragraphs[paragraphs.count - 1].isEmpty {
                    paragraphs.append([])
                }
            } else {
                paragraphs[paragraphs.count - 1]
                    .append(line.trimmingCharacters(in: .whitespaces))
            }
        }
        return paragraphs
            .filter { !$0.isEmpty }
            .map { $0.joined(separator: " ") }
            .joined(separator: "\n\n")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Pull out the body between a `## <heading>` line and the next `## ` line.
    /// Returns nil if the section isn't present.
    static func extractSection(named heading: String, from content: String) -> String? {
        let prefix = "## \(heading)"
        var inSection = false
        var collected: [String] = []
        for line in content.components(separatedBy: "\n") {
            if !inSection {
                if line.trimmingCharacters(in: .whitespaces) == prefix
                    || line.hasPrefix(prefix + " ") {
                    inSection = true
                }
                continue
            }
            if line.hasPrefix("## ") { break }
            collected.append(line)
        }
        guard inSection else { return nil }
        return collected.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Parse `## Active` into structured tasks. Top-level `- **Title**:`
    /// starts a task; lines indented ≥ 2 spaces that begin with `- ` are
    /// sub-bullets; other indented lines are continuation text. Multi-line
    /// continuation joins with a space.
    static func parseActiveTasks(from content: String) -> [ActiveTask] {
        guard let block = extractSection(named: "Active", from: content) else { return [] }

        var tasks: [ActiveTask] = []
        var title: String? = nil
        var bodyParts: [String] = []
        var subBullets: [String] = []
        var pendingSub: String? = nil
        var pendingSubCont: [String] = []

        func flushSub() {
            guard let s = pendingSub else { return }
            let cont = pendingSubCont.joined(separator: " ").trimmingCharacters(in: .whitespaces)
            subBullets.append(cont.isEmpty ? s : "\(s) \(cont)")
            pendingSub = nil
            pendingSubCont = []
        }

        func flushTask() {
            flushSub()
            guard let t = title else { return }
            let body = bodyParts.joined(separator: " ").trimmingCharacters(in: .whitespaces)
            let combined = t + " " + body + " " + subBullets.joined(separator: " ")
            let isDone = combined.contains("✅") || combined.contains(" DONE ") || combined.hasSuffix(" DONE")
            tasks.append(ActiveTask(title: t, body: body, subBullets: subBullets, isDone: isDone))
            title = nil
            bodyParts = []
            subBullets = []
        }

        let topPattern = try? NSRegularExpression(pattern: #"^- \*\*(.+?)\*\*:?\s*(.*)$"#)
        let subPattern = try? NSRegularExpression(pattern: #"^\s{2,}- (.*)$"#)
        let contPattern = try? NSRegularExpression(pattern: #"^\s{2,}(.+)$"#)

        for line in block.components(separatedBy: "\n") {
            let ns = line as NSString
            let range = NSRange(location: 0, length: ns.length)

            if let m = topPattern?.firstMatch(in: line, range: range), m.numberOfRanges >= 3 {
                flushTask()
                title = ns.substring(with: m.range(at: 1)).trimmingCharacters(in: .whitespaces)
                let rest = ns.substring(with: m.range(at: 2)).trimmingCharacters(in: .whitespaces)
                if !rest.isEmpty { bodyParts.append(rest) }
                continue
            }
            if let m = subPattern?.firstMatch(in: line, range: range), m.numberOfRanges >= 2 {
                flushSub()
                pendingSub = ns.substring(with: m.range(at: 1)).trimmingCharacters(in: .whitespaces)
                continue
            }
            if let m = contPattern?.firstMatch(in: line, range: range), m.numberOfRanges >= 2 {
                let text = ns.substring(with: m.range(at: 1)).trimmingCharacters(in: .whitespaces)
                if text.isEmpty { continue }
                if pendingSub != nil {
                    pendingSubCont.append(text)
                } else if title != nil {
                    bodyParts.append(text)
                }
                continue
            }
            // Blank or odd line — flush sub-bullet continuation but keep task open.
            if line.trimmingCharacters(in: .whitespaces).isEmpty {
                flushSub()
            }
        }
        flushTask()
        return tasks
    }
}

// MARK: - Date helpers

private extension ISO8601DateFormatter {
    static let dateOnly: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withFullDate]
        return f
    }()
}

private extension DateFormatter {
    static let iso8601Date: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd"
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone(secondsFromGMT: 0)
        return f
    }()
}
