import Foundation
import os

private let logger = Logger(subsystem: "com.claudehud", category: "ProjectService")

// MARK: - Project Model

struct Project: Identifiable {
    let id: String              // Obsidian folder name
    let name: String
    let obsidianPath: String    // full path to Obsidian folder
    let folderTerms: [String]   // search terms derived from folder name
    let recentSessions: [SessionInfo]
    let recentNotes: [RecentNote]
    let lastActivity: Date
}

struct RecentNote: Identifiable {
    let id = UUID()
    let name: String
    let path: String
    let modified: Date
}

// MARK: - Project Service

@MainActor
class ProjectService: ObservableObject {
    @Published var projects: [Project] = []
    @Published var isLoading = false

    private weak var vaultManager: VaultManager?
    private weak var sessionHistory: SessionHistoryService?

    func configure(vault: VaultManager, sessions: SessionHistoryService) {
        self.vaultManager = vault
        self.sessionHistory = sessions
    }

    func refresh() {
        guard let vault = vaultManager,
              let sessions = sessionHistory,
              let vaultPath = vault.currentVault?.path else {
            projects = []
            return
        }

        isLoading = true

        let allSessions = sessions.sessions
        let vp = vaultPath

        Task.detached(priority: .userInitiated) {
            let result = Self.buildProjects(
                vaultPath: vp,
                sessions: allSessions
            )
            await MainActor.run { [weak self] in
                self?.projects = result
                self?.isLoading = false
            }
        }
    }

    // MARK: - Project Discovery

    /// Vault folders that are never projects (shared infrastructure folders),
    /// excluded from project discovery.
    nonisolated static let excludedFolderNames: Set<String> = [
        "Templates", "Daily Notes", "Attachments", "Assets", "Archive",
        // `Claude/` is the claimless tooling-reference folder (schema.md):
        // never a project / session-mapping target.
        "Claude"
    ]

    nonisolated private static func buildProjects(
        vaultPath: String,
        sessions: [SessionInfo]
    ) -> [Project] {
        let fm = FileManager.default
        guard let folders = try? fm.contentsOfDirectory(atPath: vaultPath) else { return [] }

        var results: [Project] = []

        for folder in folders {
            let folderPath = "\(vaultPath)/\(folder)"
            var isDir: ObjCBool = false
            guard fm.fileExists(atPath: folderPath, isDirectory: &isDir), isDir.boolValue else { continue }
            guard !folder.hasPrefix(".") else { continue }
            guard !excludedFolderNames.contains(folder) else { continue }

            let normalized = normalize(folder)

            // Match sessions
            let matched = sessions.filter { session in
                let sessionNorm = normalize(session.projectName)
                return fuzzyMatch(normalized, sessionNorm)
            }
            let recentSessions = Array(matched.prefix(5))

            // Search terms derived from the folder name (kept on the model).
            let folderTerms = folder
                .components(separatedBy: CharacterSet.alphanumerics.inverted)
                .filter { $0.count > 2 }
                .map { $0.lowercased() }

            // Get recent notes
            let notes = recentNotes(in: folderPath, limit: 5)

            // Determine last activity
            let sessionDate = recentSessions.first?.timestamp
            let noteDate = notes.first?.modified
            let lastActivity = [sessionDate, noteDate].compactMap { $0 }.max() ?? Date.distantPast

            guard !recentSessions.isEmpty || !notes.isEmpty else { continue }

            results.append(Project(
                id: folder,
                name: folder,
                obsidianPath: folderPath,
                folderTerms: folderTerms,
                recentSessions: recentSessions,
                recentNotes: notes,
                lastActivity: lastActivity
            ))
        }

        return results.sorted { $0.lastActivity > $1.lastActivity }
    }

    // MARK: - Fuzzy Matching

    nonisolated static func normalize(_ name: String) -> String {
        name.lowercased()
            .replacingOccurrences(of: "-", with: "")
            .replacingOccurrences(of: "_", with: "")
            .replacingOccurrences(of: " ", with: "")
            .replacingOccurrences(of: ".", with: "")
    }

