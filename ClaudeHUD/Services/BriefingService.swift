import Contacts
import Foundation
import os

private let logger = Logger(subsystem: "com.claudehud", category: "BriefingService")

struct EventBriefing: Identifiable {
    let id: String // event id
    let emailThreads: [EmailThread]
    let relatedNotes: [RelatedNote]
    let relatedProjects: [String] // project names from ProjectService
    let summary: String? // Claude-generated
    var isLoading: Bool = false
}

struct EmailThread: Identifiable {
    let id = UUID()
    let subject: String
    let participants: String
    let date: String
    let snippet: String
    let messagePk: String
}

struct RelatedNote: Identifiable {
    let id = UUID()
    let name: String
    let path: String
    let preview: String
}

@MainActor
class BriefingService: ObservableObject {
    @Published var briefings: [String: EventBriefing] = [:]

    private static let cacheDir: String = {
        let dir = "\(NSHomeDirectory())/.claude/hud/briefings"
        try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        return dir
    }()

    // DB paths provided by SparkService

    /// Preload briefings for all events (call on tab appear)
    func preloadAll(events: [CalendarEvent], vaultPath: String?, projects: [Project]) {
        for event in events where !event.isAllDay {
            generateBriefing(for: event, vaultPath: vaultPath, projects: projects)
        }
    }

    /// Generate briefing for an event using local data sources
    func generateBriefing(for event: CalendarEvent, vaultPath: String?, projects: [Project] = []) {
        guard briefings[event.id] == nil else { return }

        // Check disk cache for Claude summary
        let cachedSummary = Self.loadCachedSummary(eventId: event.id)

        briefings[event.id] = EventBriefing(
            id: event.id,
            emailThreads: [],
            relatedNotes: [],
            relatedProjects: [],
            summary: cachedSummary,
            isLoading: cachedSummary == nil
        )

        Task.detached(priority: .userInitiated) { [weak self] in
            let emails = await self?.searchEmails(for: event) ?? []
            let notes = self?.searchNotes(for: event, vaultPath: vaultPath) ?? []

            // Match projects by event title keywords
            let titleTerms = event.title
                .components(separatedBy: CharacterSet.alphanumerics.inverted)
                .filter { $0.count > 2 }
                .map { $0.lowercased() }
            let matchedProjects = projects.filter { project in
                let projNorm = project.name.lowercased()
                return titleTerms.contains { projNorm.contains($0) || $0.contains(projNorm) }
            }.map(\.name)

            // Resolve attendee names
            let others = event.attendees.filter { !Self.isCurrentUser($0) }
            let people = Self.resolveNames(others)

            // Show raw data immediately while Claude generates the summary
            await MainActor.run {
                self?.briefings[event.id] = EventBriefing(
                    id: event.id,
                    emailThreads: emails,
                    relatedNotes: notes,
                    relatedProjects: matchedProjects,
                    summary: nil,
                    isLoading: true
                )
            }

            // Generate intelligent summary via Claude (skip if cached)
            let summary: String?
            if cachedSummary != nil {
                summary = cachedSummary
            } else {
                summary = await Self.generateClaudeSummary(
                    event: event, people: people, emails: emails,
                    notes: notes, projects: matchedProjects, vaultPath: vaultPath
                )
                // Cache to disk
                if let s = summary {
                    Self.saveCachedSummary(eventId: event.id, summary: s)
                }
            }

            await MainActor.run {
                self?.briefings[event.id] = EventBriefing(
                    id: event.id,
                    emailThreads: emails,
                    relatedNotes: notes,
                    relatedProjects: matchedProjects,
                    summary: summary,
                    isLoading: false
                )
            }
        }
    }

