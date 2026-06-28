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
    let upcomingEvents: [CalendarEvent]
    let recentNotes: [RecentNote]
    let lastActivity: Date
}

struct ProjectIntel: Identifiable {
    let id: String  // project id
    let emails: [ProjectEmail]
    let people: [Contact]
    var isLoading: Bool = false
}

struct RecentNote: Identifiable {
    let id = UUID()
    let name: String
    let path: String
    let modified: Date
}

struct GitHubRepoInfo: Codable, Equatable {
    let nameWithOwner: String   // "bbdaniels/ClaudeHUD"
    let url: String             // "https://github.com/bbdaniels/ClaudeHUD"
    let isPrivate: Bool
}

/// Disk cache entry for a project's GitHub info. `info == nil` means we resolved
/// the project and confirmed there is no GitHub remote — distinct from "not yet
/// fetched," which is represented by the absence of any cache entry. `path` is
/// optional for backward compatibility with cache entries written before the
/// path-keyed scheme; old entries are silently dropped on load.
private struct CachedGitHubInfo: Codable {
    let info: GitHubRepoInfo?
    let resolvedAt: Date
    let path: String?
}

struct ProjectEmail: Identifiable {
    let id = UUID()
    let subject: String
    let from: String
    let fromEmail: String
    let date: String
    let epoch: Double
    let body: String
    let messagePk: String
}

// MARK: - Project Service

@MainActor
class ProjectService: ObservableObject {
    @Published var projects: [Project] = []
    @Published var intel: [String: ProjectIntel] = [:]
    @Published var isLoading = false

    /// GitHub repo info keyed by absolute project path (the working directory
    /// `gh` is run from). The value is itself optional: a present-but-nil entry
    /// means we ran `gh` and confirmed the project has no GitHub remote. A
    /// missing key means we haven't fetched yet.
    @Published var gitHubInfo: [String: GitHubRepoInfo?] = [:]

    private static let gitHubCacheDir = "\(NSHomeDirectory())/.claude/hud/github-info"
    private static let gitHubMaxAge: TimeInterval = 6 * 3600 // 6 hours
    private var gitHubInflight: Set<String> = []

    private weak var vaultManager: VaultManager?
    private weak var sessionHistory: SessionHistoryService?
    private weak var calendarService: CalendarService?

    init() {
        loadGitHubCache()
    }

    func configure(vault: VaultManager, sessions: SessionHistoryService, calendar: CalendarService) {
        self.vaultManager = vault
        self.sessionHistory = sessions
        self.calendarService = calendar
    }

    func refresh() {
        guard let vault = vaultManager,
              let sessions = sessionHistory,
              let calendar = calendarService,
              let vaultPath = vault.currentVault?.path else {
            projects = []
            return
        }

        isLoading = true

        let allSessions = sessions.sessions
        let allEvents = calendar.todayEvents
        let vp = vaultPath

        Task.detached(priority: .userInitiated) {
            let result = Self.buildProjects(
                vaultPath: vp,
                sessions: allSessions,
                events: allEvents
            )
            await MainActor.run { [weak self] in
                self?.projects = result
                self?.isLoading = false
            }
        }
    }

    /// Lazy-load emails and people for a project (called on card expand)
    func loadIntel(for project: Project) {
        guard intel[project.id] == nil else { return }

        intel[project.id] = ProjectIntel(id: project.id, emails: [], people: [], isLoading: true)

        let terms = project.folderTerms
        let events = project.upcomingEvents

        Task.detached(priority: .userInitiated) { [weak self] in
            do {
                // Single batched query via SparkService
                let sparkResults = SparkService.searchEmails(terms: terms, limit: 5, includeBody: true)

                // Look up actual sender email addresses from messages table
                var senderEmails: [String: String] = [:]
                if let msgPath = SparkService.msgPath, !sparkResults.isEmpty {
                    let pks = sparkResults.map(\.pk).joined(separator: ",")
                    let sql = "SELECT pk, messageFromMailbox, messageFromDomain FROM messages WHERE pk IN (\(pks))"
                    if let rows = SparkService.runSQLite(dbPath: msgPath, sql: sql) {
                        for row in rows {
                            let cols = row.split(separator: "|", maxSplits: 2, omittingEmptySubsequences: false)
                            if cols.count >= 3 {
                                senderEmails[String(cols[0])] = "\(cols[1])@\(cols[2])".lowercased()
                            }
                        }
                    }
                }

                let emails = sparkResults.map { r in
                    ProjectEmail(subject: r.subject, from: r.from,
                                 fromEmail: senderEmails[r.pk] ?? "",
                                 date: r.date, epoch: r.epoch, body: r.body, messagePk: r.pk)
                }
                let people = Self.aggregatePeople(events: events, emails: emails)
                await MainActor.run {
                    self?.intel[project.id] = ProjectIntel(id: project.id, emails: emails, people: people)
                }
            } catch {
                await MainActor.run {
                    self?.intel[project.id] = ProjectIntel(id: project.id, emails: [], people: [])
                }
            }
        }
    }

