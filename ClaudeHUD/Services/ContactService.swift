import Contacts
import Foundation
import os

private let logger = Logger(subsystem: "com.claudehud", category: "ContactService")

// MARK: - Contact Model

enum ContactSource: String, Codable, Hashable {
    case calendar
    case email
    case macContacts
}

struct Contact: Identifiable, Codable, Hashable {
    var id: String              // lowercased email (dedup key)
    var name: String            // best-known display name
    var email: String           // canonical email
    var org: String             // organization
    var lastSeen: Date          // most recent appearance
    var sources: Set<ContactSource>
    var manualOverride: Bool    // user-edited, skip auto-resolution
}

// MARK: - Contact Service

@MainActor
class ContactService: ObservableObject {
    @Published private(set) var allContacts: [Contact] = []

    /// Fast lookup cache — nonisolated for cross-thread access (same pattern as old nameCache)
    nonisolated(unsafe) static var cache: [String: Contact] = [:]

    private static let filePath: String = {
        let dir = "\(NSHomeDirectory())/.claude/hud"
        try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        return "\(dir)/contacts.json"
    }()

    init() {
        Self.loadFromDisk()
        refreshPublished()
    }

    // MARK: - Identity Check

    nonisolated static func isCurrentUser(_ person: PersonInfo) -> Bool {
        let e = person.email.lowercased()
        return e.contains("bbdaniels") || e.contains("bdaniels") || e.contains("bd581")
    }

    nonisolated static func isCurrentUserEmail(_ email: String) -> Bool {
        let e = email.lowercased()
        return e.contains("bbdaniels") || e.contains("bdaniels") || e.contains("bd581")
    }

    // MARK: - Name Resolution (reads from cache)

    nonisolated static func resolvedName(for person: PersonInfo) -> String {
        if isCurrentUser(person) { return NSFullUserName() }
        let key = person.email.lowercased()
        if let contact = cache[key], !contact.name.isEmpty {
            return contact.name
        }
        let name = person.name
        if name.contains("@") || name == "Unknown" { return person.email }
        return cleanName(name)
    }

    nonisolated static func resolvedOrg(for person: PersonInfo) -> String? {
        if isCurrentUser(person) { return nil }
        if let contact = cache[person.email.lowercased()], !contact.org.isEmpty {
            return contact.org
        }
        let domain = person.email.split(separator: "@").last.map(String.init) ?? ""
        let org = orgFromDomain(domain)
        return org.isEmpty ? nil : org
    }

    // MARK: - Contact Access

    func contact(for email: String) -> Contact? {
        Self.cache[email.lowercased()]
    }

    func search(query: String) -> [Contact] {
        let q = query.lowercased()
        return allContacts.filter {
            $0.name.lowercased().contains(q) ||
            $0.email.lowercased().contains(q) ||
            $0.org.lowercased().contains(q)
        }
    }

    // MARK: - Ingestion

    /// Resolve names for a group of people and return display name list (for Claude prompts)
    nonisolated static func resolveNames(_ people: [PersonInfo]) -> [String] {
        ingest(people: people, source: .calendar)

        return people.compactMap { person -> String? in
            let key = person.email.lowercased()
            if let contact = cache[key], !contact.name.isEmpty {
                return contact.name
            }
            let name = person.name
            if name.contains("@") || name == "Unknown" { return nil }
            return cleanName(name)
        }
    }

    /// Ingest people from calendar/email, resolve unknown names, persist
    nonisolated static func ingest(people: [PersonInfo], source: ContactSource) {
        let now = Date()
        var changed = false

        // Update existing cached contacts with new lastSeen
        for person in people {
            let key = person.email.lowercased()
            guard !key.isEmpty, key.contains("@") else { continue }
            if var existing = cache[key] {
                existing.lastSeen = now
                existing.sources.insert(source)
                cache[key] = existing
                changed = true
            }
        }

        // Resolve uncached emails
        let uncached = people.filter {
            let key = $0.email.lowercased()
            return !key.isEmpty && key.contains("@") && cache[key] == nil
        }
        if !uncached.isEmpty {
            let resolved = lookupNames(emails: uncached.map(\.email))
            for person in uncached {
                let key = person.email.lowercased()
                let domain = person.email.split(separator: "@").last.map(String.init) ?? ""

                if let info = resolved[key] {
                    let name = cleanName(info.name)
                    let org = info.org.isEmpty ? orgFromDomain(domain) : info.org
                    cache[key] = Contact(
                        id: key, name: name, email: person.email,
                        org: org, lastSeen: now,
                        sources: [source], manualOverride: false
                    )
                } else if !person.name.contains("@") && person.name != "Unknown" {
                    cache[key] = Contact(
                        id: key, name: cleanName(person.name), email: person.email,
                        org: orgFromDomain(domain), lastSeen: now,
                        sources: [source], manualOverride: false
                    )
                }
                changed = true
            }
        }

        if changed { saveToDisk() }
    }