    /// Call Claude (haiku) to synthesize a meeting briefing from raw intel
    nonisolated private static func generateClaudeSummary(
        event: CalendarEvent,
        people: [String],
        emails: [EmailThread],
        notes: [RelatedNote],
        projects: [String],
        vaultPath: String?
    ) async -> String? {
        // Build context for Claude
        var context = "Meeting: \(event.title)\n"
        context += "Time: \(event.startDate)\n"
        if let loc = event.location { context += "Location: \(loc)\n" }
        if !people.isEmpty { context += "Attendees: \(people.joined(separator: ", "))\n" }
        if !projects.isEmpty { context += "Related project: \(projects.joined(separator: ", "))\n" }

        // Add email subjects and snippets (first 3, stripped)
        let substantive = emails.filter { e in
            let s = e.snippet.lowercased()
            let subj = e.subject.lowercased()
            if s.hasPrefix("invite.ics") || s.hasPrefix("reply.ics") { return false }
            if subj.hasPrefix("accepted:") || subj.hasPrefix("declined:") { return false }
            return true
        }
        if !substantive.isEmpty {
            context += "\nRecent email threads:\n"
            for email in substantive.prefix(3) {
                context += "- \(email.subject) (from \(email.participants), \(email.date))\n"
                if !email.snippet.isEmpty {
                    let clean = email.snippet
                        .replacingOccurrences(of: "\n", with: " ")
                        .replacingOccurrences(of: "  ", with: " ")
                    context += "  \(String(clean.prefix(300)))\n"
                }
            }
        }

        // Add note content (first note, truncated)
        for note in notes.prefix(2) {
            if let content = try? String(contentsOfFile: note.path, encoding: .utf8) {
                let truncated = String(content.prefix(500))
                context += "\nNote (\(note.name)):\n\(truncated)\n"
            }
        }

        let prompt = """
        You are preparing a brief meeting prep note. Based on the context below, write 2-3 sentences covering:
        1. What this meeting is about and what project/initiative it advances
        2. Key recent developments from the emails (decisions made, action items, open questions)
        3. What the user should prepare or be ready to discuss

        Be specific and actionable. Use names. No filler, no headers.
        Do NOT repeat the meeting title, date, or time — the user already sees that.
        Do NOT use markdown formatting (no bold, no headers).
        You may use short bullet points (plain dash) for action items or key points.
        Start directly with what this is about. If there's not enough context, say what's known and note what to clarify.

        Context:
        \(context)
        """

        // Run claude -p with haiku for speed
        return await withCheckedContinuation { continuation in
            let process = Process()
            let claudePaths = [
                "\(NSHomeDirectory())/.local/bin/claude",
                "/usr/local/bin/claude",
                "/opt/homebrew/bin/claude",
                "\(NSHomeDirectory())/.npm-global/bin/claude",
                "\(NSHomeDirectory())/.claude/local/claude",
            ]
            let claudePath = claudePaths.first { FileManager.default.fileExists(atPath: $0) } ?? "claude"

            process.executableURL = URL(fileURLWithPath: claudePath)
            process.arguments = ["-p", prompt, "--model", "haiku", "--max-turns", "1"]

            let pipe = Pipe()
            process.standardOutput = pipe
            process.standardError = Pipe()

            do {
                try process.run()
                process.waitUntilExit()
                let data = pipe.fileHandleForReading.readDataToEndOfFile()
                let output = String(data: data, encoding: .utf8)?
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                continuation.resume(returning: output?.isEmpty == false ? output : nil)
            } catch {
                continuation.resume(returning: nil)
            }
        }
    }

    /// Fetch email body from FTS index, stripping quoted reply chains
    func fetchFullBody(messagePk: String) async -> String? {
        guard let ftsPath = SparkService.ftsPath else { return nil }
        return await Task.detached {
            let sql = "SELECT searchBody FROM messagesfts WHERE messagePk = \(messagePk) LIMIT 1"
            guard let results = SparkService.runSQLite(dbPath: ftsPath, sql: sql),
                  let first = results.first else { return nil as String? }
            return Self.stripQuotedReplies(first)
        }.value
    }

