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
            guard !["Templates", "Daily Notes", "Attachments", "Assets", "Archive"].contains(folder) else { continue }

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

    nonisolated private static func normalize(_ name: String) -> String {
        name.lowercased()
            .replacingOccurrences(of: "-", with: "")
            .replacingOccurrences(of: "_", with: "")
            .replacingOccurrences(of: " ", with: "")
            .replacingOccurrences(of: ".", with: "")
    }

    nonisolated private static func fuzzyMatch(_ a: String, _ b: String) -> Bool {
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
