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

    private weak var vaultManager: VaultManager?
    private weak var sessionHistory: SessionHistoryService?
    private weak var calendarService: CalendarService?

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

        Task.detached(priority: .userInitiated) {
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
            await MainActor.run { [weak self] in
                self?.intel[project.id] = ProjectIntel(id: project.id, emails: emails, people: people)
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

}