    /// Build a prose briefing from available intel
    nonisolated private static func buildSummary(
        event: CalendarEvent,
        emails: [EmailThread],
        notes: [RelatedNote],
        projects: [String]
    ) -> String? {
        var sentences: [String] = []

        // People — resolve emails to real names via Spark
        let others = event.attendees
            .filter { !$0.email.lowercased().contains("daniels") && !$0.email.lowercased().contains("bbdaniels") }
        let people = resolveNames(others)

        // Opening: who and what
        if !people.isEmpty && !projects.isEmpty {
            sentences.append("Meeting with \(naturalList(people)) about \(projects.joined(separator: " / ")).")
        } else if !people.isEmpty {
            sentences.append("Meeting with \(naturalList(people)).")
        } else if !projects.isEmpty {
            sentences.append("Related to \(projects.joined(separator: " / ")).")
        }

        // Email intel — just count and key subjects, no raw body content
        let substantiveEmails = emails.filter { email in
            let subj = email.subject.lowercased()
            let s = email.snippet.lowercased()
            if s.hasPrefix("invite.ics") || s.hasPrefix("reply.ics") { return false }
            if subj.hasPrefix("accepted:") || subj.hasPrefix("declined:") || subj.hasPrefix("tentative:") { return false }
            return true
        }

        if !substantiveEmails.isEmpty {
            // Get unique subject lines (without Re:/Fwd: prefixes)
            let subjects = Array(Set(substantiveEmails.map { subj in
                subj.subject
                    .replacingOccurrences(of: "^(Re|Fwd|RE|FW): *", with: "", options: .regularExpression)
            })).prefix(3)

            if subjects.count == 1 {
                sentences.append("Recent thread: \(subjects[0]).")
            } else {
                sentences.append("Recent threads: \(subjects.joined(separator: "; ")).")
            }
        }

        // Notes intel — deduplicate, just name them
        let uniqueNotes = notes.reduce(into: [String: RelatedNote]()) { dict, note in
            let key = URL(fileURLWithPath: note.path).lastPathComponent
            if dict[key] == nil { dict[key] = note }
        }.values.sorted { $0.name < $1.name }

        if !uniqueNotes.isEmpty {
            sentences.append("See notes: \(uniqueNotes.map(\.name).joined(separator: ", ")).")
        }

        if sentences.isEmpty { return nil }
        return sentences.joined(separator: " ")
    }

    /// Name + org cache: email → (name, org)
    nonisolated(unsafe) static var nameCache: [String: (name: String, org: String)] = [:]

    /// Check if this is the user's own email
    nonisolated static func isCurrentUser(_ person: PersonInfo) -> Bool {
        let e = person.email.lowercased()
        return e.contains("bbdaniels") || e.contains("bdaniels") || e.contains("bd581")
    }

    /// Public accessor for resolved names (used by views)
    nonisolated static func resolvedName(for person: PersonInfo) -> String {
        if isCurrentUser(person) { return NSFullUserName() }
        let key = person.email.lowercased()
        if let cached = nameCache[key], !cached.name.isEmpty {
            return cleanName(cached.name)
        }
        let name = person.name
        if name.contains("@") || name == "Unknown" { return person.email }
        return cleanName(name)
    }

    /// Public accessor for resolved org
    nonisolated static func resolvedOrg(for person: PersonInfo) -> String? {
        if isCurrentUser(person) { return nil }
        // Check cache
        if let org = nameCache[person.email.lowercased()]?.org, !org.isEmpty {
            return org
        }
        // Fall back to domain-based org
        let domain = person.email.split(separator: "@").last.map(String.init) ?? ""
        let org = orgFromDomain(domain)
        return org.isEmpty ? nil : org
    }

    /// Resolve all attendees — always look up every email
    nonisolated private static func resolveNames(_ people: [PersonInfo]) -> [String] {
        let allEmails = people.map(\.email)

        // Only look up emails not yet cached
        let uncached = allEmails.filter { nameCache[$0.lowercased()] == nil }
        if !uncached.isEmpty {
            let resolved = lookupNames(emails: uncached)
            for (email, info) in resolved {
                nameCache[email.lowercased()] = info
            }
        }

        return people.map { displayName($0) }.filter { !$0.isEmpty }
    }

