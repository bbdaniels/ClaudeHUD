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

struct DaySummary {
    var text: String?
    var isLoading: Bool = false
}

@MainActor
class BriefingService: ObservableObject {
    @Published var briefings: [String: EventBriefing] = [:]
    @Published var daySummary: DaySummary?
    private var daySummaryDateKey: String?

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

    /// Generate an intelligent day summary via Claude
    func generateDaySummary(events: [CalendarEvent], date: Date, todos: [TodoItem] = []) {
        let dateKey = Self.dateCacheKey(date)
        // Re-generate if date changed (e.g. midnight rollover)
        if daySummaryDateKey != dateKey {
            daySummary = nil
            daySummaryDateKey = dateKey
        }
        guard daySummary == nil else { return }

        // Check disk cache (include todo count so it regenerates if todos change)
        let cacheKey = "day-\(dateKey)-t\(todos.count)"
        if let cached = Self.loadCachedSummary(eventId: cacheKey) {
            daySummary = DaySummary(text: cached, isLoading: false)
            return
        }

        daySummary = DaySummary(text: nil, isLoading: true)

        Task.detached(priority: .userInitiated) { [weak self] in
            let summary = await Self.generateClaudeDaySummary(events: events, date: date, todos: todos)
            if let s = summary {
                Self.saveCachedSummary(eventId: cacheKey, summary: s)
            }
            await MainActor.run {
                self?.daySummary = DaySummary(text: summary, isLoading: false)
            }
        }
    }

    /// Clear day summary (for date navigation)
    func clearDaySummary() {
        daySummary = nil
        daySummaryDateKey = nil
    }

    /// Claude call for day-level summary
    nonisolated private static func generateClaudeDaySummary(
        events: [CalendarEvent],
        date: Date,
        todos: [TodoItem] = []
    ) async -> String? {
        let timedEvents = events.filter { !$0.isAllDay }
        let allDayEvents = events.filter { $0.isAllDay }
        guard !events.isEmpty || !todos.isEmpty else { return nil }

        let fmt = DateFormatter()
        fmt.dateFormat = "EEEE, MMMM d"
        let dateStr = fmt.string(from: date)

        let timeFmt = DateFormatter()
        timeFmt.dateFormat = "h:mma"

        let isToday = Calendar.current.isDateInToday(date)
        let isTomorrow = Calendar.current.isDateInTomorrow(date)

        var context = "Date: \(dateStr)\n"
        if isToday {
            let nowFmt = DateFormatter()
            nowFmt.dateFormat = "h:mma"
            context += "Current time: \(nowFmt.string(from: Date()))\n"
        }
        context += "\n"

        if !allDayEvents.isEmpty {
            context += "All-day:\n"
            for e in allDayEvents {
                context += "- \(e.title) (\(e.calendarName))\n"
            }
            context += "\n"
        }

        if !timedEvents.isEmpty {
            context += "Schedule:\n"
            for e in timedEvents {
                var line = "- \(timeFmt.string(from: e.startDate))–\(timeFmt.string(from: e.endDate)): \(e.title)"
                if !e.attendees.isEmpty {
                    let names = e.attendees
                        .filter { !ContactService.isCurrentUser($0) }
                        .prefix(3)
                        .map { ContactService.resolvedName(for: $0) }
                    if !names.isEmpty { line += " (with \(names.joined(separator: ", ")))" }
                }
                if let loc = e.location, !loc.isEmpty,
                   !loc.contains("zoom.us"), !loc.contains("meet.google") {
                    line += " @ \(String(loc.prefix(40)))"
                } else if e.zoomLink != nil {
                    line += " [Zoom]"
                }
                context += line + "\n"
            }
        } else {
            context += "No meetings scheduled.\n"
        }

        // Add todos grouped by source
        if !todos.isEmpty {
            context += "\nOpen to-dos:\n"
            var grouped: [(key: String, items: [String])] = []
            var seen: Set<String> = []
            for todo in todos {
                let key = todo.projectName ?? todo.sourceBadge
                if seen.contains(key) {
                    if let idx = grouped.firstIndex(where: { $0.key == key }) {
                        grouped[idx].items.append(todo.title)
                    }
                } else {
                    seen.insert(key)
                    grouped.append((key, [todo.title]))
                }
            }
            for group in grouped {
                context += "[\(group.key)] \(group.items.prefix(4).joined(separator: "; "))"
                if group.items.count > 4 { context += " (+\(group.items.count - 4) more)" }
                context += "\n"
            }
        }

        let tense = isToday ? "today" : isTomorrow ? "tomorrow" : "that day"
        let prompt = """
        You're a sharp, warm executive assistant writing a day-at-a-glance briefing. \
        Based on the schedule and open to-dos below, write 2-4 short sentences covering:
        1. The shape and feel of \(tense) — is it packed, light, meeting-free, has open time?
        2. What to be aware of — meetings, all-day events, or open to-dos that could use attention
        3. A practical tip or encouraging note — what to tackle in free time, or just a good vibe

        Be specific. Reference actual event names and to-do projects where relevant. \
        Keep it natural and conversational — like a friend who knows your calendar. \
        No headers, no bullet points, no markdown. Just flowing sentences. \
        \(isToday ? "Use present/future tense relative to the current time." : "")

        \(context)
        """

        return await runClaude(prompt: prompt)
    }

    /// Shared Claude runner
    nonisolated private static func runClaude(prompt: String) async -> String? {
        await withCheckedContinuation { continuation in
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
                let data = pipe.fileHandleForReading.readDataToEndOfFile()
                process.waitUntilExit()
                let output = String(data: data, encoding: .utf8)?
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                continuation.resume(returning: output?.isEmpty == false ? output : nil)
            } catch {
                continuation.resume(returning: nil)
            }
        }
    }

    private static func dateCacheKey(_ date: Date) -> String {
        let fmt = DateFormatter()
        fmt.dateFormat = "yyyy-MM-dd"
        return fmt.string(from: date)
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
            let others = event.attendees.filter { !ContactService.isCurrentUser($0) }
            let people = ContactService.resolveNames(others)

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
                let data = pipe.fileHandleForReading.readDataToEndOfFile()
                process.waitUntilExit()
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
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
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