    nonisolated static func fuzzyMatch(_ a: String, _ b: String) -> Bool {
        if a == b { return true }
        if a.count >= 4 && b.contains(a) { return true }
        if b.count >= 4 && a.contains(b) { return true }
        return false
    }

    // MARK: - Recent Notes

    nonisolated private static func recentNotes(in folderPath: String, limit: Int) -> [RecentNote] {
        let fm = FileManager.default
        guard let files = try? fm.contentsOfDirectory(atPath: folderPath) else { return [] }

        var notes: [RecentNote] = []

        for file in files where file.hasSuffix(".md") {
            let path = "\(folderPath)/\(file)"
            guard let attrs = try? fm.attributesOfItem(atPath: path),
                  let modified = attrs[.modificationDate] as? Date else { continue }
            let name = String(file.dropLast(3))
            notes.append(RecentNote(name: name, path: path, modified: modified))
        }

        return notes.sorted { $0.modified > $1.modified }.prefix(limit).map { $0 }
    }

    // MARK: - Canonical project↔vault resolver

    /// Resolve a repo working directory to its Obsidian vault project folder
    /// using the ONE canonical rule shared by the ingest hook
    /// (`~/.claude/scripts/vault-ingest.sh` `resolve_project`) and the wiki
    /// contract (`~/Documents/Obsidian/schema.md` §"Canonical project model").
    ///
    /// Among ALL vault project folders, every `cwds:` + `migrated-from:`
    /// frontmatter entry from each folder's `Tasks.md` is collected (every
    /// project has a `Tasks.md`; some have no `Dashboard.md`). A
    /// pattern matches `repoPath` when any of: exact equality; shell-glob
    /// `fnmatch`; equality after stripping a trailing `/`/`*` run; or
    /// `repoPath` is under `pattern` (trailing `*` then `/` stripped, `+ "/"`).
    /// The project whose MATCHING pattern is the LONGEST wins; no match → nil.
    /// Never fuzzy-matched, never guessed — deterministic by design.
    ///
    /// Returns the absolute vault folder path on a hit (so the launcher can
    /// name it directly), or nil for an unclaimed working directory (the
    /// launcher then falls back to the legacy index.md resolution).
    func vaultFolderPath(forRepoPath repoPath: String) -> String? {
        let vaultRoot = vaultManager?.currentVault?.path
            ?? "\(NSHomeDirectory())/Documents/Obsidian"
        guard let folder = Self.resolveProjectFolder(cwd: repoPath, vaultPath: vaultRoot) else {
            return nil
        }
        return "\(vaultRoot)/\(folder)"
    }

    /// Pure port of the bash `resolve_project` python. Returns the winning
    /// vault folder NAME, or nil. Kept `nonisolated static` so it can be unit-
    /// reasoned in isolation and never touches actor state.
    nonisolated static func resolveProjectFolder(cwd: String, vaultPath: String) -> String? {
        let fm = FileManager.default
        guard let folders = try? fm.contentsOfDirectory(atPath: vaultPath) else { return nil }

        var best: String?
        var bestLen = -1
        // `sorted()` mirrors the bash `sorted(os.listdir(vault))` so ties
        // resolve identically across both implementations.
        for folder in folders.sorted() {
            let folderPath = "\(vaultPath)/\(folder)"
            var isDir: ObjCBool = false
            guard fm.fileExists(atPath: folderPath, isDirectory: &isDir), isDir.boolValue else { continue }
            guard !folder.hasPrefix(".") else { continue }

            for pat in claimedCwds(dashboardAt: "\(folderPath)/Tasks.md") {
                if patternMatches(cwd: cwd, pattern: pat), pat.count > bestLen {
                    best = folder
                    bestLen = pat.count
                }
            }
        }
        return best
    }