    nonisolated private static func displayName(_ person: PersonInfo) -> String {
        let key = person.email.lowercased()
        if let cached = nameCache[key], !cached.name.isEmpty {
            return cleanName(cached.name)
        }
        let name = person.name
        if name.contains("@") || name == "Unknown" { return "" }
        return cleanName(name)
    }

    nonisolated private static func cleanName(_ name: String) -> String {
        var n = name.replacingOccurrences(of: "\"", with: "").trimmingCharacters(in: .whitespaces)

        // "Last, First Middle" → "First Middle Last"
        // But preserve suffixes: "Last, First, MD" → "First Last, MD"
        if n.contains(", ") {
            let parts = n.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }
            if parts.count >= 2 {
                let last = parts[0]
                let first = parts[1]
                // Check if remaining parts are suffixes (MD, PhD, Jr, etc.)
                let suffixes = parts.dropFirst(2).joined(separator: ", ")
                n = suffixes.isEmpty ? "\(first) \(last)" : "\(first) \(last), \(suffixes)"
            }
        }

        // Title-case each word (handles all-lowercase names from headers)
        n = n.split(separator: " ").map { word in
            let w = String(word)
            // Don't capitalize suffixes/abbreviations that are already uppercase-ish
            if w.count <= 3 && w == w.uppercased() { return w }
            // Capitalize first letter of each word
            return w.prefix(1).uppercased() + w.dropFirst()
        }.joined(separator: " ")