    func invalidateIntel(projectId: String) {
        intel.removeValue(forKey: projectId)
    }

    // MARK: - Project Discovery

    /// Vault folders that are never projects (shared infrastructure folders).
    /// Exposed so other services (e.g. SlackService channel sync) apply the
    /// same exclusion as project discovery.
    nonisolated static let excludedFolderNames: Set<String> = [
        "Templates", "Daily Notes", "Attachments", "Assets", "Archive",
        // `Claude/` is the claimless tooling-reference folder (schema.md):
        // never a project / session-mapping target, so never a Slack channel.
        "Claude"
    ]

    nonisolated private static func buildProjects(
        vaultPath: String,
        sessions: [SessionInfo],
        events: [CalendarEvent]
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

            // Match calendar events
            let folderTerms = folder
                .components(separatedBy: CharacterSet.alphanumerics.inverted)
                .filter { $0.count > 2 }
                .map { $0.lowercased() }

            let matchedEvents = events.filter { event in
                let titleLower = event.title.lowercased()
                return folderTerms.contains { titleLower.contains($0) }
            }

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
                upcomingEvents: matchedEvents,
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

    // MARK: - People Aggregation

    nonisolated private static func aggregatePeople(events: [CalendarEvent], emails: [ProjectEmail]) -> [Contact] {
        var contactsByEmail: [String: Contact] = [:]
        let now = Date()

        // From calendar events
        for event in events {
            for attendee in event.attendees {
                let key = attendee.email.lowercased()
                if ContactService.isCurrentUserEmail(key) { continue }
                if attendee.name == "Unknown" { continue }

                if var existing = contactsByEmail[key] {
                    existing.sources.insert(.calendar)
                    contactsByEmail[key] = existing
                } else {
                    let domain = attendee.email.split(separator: "@").last.map(String.init) ?? ""
                    contactsByEmail[key] = Contact(
                        id: key,
                        name: ContactService.cleanName(attendee.name),
                        email: attendee.email,
                        org: ContactService.orgFromDomain(domain),
                        lastSeen: now,
                        sources: [.calendar],
                        manualOverride: false
                    )
                }
            }
        }

        // From emails (using actual email address)
        for email in emails {
            let key = email.fromEmail.lowercased()
            guard !key.isEmpty, key.contains("@") else { continue }
            if ContactService.isCurrentUserEmail(key) { continue }

            if var existing = contactsByEmail[key] {
                existing.sources.insert(.email)
                contactsByEmail[key] = existing
            } else {
                let domain = key.split(separator: "@").last.map(String.init) ?? ""
                contactsByEmail[key] = Contact(
                    id: key,
                    name: ContactService.cleanName(email.from),
                    email: email.fromEmail,
                    org: ContactService.orgFromDomain(domain),
                    lastSeen: now,
                    sources: [.email],
                    manualOverride: false
                )
            }
        }

        let result = Array(contactsByEmail.values)
        ContactService.mergeContacts(result)
        return result.sorted { $0.name < $1.name }
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

    // MARK: - GitHub Info

    /// Trigger a `gh repo view` lookup for the given path if we don't already
    /// have a fresh cached answer. Idempotent and cheap to call from `onAppear`.
    /// Worktree paths are normalized to their parent so a project's worktrees
    /// share one cache entry with the parent repo.
    func refreshGitHubInfo(forPath rawPath: String) {
        let path = Self.canonicalRepoPath(rawPath)
        if gitHubInflight.contains(path) { return }

        if let cached = loadGitHubCacheEntry(path: path),
           Date().timeIntervalSince(cached.resolvedAt) < Self.gitHubMaxAge {
            if gitHubInfo[path] == nil {
                gitHubInfo[path] = cached.info
            }
            return
        }

        gitHubInflight.insert(path)

        Task.detached(priority: .utility) {
            let outcome = await Self.resolveGitHubInfo(projectPath: path)
            // Only persist confirmed answers. Transient failures (gh not
            // authenticated, network down, gh missing entirely) leave the
            // cache untouched so the next view appearance retries.
            switch outcome {
            case .found(let info):
                Self.saveGitHubCacheEntry(path: path, info: info)
                await MainActor.run { [weak self] in
                    self?.gitHubInfo[path] = info
                    self?.gitHubInflight.remove(path)
                }
            case .absent:
                Self.saveGitHubCacheEntry(path: path, info: nil)
                await MainActor.run { [weak self] in
                    self?.gitHubInfo[path] = .some(nil)
                    self?.gitHubInflight.remove(path)
                }
            case .transientFailure:
                await MainActor.run { [weak self] in
                    self?.gitHubInflight.remove(path)
                }
            }
        }
    }

    /// Look up cached GitHub info by raw project path; applies the same
    /// canonicalization as `refreshGitHubInfo` so callers don't have to.
    func gitHubInfo(forPath rawPath: String) -> GitHubRepoInfo? {
        gitHubInfo[Self.canonicalRepoPath(rawPath)] ?? nil
    }

    /// Strip `/.claude/worktrees/<branch>` suffixes so worktree paths key
    /// against the parent repo's GitHub info.
    private static func canonicalRepoPath(_ rawPath: String) -> String {
        if let range = rawPath.range(of: "/.claude/worktrees/") {
            return String(rawPath[..<range.lowerBound])
        }
        return rawPath
    }

    private func loadGitHubCache() {
        let fm = FileManager.default
        if !fm.fileExists(atPath: Self.gitHubCacheDir) {
            try? fm.createDirectory(atPath: Self.gitHubCacheDir, withIntermediateDirectories: true)
            return
        }
        guard let files = try? fm.contentsOfDirectory(atPath: Self.gitHubCacheDir) else { return }
        for file in files where file.hasSuffix(".json") {
            let path = "\(Self.gitHubCacheDir)/\(file)"
            guard let data = fm.contents(atPath: path),
                  let cached = try? JSONDecoder().decode(CachedGitHubInfo.self, from: data),
                  let key = cached.path
            else { continue }
            gitHubInfo[key] = cached.info
        }
    }

    private func loadGitHubCacheEntry(path: String) -> CachedGitHubInfo? {
        let filename = Self.cacheFilename(forPath: path)
        let cachePath = "\(Self.gitHubCacheDir)/\(filename)"
        guard let data = FileManager.default.contents(atPath: cachePath),
              let cached = try? JSONDecoder().decode(CachedGitHubInfo.self, from: data) else {
            return nil
        }
        return cached
    }

    nonisolated private static func saveGitHubCacheEntry(path: String, info: GitHubRepoInfo?) {
        let fm = FileManager.default
        if !fm.fileExists(atPath: gitHubCacheDir) {
            try? fm.createDirectory(atPath: gitHubCacheDir, withIntermediateDirectories: true)
        }
        let cached = CachedGitHubInfo(info: info, resolvedAt: Date(), path: path)
        guard let data = try? JSONEncoder().encode(cached) else { return }
        let filename = cacheFilename(forPath: path)
        fm.createFile(atPath: "\(gitHubCacheDir)/\(filename)", contents: data)
    }

    /// Hash absolute paths into stable, filesystem-safe filenames. Avoids the
    /// path-mangling issues of "replace `/` with `_`" while keeping cache files
    /// keyed deterministically.
    nonisolated private static func cacheFilename(forPath path: String) -> String {
        var hash: UInt64 = 14695981039346656037
        for byte in path.utf8 {
            hash ^= UInt64(byte)
            hash = hash &* 1099511628211
        }
        return String(format: "%016llx.json", hash)
    }

    /// Three-state result of resolving GitHub info. `transientFailure` covers
    /// "gh not authenticated", "network down", "gh not on PATH" — anything
    /// where the answer is unknown rather than confirmed-absent.
    private enum GitHubResolution {
        case found(GitHubRepoInfo)
        case absent
        case transientFailure
    }

    nonisolated private static func resolveGitHubInfo(projectPath: String) async -> GitHubResolution {
        // First decide via git: is this a repo at all, and does it have a
        // remote? This separates "no remote" (cheap, deterministic) from
        // "gh failed for some other reason" (which we should never cache).
        switch detectGitRemote(projectPath: projectPath) {
        case .notARepo, .noRemote:
            return .absent
        case .undetermined:
            // git itself was unavailable or errored — treat as transient.
            return .transientFailure
        case .hasRemote(let remoteURL):
            // Only consider it a GitHub remote if the URL looks like one.
            // Anything else (GitLab, Bitbucket, self-hosted) is "absent" for
            // the purposes of this indicator, which is GitHub-specific.
            guard remoteURL.contains("github.com") else { return .absent }
            return await runGhRepoView(projectPath: projectPath)
        }
    }

    private enum GitRemoteDetection {
        case hasRemote(String)
        case noRemote
        case notARepo
        case undetermined
    }

    nonisolated private static func detectGitRemote(projectPath: String) -> GitRemoteDetection {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = ["git", "-C", projectPath, "config", "--get", "remote.origin.url"]
        let stdout = Pipe()
        let stderr = Pipe()
        process.standardOutput = stdout
        process.standardError = stderr
        do {
            try process.run()
            let data = stdout.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            let raw = String(data: data, encoding: .utf8)?
                .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            // git config exits 0 with the URL on success, 1 when the key is
            // unset (= no remote), and 128 when not a git repo. Anything else
            // is an environmental problem we can't classify.
            switch process.terminationStatus {
            case 0:
                return raw.isEmpty ? .noRemote : .hasRemote(raw)
            case 1:
                return .noRemote
            case 128:
                return .notARepo
            default:
                return .undetermined
            }
        } catch {
            return .undetermined
        }
    }

    nonisolated private static func runGhRepoView(projectPath: String) async -> GitHubResolution {
        // Prefer well-known install locations; fall back to `/usr/bin/env gh`
        // so PATH lookup still finds installs from asdf/nix/MacPorts/etc.
        let process = Process()
        if let direct = ["/opt/homebrew/bin/gh", "/usr/local/bin/gh"]
            .first(where: { FileManager.default.isExecutableFile(atPath: $0) })
        {
            process.executableURL = URL(fileURLWithPath: direct)
            process.arguments = ["repo", "view", "--json", "nameWithOwner,visibility,url"]
        } else {
            process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
            process.arguments = ["gh", "repo", "view", "--json", "nameWithOwner,visibility,url"]
        }
        process.currentDirectoryURL = URL(fileURLWithPath: projectPath)

        let stdout = Pipe()
        let stderr = Pipe()
        process.standardOutput = stdout
        process.standardError = stderr

        do {
            try process.run()
            let data = stdout.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            guard process.terminationStatus == 0,
                  let raw = String(data: data, encoding: .utf8),
                  let jsonData = raw.data(using: .utf8),
                  let json = try? JSONSerialization.jsonObject(with: jsonData) as? [String: Any],
                  let nameWithOwner = json["nameWithOwner"] as? String,
                  let url = json["url"] as? String,
                  let visibility = json["visibility"] as? String
            else {
                // gh failed for some reason. We already confirmed via git
                // that there *is* a github.com remote, so this is transient
                // (auth lapsed, rate limited, network blip).
                return .transientFailure
            }
            return .found(GitHubRepoInfo(
                nameWithOwner: nameWithOwner,
                url: url,
                isPrivate: visibility.uppercased() != "PUBLIC"
            ))
        } catch {
            return .transientFailure
        }
    }

}