    /// The four-way match predicate, byte-for-byte equivalent to the bash:
    ///   cwd == pat
    ///   || fnmatch(cwd, pat)
    ///   || cwd == pat.rstrip("/*")
    ///   || cwd.startswith(pat.rstrip("*").rstrip("/") + "/")
    nonisolated private static func patternMatches(cwd: String, pattern pat: String) -> Bool {
        if cwd == pat { return true }
        // POSIX fnmatch(3) — same engine Python's fnmatch.fnmatch ultimately
        // models (default flags: `*`/`?`/`[…]`, `*` spans `/`). No FNM_PATHNAME.
        if fnmatch(pat, cwd, 0) == 0 { return true }
        if cwd == rstrip(pat, of: "/*") { return true }
        if cwd.hasPrefix(rstrip(rstrip(pat, of: "*"), of: "/") + "/") { return true }
        return false
    }

    /// Python `str.rstrip(chars)`: drop the trailing run of any char in `set`.
    nonisolated private static func rstrip(_ s: String, of set: String) -> String {
        let drop = Set(set)
        var end = s.endIndex
        while end > s.startIndex {
            let prev = s.index(before: end)
            if drop.contains(s[prev]) { end = prev } else { break }
        }
        return String(s[s.startIndex..<end])
    }

    /// Parse a `Tasks.md`'s leading YAML frontmatter and collect every
    /// `cwds:` + `migrated-from:` entry, keeping only absolute paths/globs.
    /// Faithful to the bash python `claims()`: leading `---\n…\n---\n` block;
    /// `key:` arms collection, inline value or following `- item` lines are
    /// taken; a non-indented non-empty line resets the active key; quotes,
    /// brackets and surrounding spaces are stripped.
    nonisolated private static func claimedCwds(dashboardAt path: String) -> [String] {
        guard let txt = try? String(contentsOfFile: path, encoding: .utf8) else { return [] }

        // FM = re.compile(r'^---\n(.*?)\n---\n', re.DOTALL); FM.match(txt)
        // Normalize CRLF so a Windows-authored note still parses; the bash
        // runs on macOS notes (LF) so this only ever widens, never narrows.
        let normalized = txt.replacingOccurrences(of: "\r\n", with: "\n")
        guard normalized.hasPrefix("---\n") else { return [] }
        let afterOpen = normalized.index(normalized.startIndex, offsetBy: 4)
        guard let closeRange = normalized.range(of: "\n---\n", range: afterOpen..<normalized.endIndex) else {
            return []
        }
        let body = String(normalized[afterOpen..<closeRange.lowerBound])

        var out: [String] = []
        var keyActive = false
        for line in body.components(separatedBy: "\n") {
            let stripped = line.trimmingCharacters(in: .whitespaces)

            // re.match(r'^(cwds|migrated-from)\s*:', line)
            if let colon = line.firstIndex(of: ":") {
                let head = String(line[line.startIndex..<colon])
                    .trimmingCharacters(in: CharacterSet(charactersIn: " \t"))
                if head == "cwds" || head == "migrated-from" {
                    keyActive = true
                    let inline = String(line[line.index(after: colon)...])
                        .trimmingCharacters(in: .whitespaces)
                    if !inline.isEmpty, inline != "[]", inline != "~" {
                        out.append(trim(inline, anyOf: "'\"[] "))
                    }
                    continue
                }
            }

            if keyActive && stripped.hasPrefix("- ") {
                let item = String(stripped.dropFirst(2)).trimmingCharacters(in: .whitespaces)
                out.append(trim(item, anyOf: "'\""))
                continue
            }

            // `if line and not line[0].isspace(): key = None`
            if let first = line.first, !first.isWhitespace {
                keyActive = false
            }
        }
        return out.filter { $0.hasPrefix("/") }
    }

    /// Python `str.strip(chars)` applied to both ends.
    nonisolated private static func trim(_ s: String, anyOf set: String) -> String {
        let drop = Set(set)
        var start = s.startIndex
        var end = s.endIndex
        while start < end, drop.contains(s[start]) { start = s.index(after: start) }
        while end > start {
            let prev = s.index(before: end)
            if drop.contains(s[prev]) { end = prev } else { break }
        }
        return String(s[start..<end])
    }
}
