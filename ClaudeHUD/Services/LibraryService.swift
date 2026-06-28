import Foundation
import Combine
import AppKit
import os

private let logger = Logger(subsystem: "com.claudehud", category: "LibraryService")

/// Loads and exposes Claude's user-level internals (~/.claude/...) grouped by
/// category, for the Library tab. Owns a `SkillsService` for the Skills category
/// so the existing family/subfamily grouping logic stays in one place.
@MainActor
final class LibraryService: ObservableObject {
    @Published var selectedCategory: LibraryCategory = .skills
    @Published private(set) var itemsByCategory: [LibraryCategory: [LibraryItem]] = [:]
    @Published private(set) var lastError: String?

    let skillsService: SkillsService

    init(skillsService: SkillsService) {
        self.skillsService = skillsService
    }

    func items(in category: LibraryCategory) -> [LibraryItem] {
        itemsByCategory[category] ?? []
    }

    /// Reload one category (or all if `nil`). Skills loading delegates to the
    /// shared SkillsService so the family/subfamily UI stays in sync with the
    /// LibraryItem list.
    func reload(_ category: LibraryCategory? = nil) {
        let targets = category.map { [$0] } ?? LibraryCategory.allCases
        for cat in targets {
            switch cat {
            case .skills:
                skillsService.reload()
                itemsByCategory[.skills] = skillsService.skills.map(Self.libraryItemFromSkill)
            case .agents:    itemsByCategory[.agents]   = loadMarkdownFolder(cat)
            case .commands:  itemsByCategory[.commands] = loadMarkdownFolder(cat)
            case .rules:     itemsByCategory[.rules]    = loadMarkdownFolder(cat)
            case .style:     itemsByCategory[.style]    = loadMarkdownFolder(cat)
            case .plans:     itemsByCategory[.plans]    = loadMarkdownFolder(cat, sortByMTime: true)
            case .scripts:   itemsByCategory[.scripts]  = loadFlatFolder(cat)
            case .hooks:     itemsByCategory[.hooks]    = loadHooks()
            case .tools:     itemsByCategory[.tools]    = loadTools()
            case .mcp:       itemsByCategory[.mcp]      = loadMCP()
            case .guides:    itemsByCategory[.guides]   = loadGuides()
            case .memories:  itemsByCategory[.memories] = loadMemories()
            case .settings:  itemsByCategory[.settings] = loadSettings()
            case .plugins:   itemsByCategory[.plugins]  = loadPlugins()
            }
        }
    }

    // MARK: - Skill bridge

    private static func libraryItemFromSkill(_ s: SkillFile) -> LibraryItem {
        LibraryItem(
            id: s.id,
            category: .skills,
            displayName: s.displayName,
            summary: s.summary,
            path: s.folder,           // for Skills, "open" should target the folder, not just SKILL.md
            isDirectory: true,
            frontmatter: s.frontmatter,
            body: s.body,
            group: s.group,
            subgroup: s.taggedSubfamily
        )
    }

    // MARK: - Markdown-folder loader (agents, commands, rules, style, plans)