        return n
    }

    /// Look up names from: 1) Spark contacts, 2) message From/To headers, 3) macOS Contacts
    nonisolated private static func lookupNames(emails: [String]) -> [String: (name: String, org: String)] {
        var results: [String: (name: String, org: String)] = [:]

        // 1. Spark contacts DB
        if let msgPath = SparkService.msgPath {
            let emailList = emails.map { "'\($0.lowercased())'" }.joined(separator: ",")
            let sql = "SELECT name, email FROM contacts WHERE email IN (\(emailList)) AND name IS NOT NULL AND name != ''"
            if let rows = SparkService.runSQLite(dbPath: msgPath, sql: sql) {
                for row in rows {
                    let cols = row.split(separator: "|", maxSplits: 1)
                    if cols.count == 2 {
                        let name = String(cols[0])
                        let email = String(cols[1]).lowercased()
                        if !name.isEmpty && !name.contains("@") {
                            results[email] = (name: name, org: "")
                        }
                    }
                }
            }

            // 2. Message headers for unresolved — extract name paired with the specific email
            let unresolved = emails.filter { results[$0.lowercased()] == nil }
            for email in unresolved {
                let escaped = email.replacingOccurrences(of: "'", with: "''")
                // Check From headers first (most reliable — single sender)
                let fromSQL = "SELECT DISTINCT messageFrom FROM messages WHERE messageFromMailbox = '\(escaped.split(separator: "@").first ?? "")' AND messageFromDomain = '\(escaped.split(separator: "@").last ?? "")' LIMIT 1"
                if let rows = SparkService.runSQLite(dbPath: msgPath, sql: fromSQL), let row = rows.first {
                    let name = SparkService.extractDisplayName(from: row)
                    if !name.isEmpty && !name.contains("@") {
                        let domain = email.split(separator: "@").last.map(String.init) ?? ""
                        results[email.lowercased()] = (name: name, org: orgFromDomain(domain))
                        continue
                    }
                }
                // Check To/Cc headers — parse out the specific entry for this email
                let toSQL = "SELECT DISTINCT messageTo FROM messages WHERE messageTo LIKE '%\(escaped)%' LIMIT 3"
                if let rows = SparkService.runSQLite(dbPath: msgPath, sql: toSQL) {
                    for row in rows {
                        if let name = extractNameForEmail(email: email, fromHeader: row) {
                            let domain = email.split(separator: "@").last.map(String.init) ?? ""
                            results[email.lowercased()] = (name: name, org: orgFromDomain(domain))
                            break
                        }
                    }
                }
            }
        }

        // 3. macOS Contacts (CNContactStore) for still unresolved
        let stillUnresolved = emails.filter { results[$0.lowercased()] == nil }
        if !stillUnresolved.isEmpty {
            let contactResults = lookupMacOSContacts(emails: stillUnresolved)
            for (email, info) in contactResults {
                results[email] = info
            }
        }

        return results
    }

    /// Look up names from macOS Contacts framework
    nonisolated private static func lookupMacOSContacts(emails: [String]) -> [String: (name: String, org: String)] {
        var results: [String: (name: String, org: String)] = [:]

        let store = CNContactStore()
        let keysToFetch: [CNKeyDescriptor] = [
            CNContactGivenNameKey as CNKeyDescriptor,
            CNContactFamilyNameKey as CNKeyDescriptor,
            CNContactOrganizationNameKey as CNKeyDescriptor,
            CNContactEmailAddressesKey as CNKeyDescriptor,
        ]

        for email in emails {
            let predicate = CNContact.predicateForContacts(matchingEmailAddress: email)
            if let contacts = try? store.unifiedContacts(matching: predicate, keysToFetch: keysToFetch),
               let contact = contacts.first {
                let name = [contact.givenName, contact.familyName]
                    .filter { !$0.isEmpty }
                    .joined(separator: " ")
                if !name.isEmpty {
                    results[email.lowercased()] = (name: name, org: contact.organizationName)
                }
            }
        }

        return results
    }

    /// Extract the display name specifically paired with an email in a header like:
    /// "Name One <one@x.com>, Name Two <two@x.com>"
    nonisolated private static func extractNameForEmail(email: String, fromHeader header: String) -> String? {
        let emailLower = email.lowercased()
        // Split on comma to get individual entries
        let entries = header.components(separatedBy: ",")
        for entry in entries {
            let trimmed = entry.trimmingCharacters(in: .whitespaces)
            guard trimmed.lowercased().contains(emailLower) else { continue }
            // Extract name before <email>
            let name = SparkService.extractDisplayName(from: trimmed)
            if !name.isEmpty && !name.contains("@") {
                return name
            }
        }
        return nil
    }

    /// Guess organization from email domain
    nonisolated private static func orgFromDomain(_ domain: String) -> String {
        let d = domain.lowercased()
        if d.contains("harvard") { return "Harvard" }
        if d.contains("novartis") { return "Novartis" }
        if d.contains("georgetown") { return "Georgetown" }
        if d.hasSuffix(".edu") {
            let parts = d.split(separator: ".")
            if parts.count >= 2 { return String(parts[parts.count - 2]).capitalized }
        }
        if d.hasSuffix(".gov") { return String(d.split(separator: ".").first ?? "").uppercased() }
        // Generic: use second-level domain
        let parts = d.split(separator: ".")
        if parts.count >= 2 && !["gmail", "yahoo", "hotmail", "outlook", "icloud", "me", "aol"].contains(String(parts[0])) {
            return String(parts[0]).capitalized
        }
        return ""
    }

    /// Join names naturally: "A", "A and B", "A, B, and C"
    nonisolated private static func naturalList(_ items: [String]) -> String {
        switch items.count {
        case 0: return ""
        case 1: return items[0]
        case 2: return "\(items[0]) and \(items[1])"
        default: return items.dropLast().joined(separator: ", ") + ", and " + items.last!
        }
    }

    /// Strip quoted reply chains, signatures, and forwarded content
    nonisolated private static func stripQuotedReplies(_ body: String) -> String {
        let lines = body.components(separatedBy: "\n")
        var cleaned: [String] = []

        for line in lines {
            let trimmed = line.trimmingCharacters(in: .whitespaces)

            // Stop at common reply/forward markers
            if trimmed.hasPrefix(">") { break }
            if trimmed.hasPrefix("On ") && trimmed.contains(" wrote:") { break }
            if trimmed.hasPrefix("From:") && trimmed.contains("@") { break }
            if trimmed == "---" || trimmed == "___" { break }
            if trimmed.hasPrefix("-----Original Message") { break }
            if trimmed.hasPrefix("________________________________") { break }
            if trimmed.hasPrefix("Begin forwarded message") { break }
            // Outlook-style separator
            if trimmed.hasPrefix("_____") { break }

            cleaned.append(line)
        }

        // Trim trailing whitespace
        while cleaned.last?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == true {
            cleaned.removeLast()
        }

        return cleaned.joined(separator: "\n")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Clear all cached briefings (e.g. when calendar changes)
    func invalidateAll() {
        briefings.removeAll()
        // Clear today's disk cache
        Self.clearDiskCache()
    }

    func invalidate(eventId: String) {
        briefings.removeValue(forKey: eventId)
        Self.removeCachedSummary(eventId: eventId)
    }

    // MARK: - Disk Cache

    /// Cache key includes date so stale briefings from yesterday auto-expire
    nonisolated private static func cacheKey(_ eventId: String) -> String {
        let fmt = DateFormatter()
        fmt.dateFormat = "yyyy-MM-dd"
        return "\(fmt.string(from: Date()))_\(eventId.hashValue)"
    }

    nonisolated private static func loadCachedSummary(eventId: String) -> String? {
        let path = "\(cacheDir)/\(cacheKey(eventId)).txt"
        return try? String(contentsOfFile: path, encoding: .utf8)
    }

    nonisolated private static func saveCachedSummary(eventId: String, summary: String) {
        let path = "\(cacheDir)/\(cacheKey(eventId)).txt"
        try? summary.write(toFile: path, atomically: true, encoding: .utf8)
    }

    nonisolated private static func removeCachedSummary(eventId: String) {
        let path = "\(cacheDir)/\(cacheKey(eventId)).txt"
        try? FileManager.default.removeItem(atPath: path)
    }

    nonisolated private static func clearDiskCache() {
        let fm = FileManager.default
        guard let files = try? fm.contentsOfDirectory(atPath: cacheDir) else { return }
        for file in files {
            try? fm.removeItem(atPath: "\(cacheDir)/\(file)")
        }
    }

    // MARK: - Email Search

    nonisolated private func searchEmails(for event: CalendarEvent) async -> [EmailThread] {
        // Build search terms from event title and attendee names
        var searchTerms: [String] = []

        // Title words (skip common words)
        let skipWords: Set<String> = ["meeting", "call", "sync", "weekly", "daily", "internal",
                                       "external", "team", "the", "and", "with", "for", "review"]
        let titleWords = event.title.split(separator: " ")
            .map { String($0).lowercased() }
            .filter { $0.count > 2 && !skipWords.contains($0) }
        if !titleWords.isEmpty {
            searchTerms.append(titleWords.joined(separator: " "))
        }

        // Attendee names (more specific searches)
        let attendeeNames = event.attendees
            .filter { $0.name != "Unknown" && !$0.email.contains("bbdaniels") && !$0.email.contains("bdaniels") }
            .map(\.name)

        // Search by title keywords first, then by each attendee
        var results: [EmailThread] = []
        var seenSubjects: Set<String> = []

        for term in searchTerms {
            let found = await searchSpark(query: term, limit: 8)
            for thread in found where !seenSubjects.contains(thread.subject) {
                results.append(thread)
                seenSubjects.insert(thread.subject)
            }
        }

        for name in attendeeNames.prefix(3) {
            let found = await searchSpark(query: name, limit: 5)
            for thread in found where !seenSubjects.contains(thread.subject) {
                results.append(thread)
                seenSubjects.insert(thread.subject)
            }
        }

        return Array(results.prefix(8))
    }

    nonisolated private func searchSpark(query: String, limit: Int) async -> [EmailThread] {
        guard let ftsPath = SparkService.ftsPath else { return [] }
        let msgPath = SparkService.msgPath

        return await Task.detached {
            Self.querySparkDB(ftsPath: ftsPath, msgPath: msgPath, query: query, limit: limit)
        }.value
    }

    /// Query Spark's FTS index for matching emails, then look up dates + bodies from messages DB
    nonisolated private static func querySparkDB(ftsPath: String, msgPath: String?,
                                                  query: String, limit: Int) -> [EmailThread] {
        // FTS5 table: messagesfts(messagePk, messageFrom, messageTo, subject, searchBody, additionalText)
        let escaped = query.replacingOccurrences(of: "'", with: "''")
            .replacingOccurrences(of: "\"", with: "")
        let sql = """
        SELECT messagePk, messageFrom, subject
        FROM messagesfts
        WHERE messagesfts MATCH '"\(escaped)"'
        ORDER BY rowid DESC
        LIMIT \(limit * 2)
        """

        guard let ftsResults = SparkService.runSQLite(dbPath: ftsPath, sql: sql) else { return [] }

        // Collect messagePks for date/body lookup
        var pks: [String] = []
        var ftsData: [(pk: String, from: String, subject: String)] = []

        for line in ftsResults {
            let cols = line.components(separatedBy: "|")
            guard cols.count >= 3 else { continue }
            pks.append(cols[0])
            ftsData.append((pk: cols[0], from: cols[1], subject: cols[2]))
        }

        // Look up dates and body snippets from messages DB
        var msgInfo: [String: (date: String, body: String, epoch: Double)] = [:]
        if let msgPath = msgPath, !pks.isEmpty {
            let fmt = DateFormatter()
            fmt.dateFormat = "MMM d"

            let idList = pks.joined(separator: ",")
            let dateSql = "SELECT pk, receivedDate, shortBody FROM messages WHERE pk IN (\(idList)) ORDER BY receivedDate DESC"
            if let dateResults = SparkService.runSQLite(dbPath: msgPath, sql: dateSql) {
                for line in dateResults {
                    // pk|receivedDate|shortBody (body may contain |)
                    let parts = line.split(separator: "|", maxSplits: 2, omittingEmptySubsequences: false)
                    guard parts.count >= 2 else { continue }
                    let pk = String(parts[0])
                    if let epoch = Double(parts[1]) {
                        let dateStr = fmt.string(from: Date(timeIntervalSince1970: epoch))
                        let body = parts.count > 2 ? String(parts[2]) : ""
                        msgInfo[pk] = (date: dateStr, body: body, epoch: epoch)
                    }
                }
            }
        }

        // Build results, deduplicate by subject, sort by date (newest first)
        var seen: Set<String> = []
        var results: [(thread: EmailThread, epoch: Double)] = []

        for item in ftsData {
            let subjectKey = item.subject.lowercased()
                .replacingOccurrences(of: "re: ", with: "")
                .replacingOccurrences(of: "fwd: ", with: "")
            if seen.contains(subjectKey) { continue }
            seen.insert(subjectKey)

            let name = SparkService.extractDisplayName(from: item.from)
            let info = msgInfo[item.pk]

            results.append((
                thread: EmailThread(
                    subject: item.subject,
                    participants: name,
                    date: info?.date ?? "",
                    snippet: info?.body ?? "",
                    messagePk: item.pk
                ),
                epoch: info?.epoch ?? 0
            ))
        }

        return results
            .sorted { $0.epoch > $1.epoch }
            .prefix(limit)
            .map(\.thread)
    }

    // MARK: - Obsidian Notes Search

    nonisolated private func searchNotes(for event: CalendarEvent, vaultPath: String?) -> [RelatedNote] {
        guard let vaultPath = vaultPath else { return [] }
        let fm = FileManager.default

        // Build search terms
        var terms: [String] = []

        // Event title words (cleaned)
        let skipWords: Set<String> = ["meeting", "call", "sync", "weekly", "daily", "internal",
                                       "external", "team", "the", "and", "with", "for", "review"]
        let titleWords = event.title.split(separator: " ")
            .map { String($0) }
            .filter { $0.count > 2 && !skipWords.contains($0.lowercased()) }
        terms.append(contentsOf: titleWords)

        // Attendee last names
        let lastNames = event.attendees
            .filter { $0.name != "Unknown" }
            .compactMap { $0.name.split(separator: " ").last.map(String.init) }
        terms.append(contentsOf: lastNames)

        guard !terms.isEmpty else { return [] }

        // Search vault: check folder names and file names
        var results: [RelatedNote] = []
        var seen: Set<String> = []

        // First: check if any top-level folder matches a term
        if let folders = try? fm.contentsOfDirectory(atPath: vaultPath) {
            for folder in folders {
                let folderLower = folder.lowercased()
                for term in terms {
                    if folderLower.contains(term.lowercased()) && !seen.contains(folder) {
                        seen.insert(folder)
                        let folderPath = "\(vaultPath)/\(folder)"
                        // Find the best .md file in the folder
                        if let (noteName, notePath, preview) = bestNoteInFolder(folderPath) {
                            results.append(RelatedNote(
                                name: "\(folder)/\(noteName)",
                                path: notePath,
                                preview: preview
                            ))
                        }
                    }
                }
            }
        }

        // Second: grep for terms in note contents (limit to avoid slowness)
        for term in terms.prefix(3) {
            let found = grepVault(vaultPath: vaultPath, term: term, limit: 2)
            for note in found where !seen.contains(note.path) {
                seen.insert(note.path)
                results.append(note)
            }
        }

        return Array(results.prefix(8))
    }

    /// Find the best .md file in a folder: prefer Overview, Technical Notes, or the first .md
    nonisolated private func bestNoteInFolder(_ folderPath: String) -> (name: String, path: String, preview: String)? {
        let fm = FileManager.default
        guard let files = try? fm.contentsOfDirectory(atPath: folderPath) else { return nil }
        let mdFiles = files.filter { $0.hasSuffix(".md") }
        guard !mdFiles.isEmpty else { return nil }

        // Prefer certain names
        let preferred = ["Overview.md", "Technical Notes.md", "README.md"]
        let best = preferred.first { mdFiles.contains($0) } ?? mdFiles.first!

        let path = "\(folderPath)/\(best)"
        let preview: String
        if let content = try? String(contentsOfFile: path, encoding: .utf8) {
            let lines = content.components(separatedBy: "\n")
                .filter { !$0.hasPrefix("---") && !$0.isEmpty && !$0.hasPrefix("#") }
            preview = String(lines.prefix(2).joined(separator: " ").prefix(120))
        } else {
            preview = ""
        }
        return (best.replacingOccurrences(of: ".md", with: ""), path, preview)
    }

    nonisolated private func grepVault(vaultPath: String, term: String, limit: Int) -> [RelatedNote] {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/grep")
        process.arguments = ["-rl", "-i", "--include=*.md", term, vaultPath]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = Pipe()

        do {
            try process.run()
            process.waitUntilExit()
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            guard let output = String(data: data, encoding: .utf8) else { return [] }

            return output.components(separatedBy: "\n")
                .filter { !$0.isEmpty }
                .prefix(limit)
                .map { path in
                    let name = URL(fileURLWithPath: path).lastPathComponent
                        .replacingOccurrences(of: ".md", with: "")
                    // Get short preview
                    let preview: String
                    if let content = try? String(contentsOfFile: path, encoding: .utf8) {
                        let lines = content.components(separatedBy: "\n")
                            .filter { !$0.hasPrefix("---") && !$0.isEmpty }
                        preview = String(lines.prefix(1).joined().prefix(100))
                    } else {
                        preview = ""
                    }
                    return RelatedNote(name: name, path: path, preview: preview)
                }
        } catch {
            return []
        }
    }
}