    /// Bulk-merge contacts from external sources (e.g., project aggregation)
    nonisolated static func mergeContacts(_ newContacts: [Contact]) {
        var changed = false
        for contact in newContacts {
            if var existing = cache[contact.id] {
                existing.lastSeen = max(existing.lastSeen, contact.lastSeen)
                existing.sources.formUnion(contact.sources)
                if !existing.manualOverride {
                    if existing.name.isEmpty && !contact.name.isEmpty {
                        existing.name = contact.name
                    }
                    if existing.org.isEmpty && !contact.org.isEmpty {
                        existing.org = contact.org
                    }
                }
                cache[contact.id] = existing
            } else {
                cache[contact.id] = contact
            }
            changed = true
        }
        if changed { saveToDisk() }
    }

    // MARK: - Mutation

    func update(_ contact: Contact) {
        Self.cache[contact.id] = contact
        Self.saveToDisk()
        refreshPublished()
    }

    func delete(id: String) {
        Self.cache.removeValue(forKey: id)
        Self.saveToDisk()
        refreshPublished()
    }

    func refreshPublished() {
        allContacts = Array(Self.cache.values).sorted { $0.lastSeen > $1.lastSeen }
    }

    // MARK: - Name Cleaning

    nonisolated static func cleanName(_ name: String) -> String {
        var n = name.replacingOccurrences(of: "\"", with: "").trimmingCharacters(in: .whitespaces)

        // "Last, First Middle" → "First Middle Last"
        // But preserve suffixes: "Last, First, MD" → "First Last, MD"
        if n.contains(", ") {
            let parts = n.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }
            if parts.count >= 2 {
                let last = parts[0]
                let first = parts[1]
                let suffixes = parts.dropFirst(2).joined(separator: ", ")
                n = suffixes.isEmpty ? "\(first) \(last)" : "\(first) \(last), \(suffixes)"
            }
        }

        // Title-case each word (handles all-lowercase names from headers)
        n = n.split(separator: " ").map { word in
            let w = String(word)
            // Don't capitalize suffixes/abbreviations that are already uppercase-ish
            if w.count <= 3 && w == w.uppercased() { return w }
            return w.prefix(1).uppercased() + w.dropFirst()
        }.joined(separator: " ")

        return n
    }

    // MARK: - Name Lookup (Spark + macOS Contacts)

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
        let entries = header.components(separatedBy: ",")
        for entry in entries {
            let trimmed = entry.trimmingCharacters(in: .whitespaces)
            guard trimmed.lowercased().contains(emailLower) else { continue }
            let name = SparkService.extractDisplayName(from: trimmed)
            if !name.isEmpty && !name.contains("@") {
                return name
            }
        }
        return nil
    }

    /// Guess organization from email domain
    nonisolated static func orgFromDomain(_ domain: String) -> String {
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

    // MARK: - Persistence

    nonisolated private static func loadFromDisk() {
        guard let data = try? Data(contentsOf: URL(fileURLWithPath: filePath)) else { return }
        if let contacts = try? JSONDecoder().decode([Contact].self, from: data) {
            for contact in contacts {
                cache[contact.id] = contact
            }
            logger.info("Loaded \(contacts.count) contacts from disk")
        }
    }

    nonisolated static func saveToDisk() {
        let contacts = Array(cache.values)
        do {
            let data = try JSONEncoder().encode(contacts)
            try data.write(to: URL(fileURLWithPath: filePath))
        } catch {
            logger.error("Failed to save contacts: \(error)")
        }
    }
}