    private func loadMarkdownFolder(_ cat: LibraryCategory, sortByMTime: Bool = false) -> [LibraryItem] {
        let root = cat.rootURL
        let fm = FileManager.default
        guard let contents = try? fm.contentsOfDirectory(at: root,
                                                         includingPropertiesForKeys: [.contentModificationDateKey],
                                                         options: [.skipsHiddenFiles]) else {
            return []
        }
        let mdFiles = contents.filter { $0.pathExtension.lowercased() == "md" }
        let items: [LibraryItem] = mdFiles.compactMap { url in
            guard let raw = try? String(contentsOf: url, encoding: .utf8) else { return nil }
            let (front, body) = SkillFrontmatter.split(raw)
            let name = front["name"] ?? url.deletingPathExtension().lastPathComponent
            let summary = front["description"] ?? Self.firstNonEmptyLine(of: body)
            let group: String?
            switch cat {
            case .agents:
                group = Self.agentRole(name: name)
            case .plans:
                let mtime = (try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
                group = Self.recencyBucket(for: mtime)
            default:
                group = nil
            }
            return LibraryItem(
                id: url.path,
                category: cat,
                displayName: name,
                summary: summary,
                path: url,
                isDirectory: false,
                frontmatter: front,
                body: body,
                group: group,
                subgroup: nil
            )
        }
        if sortByMTime {
            return items.sorted { lhs, rhs in
                let a = (try? lhs.path.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
                let b = (try? rhs.path.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
                return a > b
            }
        }
        return items.sorted { $0.displayName.localizedCaseInsensitiveCompare($1.displayName) == .orderedAscending }
    }

    /// Bucket an agent by name into a high-level role group.
    /// Heuristic: name suffix takes precedence (-critic / -referee / -reviewer),
    /// then known orchestrators / built-in helpers, then everything else is a Worker.
    private static func agentRole(name: String) -> String {
        let lower = name.lowercased()
        if lower.hasSuffix("-critic")   { return "Critics" }
        if lower.hasSuffix("-referee")  { return "Referees" }
        if lower.hasSuffix("-reviewer") { return "Reviewers" }
        let orchestrators: Set<String> = ["orchestrator", "verifier", "proofreader"]
        if orchestrators.contains(lower) { return "Orchestration" }
        let builtIns: Set<String> = [
            "plan", "explore", "general-purpose", "claude-code-guide",
            "statusline-setup", "frontend-design"
        ]
        if builtIns.contains(lower) { return "Built-in" }
        return "Workers"
    }

    private static func recencyBucket(for date: Date) -> String {
        let cal = Calendar.current
        let now = Date()
        let startOfToday = cal.startOfDay(for: now)
        let startOfWeek = cal.date(byAdding: .day, value: -7, to: startOfToday) ?? startOfToday
        if date >= startOfToday { return "Today" }
        if date >= startOfWeek  { return "This Week" }
        return "Older"
    }

    // MARK: - Flat-file folder loader (scripts)

    private func loadFlatFolder(_ cat: LibraryCategory) -> [LibraryItem] {
        let root = cat.rootURL
        let fm = FileManager.default
        guard let contents = try? fm.contentsOfDirectory(at: root,
                                                         includingPropertiesForKeys: [.isRegularFileKey],
                                                         options: [.skipsHiddenFiles]) else {
            return []
        }
        let files = contents.filter { url in
            (try? url.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true
        }
        return files.map { url in
            let body = (try? String(contentsOf: url, encoding: .utf8)) ?? ""
            let summary: String
            if url.pathExtension.lowercased() == "md" {
                let (_, b) = SkillFrontmatter.split(body)
                summary = Self.firstNonEmptyLine(of: b)
            } else {
                summary = Self.firstShebangSummary(of: body)
            }
            return LibraryItem(
                id: url.path,
                category: cat,
                displayName: url.lastPathComponent,
                summary: summary,
                path: url,
                isDirectory: false,
                frontmatter: [:],
                body: body,
                group: nil,
                subgroup: nil
            )
        }
        .sorted { $0.displayName.localizedCaseInsensitiveCompare($1.displayName) == .orderedAscending }
    }

    // MARK: - Hooks: scripts in ~/.claude/hooks + registered hooks in settings.json

    private func loadHooks() -> [LibraryItem] {
        var out: [LibraryItem] = []

        // 1) Scripts in ~/.claude/hooks/ (files only; nested dirs skipped).
        let fm = FileManager.default
        let hooksRoot = LibraryCategory.hooks.rootURL
        if let contents = try? fm.contentsOfDirectory(at: hooksRoot,
                                                      includingPropertiesForKeys: [.isRegularFileKey],
                                                      options: [.skipsHiddenFiles]) {
            for url in contents {
                let isFile = (try? url.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true
                guard isFile else { continue }
                let body = (try? String(contentsOf: url, encoding: .utf8)) ?? ""
                out.append(LibraryItem(
                    id: url.path,
                    category: .hooks,
                    displayName: url.lastPathComponent,
                    summary: Self.firstShebangSummary(of: body),
                    path: url,
                    isDirectory: false,
                    frontmatter: [:],
                    body: body,
                    group: "Scripts",
                    subgroup: nil
                ))
            }
        }

        // 2) Registered hooks in settings.json under "hooks" → event → matchers → commands.
        let settingsURL = LibraryCategory.settings.rootURL
        if let data = try? Data(contentsOf: settingsURL),
           let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let hooksDict = json["hooks"] as? [String: Any] {
            for event in hooksDict.keys.sorted() {
                guard let matchers = hooksDict[event] as? [[String: Any]] else { continue }
                for (mi, matcher) in matchers.enumerated() {
                    let pattern = matcher["matcher"] as? String ?? ""
                    let hooks = matcher["hooks"] as? [[String: Any]] ?? []
                    for (hi, hook) in hooks.enumerated() {
                        let cmd = hook["command"] as? String ?? ""
                        let type = hook["type"] as? String ?? "command"
                        let label = pattern.isEmpty ? event : "\(event) · \(pattern)"
                        out.append(LibraryItem(
                            id: "settings.hooks.\(event).\(mi).\(hi)",
                            category: .hooks,
                            displayName: label,
                            summary: "[\(type)] \(cmd)",
                            path: settingsURL,            // opening jumps to settings.json (no jq path)
                            isDirectory: false,
                            frontmatter: [:],
                            body: cmd,
                            group: event,                 // group by event for clean sub-headers
                            subgroup: nil
                        ))
                    }
                }
            }
        }

        return out
    }

    // MARK: - CLI Tools (collapsed from settings.json:permissions.allow)

    /// One row per *binary* allowlisted as `Bash(<binary>:*)` / `Bash(<binary>)` in
    /// settings.json. Sub-command patterns (e.g., `Bash(gh api:*)`, `Bash(gh run list:*)`)
    /// roll up into the parent binary row with a count. POSIX/shell-builtin noise
    /// (ls, mv, cp, find, grep, ...) is filtered out because every project allowlists
    /// it and seeing 50 rows of basics drowns the signal.
    ///
    /// Source of truth is settings.json — opening the row in VS Code jumps you there.
    private func loadTools() -> [LibraryItem] {
        let settingsURL = LibraryCategory.settings.rootURL
        guard let data = try? Data(contentsOf: settingsURL),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let perms = json["permissions"] as? [String: Any] else { return [] }

        let allow = (perms["allow"] as? [String]) ?? []
        let deny  = (perms["deny"]  as? [String]) ?? []
        let ask   = (perms["ask"]   as? [String]) ?? []

        // First pass: bucket every Bash() entry by its leading binary token.
        struct BinaryStats { var allow: [String] = []; var deny: [String] = []; var ask: [String] = [] }
        var binStats: [String: BinaryStats] = [:]
        func ingest(_ patterns: [String], into keypath: WritableKeyPath<BinaryStats, [String]>) {
            for pattern in patterns {
                guard let binary = Self.bashBinary(from: pattern) else { continue }
                var stats = binStats[binary] ?? BinaryStats()
                stats[keyPath: keypath].append(pattern)
                binStats[binary] = stats
            }
        }
        ingest(allow, into: \.allow)
        ingest(deny,  into: \.deny)
        ingest(ask,   into: \.ask)

        var out: [LibraryItem] = []
        for binary in binStats.keys where !Self.shellNoise.contains(binary) {
            let stats = binStats[binary]!
            let allowCount = stats.allow.count
            let denyCount  = stats.deny.count
            let askCount   = stats.ask.count
            // Summary: "12 allowed · 1 denied"
            var parts: [String] = []
            if allowCount > 0 { parts.append("\(allowCount) allowed") }
            if denyCount  > 0 { parts.append("\(denyCount) denied")  }
            if askCount   > 0 { parts.append("\(askCount) ask")      }
            let summary = parts.isEmpty ? "(no rules)" : parts.joined(separator: " · ")
            // Body shows every matching pattern so the user can scan exactly
            // what's authorized for this binary when they open it.
            let body = (stats.allow.map { "ALLOW \($0)" }
                        + stats.deny.map  { "DENY  \($0)" }
                        + stats.ask.map   { "ASK   \($0)" }).joined(separator: "\n")
            out.append(LibraryItem(
                id: "tool.bash.\(binary)",
                category: .tools,
                displayName: binary,
                summary: summary,
                path: settingsURL,
                isDirectory: false,
                frontmatter: [:],
                body: body,
                group: Self.toolFamily(for: binary),
                subgroup: nil
            ))
        }
        return out.sorted { $0.displayName.localizedCaseInsensitiveCompare($1.displayName) == .orderedAscending }
    }

    /// Extract the leading binary token from a `Bash(...)` permission pattern.
    /// `Bash(gh api:*)`     → `gh`
    /// `Bash(npm install:*)`→ `npm`
    /// `Bash(brew tap:*)`   → `brew`
    /// `Bash(git push)`     → `git`
    /// Non-Bash entries return nil and are ignored.
    private static func bashBinary(from pattern: String) -> String? {
        guard pattern.hasPrefix("Bash(") else { return nil }
        let inner = pattern.dropFirst("Bash(".count).dropLast()
        // Trim trailing `:*` if present; split on first space or colon.
        let token = inner
            .split(whereSeparator: { $0 == " " || $0 == ":" })
            .first
            .map(String.init)
        guard let t = token, !t.isEmpty, t != "*" else { return nil }
        return t
    }

    /// POSIX / shell builtins that are noise — every project allowlists them
    /// and they don't tell you anything about which CLI tools live on the
    /// machine. Filtered out of the Tools view.
    private static let shellNoise: Set<String> = [
        "ls", "cd", "pwd", "mv", "cp", "rm", "mkdir", "rmdir", "ln", "touch",
        "cat", "head", "tail", "less", "more", "echo", "printf",
        "find", "grep", "sed", "awk", "tr", "cut", "sort", "uniq", "wc",
        "chmod", "chown", "chgrp",
        "kill", "killall", "ps", "pgrep", "pkill", "lsof", "top",
        "env", "which", "type", "command", "alias", "source", ".", "test", "true", "false",
        "tar", "gzip", "gunzip", "zip", "unzip",
        "sleep", "date", "uname", "hostname", "whoami", "id", "uptime",
        "tee", "xargs", "dirname", "basename", "realpath", "readlink",
        "diff", "comm", "join", "paste",
        "ssh", "scp",
    ]

    /// Bucket a binary into a high-level family for the Tools section headers.
    private static func toolFamily(for binary: String) -> String {
        let git: Set<String>   = ["git", "gh", "git-lfs", "hub"]
        let pkgmgr: Set<String> = ["brew", "npm", "yarn", "pnpm", "pip", "pip3", "pipx", "uv",
                                   "cargo", "rustup", "gem", "conda", "mamba", "asdf"]
        let build: Set<String>  = ["xcodebuild", "xcodegen", "swift", "make", "cmake", "ninja",
                                   "tsc", "vite", "webpack", "rollup", "esbuild"]
        let data: Set<String>   = ["stata-mp", "stata-se", "stata", "Rscript", "R",
                                   "python3", "python", "ipython", "jupyter", "uv",
                                   "jq", "yq", "duckdb", "sqlite3",
                                   "pandoc", "latexmk", "pdflatex", "xelatex", "bibtex", "biber"]
        let net: Set<String>    = ["curl", "wget", "http", "httpie", "rsync"]
        let mac: Set<String>    = ["open", "osascript", "defaults", "launchctl",
                                   "sw_vers", "softwareupdate", "pmset",
                                   "diskutil", "hdiutil", "sips", "afplay"]
        let claude: Set<String> = ["claude", "rtk", "xcodegen", "ghostty"]
        if claude.contains(binary)  { return "Claude / HUD" }
        if git.contains(binary)     { return "Git & GitHub" }
        if pkgmgr.contains(binary)  { return "Package managers" }
        if build.contains(binary)   { return "Build tools" }
        if data.contains(binary)    { return "Data & research" }
        if net.contains(binary)     { return "Network" }
        if mac.contains(binary)     { return "macOS" }
        return "Other"
    }

    // MARK: - MCP

    private func loadMCP() -> [LibraryItem] {
        var out: [LibraryItem] = []
        let candidates: [URL] = [
            LibraryCategory.mcp.rootURL,
            FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".claude/mcp_settings.json"),
        ]
        var seen = Set<String>()
        for url in candidates {
            guard FileManager.default.fileExists(atPath: url.path),
                  let data = try? Data(contentsOf: url),
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { continue }
            // Both files use `mcpServers` as the canonical key.
            guard let servers = json["mcpServers"] as? [String: Any] else { continue }
            for name in servers.keys.sorted() {
                guard !seen.contains(name) else { continue }
                seen.insert(name)
                let spec = servers[name] as? [String: Any] ?? [:]
                let cmd = spec["command"] as? String ?? ""
                let args = spec["args"] as? [String] ?? []
                let summary = args.isEmpty ? cmd : "\(cmd) (\(args.count) arg\(args.count == 1 ? "" : "s"))"
                let body = (try? String(data: JSONSerialization.data(withJSONObject: spec,
                                                                     options: [.prettyPrinted, .sortedKeys]),
                                        encoding: .utf8)) ?? ""
                out.append(LibraryItem(
                    id: "mcp.\(url.lastPathComponent).\(name)",
                    category: .mcp,
                    displayName: name,
                    summary: summary,
                    path: url,
                    isDirectory: false,
                    frontmatter: [:],
                    body: body,
                    group: url.lastPathComponent == ".mcp.json" ? "Primary" : url.lastPathComponent,
                    subgroup: nil
                ))
            }
        }
        return out
    }

    // MARK: - Guides (top-level .md in ~/.claude/)

    private func loadGuides() -> [LibraryItem] {
        let root = LibraryCategory.guides.rootURL
        let fm = FileManager.default
        guard let contents = try? fm.contentsOfDirectory(at: root,
                                                         includingPropertiesForKeys: [.isRegularFileKey],
                                                         options: [.skipsHiddenFiles]) else {
            return []
        }
        let mdFiles = contents.filter { $0.pathExtension.lowercased() == "md" }
        return mdFiles.map { url in
            let body = (try? String(contentsOf: url, encoding: .utf8)) ?? ""
            return LibraryItem(
                id: url.path,
                category: .guides,
                displayName: url.lastPathComponent,
                summary: Self.firstNonEmptyLine(of: body),
                path: url,
                isDirectory: false,
                frontmatter: [:],
                body: body,
                group: nil,
                subgroup: nil
            )
        }
        .sorted { $0.displayName.localizedCaseInsensitiveCompare($1.displayName) == .orderedAscending }
    }

    // MARK: - Memories (~/.claude/projects/<encoded-home>/memory/*.md)

    /// One row per memory file. Each memory is a single .md with name/description/
    /// metadata frontmatter. MEMORY.md is the index, not a memory — skip it.
    /// Items are grouped by their `metadata.type` (Feedback / Project / Reference /
    /// User / Note) so the shared grouped-list renderer shows type section headers.
    private func loadMemories() -> [LibraryItem] {
        let root = LibraryCategory.memories.rootURL
        let fm = FileManager.default
        guard let contents = try? fm.contentsOfDirectory(at: root,
                                                         includingPropertiesForKeys: [.isRegularFileKey],
                                                         options: [.skipsHiddenFiles]) else {
            return []
        }
        let mdFiles = contents.filter {
            $0.pathExtension.lowercased() == "md" && $0.lastPathComponent != "MEMORY.md"
        }
        let items: [LibraryItem] = mdFiles.compactMap { url in
            guard let raw = try? String(contentsOf: url, encoding: .utf8) else { return nil }
            let (front, body) = SkillFrontmatter.split(raw)
            // The flat frontmatter parser captures the indented `type:` under
            // `metadata:` as a top-level key, so front["type"] is metadata.type.
            let name = front["name"] ?? url.deletingPathExtension().lastPathComponent
            let summary = front["description"] ?? Self.firstNonEmptyLine(of: body)
            let group = Self.memoryTypeLabel(front["type"])
            return LibraryItem(
                id: url.path,
                category: .memories,
                displayName: name,
                summary: summary,
                path: url,
                isDirectory: false,
                frontmatter: front,
                body: body,
                group: group,
                subgroup: nil
            )
        }
        return items.sorted { $0.displayName.localizedCaseInsensitiveCompare($1.displayName) == .orderedAscending }
    }

    /// Capitalize the raw metadata.type into a section label. Unknown/missing
    /// types fall back to "Note".
    private static func memoryTypeLabel(_ raw: String?) -> String {
        let value = (raw ?? "").trimmingCharacters(in: .whitespaces).lowercased()
        switch value {
        case "feedback":  return "Feedback"
        case "project":   return "Project"
        case "reference": return "Reference"
        case "user":      return "User"
        case "note":      return "Note"
        default:          return value.isEmpty ? "Note" : value.capitalized
        }
    }

    // MARK: - Settings (the two JSON files themselves as rows)

    private func loadSettings() -> [LibraryItem] {
        let home = FileManager.default.homeDirectoryForCurrentUser
        let urls = [
            home.appendingPathComponent(".claude/settings.json"),
            home.appendingPathComponent(".claude/settings.local.json"),
        ]
        return urls.compactMap { url in
            guard FileManager.default.fileExists(atPath: url.path) else { return nil }
            let body = (try? String(contentsOf: url, encoding: .utf8)) ?? ""
            let size = ByteCountFormatter.string(fromByteCount: Int64(body.utf8.count), countStyle: .file)
            let keys: Int = {
                guard let data = body.data(using: .utf8),
                      let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return 0 }
                return json.count
            }()
            return LibraryItem(
                id: url.path,
                category: .settings,
                displayName: url.lastPathComponent,
                summary: "\(keys) top-level key\(keys == 1 ? "" : "s") · \(size)",
                path: url,
                isDirectory: false,
                frontmatter: [:],
                body: body,
                group: nil,
                subgroup: nil
            )
        }
    }

    // MARK: - Plugins (installed_plugins.json v2)

    private func loadPlugins() -> [LibraryItem] {
        let url = LibraryCategory.plugins.rootURL
        guard let data = try? Data(contentsOf: url),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return []
        }
        // v2: { version: 2, plugins: { "name@marketplace": [installRecord, ...] } }
        guard let plugins = json["plugins"] as? [String: Any] else { return [] }
        var out: [LibraryItem] = []
        for key in plugins.keys.sorted() {
            let records = (plugins[key] as? [[String: Any]]) ?? []
            let head = records.first ?? [:]
            let version = head["version"] as? String ?? ""
            let scope = head["scope"] as? String ?? ""
            let installPath = head["installPath"] as? String
            let summary = [scope, version].filter { !$0.isEmpty }.joined(separator: " · ")
            let openPath = installPath.map { URL(fileURLWithPath: $0) } ?? url
            // "name@marketplace" → split for nicer display + marketplace grouping.
            let parts = key.split(separator: "@", maxSplits: 1, omittingEmptySubsequences: true)
            let displayName = parts.first.map(String.init) ?? key
            let marketplace = parts.count > 1 ? String(parts[1]) : "other"
            out.append(LibraryItem(
                id: "plugin.\(key)",
                category: .plugins,
                displayName: displayName,
                summary: summary.isEmpty ? "(no version info)" : summary,
                path: openPath,
                isDirectory: installPath != nil,
                frontmatter: [:],
                body: "",
                group: marketplace,
                subgroup: nil
            ))
        }
        return out
    }

    // MARK: - Helpers

    private static func firstNonEmptyLine(of body: String) -> String {
        for line in body.components(separatedBy: "\n") {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.isEmpty || trimmed.hasPrefix("#") || trimmed.hasPrefix("---") { continue }
            return String(trimmed.prefix(180))
        }
        return ""
    }

    private static func firstShebangSummary(of body: String) -> String {
        let lines = body.components(separatedBy: "\n").prefix(20)
        // Prefer the first comment line below the shebang.
        for line in lines {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("#!") { continue }
            if trimmed.hasPrefix("#") || trimmed.hasPrefix("//") || trimmed.hasPrefix("\"\"\"") {
                let stripped = trimmed
                    .drop(while: { $0 == "#" || $0 == "/" || $0 == "\"" })
                    .trimmingCharacters(in: .whitespaces)
                if !stripped.isEmpty { return String(stripped.prefix(180)) }
            }
            if !trimmed.isEmpty { break }
        }
        // Fall back to the shebang itself.
        if let shebang = lines.first(where: { $0.hasPrefix("#!") }) {
            return String(shebang.prefix(180))
        }
        return ""
    }

    func revealInFinder(_ item: LibraryItem) {
        if item.isDirectory {
            NSWorkspace.shared.activateFileViewerSelecting([item.path])
        } else {
            NSWorkspace.shared.activateFileViewerSelecting([item.path])
        }
    }
}
