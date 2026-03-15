import Foundation
import os

private let logger = Logger(subsystem: "com.claudehud", category: "SparkService")

// MARK: - Shared Email Result

struct SparkEmailResult {
    let pk: String
    let from: String
    let subject: String
    let body: String
    let date: String
    let epoch: Double
}

// MARK: - Spark Database Service

enum SparkService {
    static let ftsPath: String? = {
        let appSupport = NSHomeDirectory() + "/Library/Application Support"
        let paths = [
            "\(appSupport)/Spark Desktop/core-data/search_fts5.sqlite",
            "\(appSupport)/com.readdle.SparkDesktop/core-data/search_fts5.sqlite",
            "\(appSupport)/com.readdle.SparkDesktop-setapp/db/SearchIndex.sqlite",
            "\(appSupport)/com.readdle.SparkDesktop/db/SearchIndex.sqlite",
            "\(appSupport)/Spark/db/SearchIndex.sqlite",
        ]
        return paths.first { FileManager.default.fileExists(atPath: $0) }
    }()

    static let msgPath: String? = {
        let appSupport = NSHomeDirectory() + "/Library/Application Support"
        let paths = [
            "\(appSupport)/Spark Desktop/core-data/messages.sqlite",
            "\(appSupport)/com.readdle.SparkDesktop/core-data/messages.sqlite",
            "\(appSupport)/com.readdle.SparkDesktop-setapp/db/messages.sqlite",
            "\(appSupport)/com.readdle.SparkDesktop/db/messages.sqlite",
            "\(appSupport)/Spark/db/messages.sqlite",
        ]
        return paths.first { FileManager.default.fileExists(atPath: $0) }
    }()

    // MARK: - Email Search

    /// Search Spark emails by terms. Each term is OR'd. Returns deduplicated results sorted newest-first.
    /// Uses a single sqlite3 process per DB (FTS + messages) regardless of term count.
    static func searchEmails(terms: [String], limit: Int, includeBody: Bool = false) -> [SparkEmailResult] {
        guard let ftsPath = ftsPath, !terms.isEmpty else { return [] }

        // Build a single FTS query: "term1" OR "term2" OR "term3"
        let matchClauses = terms.map { term -> String in
            let escaped = term.replacingOccurrences(of: "'", with: "''")
                .replacingOccurrences(of: "\"", with: "")
            return "\"\(escaped)\""
        }
        let matchExpr = matchClauses.joined(separator: " OR ")

        let bodyCol = includeBody ? ", searchBody" : ""
        let sql = """
        SELECT messagePk, messageFrom, subject\(bodyCol)
        FROM messagesfts
        WHERE messagesfts MATCH '\(matchExpr)'
        ORDER BY rowid DESC
        LIMIT \(limit * 3)
        """

        guard let ftsResults = runSQLite(dbPath: ftsPath, sql: sql) else { return [] }

        let maxSplits = includeBody ? 3 : 2
        var pks: [String] = []
        var ftsData: [(pk: String, from: String, subject: String, body: String)] = []
        var seenPks: Set<String> = []

        for line in ftsResults {
            let cols = line.split(separator: "|", maxSplits: maxSplits, omittingEmptySubsequences: false).map(String.init)
            guard cols.count >= 3, !seenPks.contains(cols[0]) else { continue }
            seenPks.insert(cols[0])
            pks.append(cols[0])
            ftsData.append((
                pk: cols[0],
                from: cols[1],
                subject: cols[2],
                body: includeBody && cols.count > 3 ? cols[3] : ""
            ))
        }

        guard !ftsData.isEmpty else { return [] }

        // Single query for all dates + shortBody
        var msgInfo: [String: (date: String, body: String, epoch: Double)] = [:]
        if let msgPath = msgPath {
            let fmt = DateFormatter()
            fmt.dateFormat = "MMM d"
            let idList = pks.joined(separator: ",")
            let dateSql = "SELECT pk, receivedDate, shortBody FROM messages WHERE pk IN (\(idList)) ORDER BY receivedDate DESC"
            if let dateResults = runSQLite(dbPath: msgPath, sql: dateSql) {
                for line in dateResults {
                    let parts = line.split(separator: "|", maxSplits: 2, omittingEmptySubsequences: false)
                    guard parts.count >= 2, let epoch = Double(parts[1]) else { continue }
                    let dateStr = fmt.string(from: Date(timeIntervalSince1970: epoch))
                    let body = parts.count > 2 ? String(parts[2]) : ""
                    msgInfo[String(parts[0])] = (date: dateStr, body: body, epoch: epoch)
                }
            }
        }

        // Deduplicate by subject, sort newest first
        var seen: Set<String> = []
        var results: [(result: SparkEmailResult, epoch: Double)] = []

        for item in ftsData {
            let subjectKey = item.subject.lowercased()
                .replacingOccurrences(of: "re: ", with: "")
                .replacingOccurrences(of: "fwd: ", with: "")
            if seen.contains(subjectKey) { continue }
            seen.insert(subjectKey)

            let name = extractDisplayName(from: item.from)
            let info = msgInfo[item.pk]
            // Prefer FTS searchBody if available, fall back to messages shortBody
            let body = !item.body.isEmpty ? item.body : (info?.body ?? "")

            results.append((
                result: SparkEmailResult(
                    pk: item.pk,
                    from: name,
                    subject: item.subject,
                    body: body,
                    date: info?.date ?? "",
                    epoch: info?.epoch ?? 0
                ),
                epoch: info?.epoch ?? 0
            ))
        }

        return results
            .sorted { $0.epoch > $1.epoch }
            .prefix(limit)
            .map(\.result)
    }

    // MARK: - Inbox Emails

    /// Fetch recent inbox emails (not sent by user), newest first
    static func fetchInboxEmails(limit: Int = 15) -> [SparkEmailResult] {
        guard let msgPath = msgPath else { return [] }

        let fmt = DateFormatter()
        fmt.dateFormat = "MMM d"

        let sql = """
        SELECT pk, subject, messageFrom, shortBody, receivedDate
        FROM messages
        WHERE inInbox=1 AND inSent=0 AND inDrafts=0 AND category IN (1, 4)
        ORDER BY receivedDate DESC
        LIMIT \(limit)
        """

        guard let rows = runSQLite(dbPath: msgPath, sql: sql) else { return [] }

        var seen: Set<String> = []
        var results: [SparkEmailResult] = []

        for row in rows {
            let cols = row.split(separator: "|", maxSplits: 4, omittingEmptySubsequences: false).map(String.init)
            guard cols.count >= 5, let epoch = Double(cols[4]) else { continue }

            let subjectKey = cols[1].lowercased()
                .replacingOccurrences(of: "re: ", with: "")
                .replacingOccurrences(of: "fwd: ", with: "")
            guard !seen.contains(subjectKey) else { continue }
            seen.insert(subjectKey)

            results.append(SparkEmailResult(
                pk: cols[0],
                from: extractDisplayName(from: cols[2]),
                subject: cols[1],
                body: cols[3],
                date: fmt.string(from: Date(timeIntervalSince1970: epoch)),
                epoch: epoch
            ))
        }

        return results
    }

    // MARK: - Helpers

    static func runSQLite(dbPath: String, sql: String) -> [String]? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/sqlite3")
        process.arguments = ["-separator", "|", "-readonly", dbPath, sql]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = Pipe()

        do {
            try process.run()
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            guard let output = String(data: data, encoding: .utf8), !output.isEmpty else { return nil }
            return output.components(separatedBy: "\n").filter { !$0.isEmpty }
        } catch {
            return nil
        }
    }

    static func extractDisplayName(from field: String) -> String {
        let s = field.trimmingCharacters(in: .whitespaces)
        if let quoteStart = s.firstIndex(of: "\""),
           let quoteEnd = s[s.index(after: quoteStart)...].firstIndex(of: "\"") {
            return String(s[s.index(after: quoteStart)..<quoteEnd])
        }
        if let angleStart = s.firstIndex(of: "<") {
            let name = s[s.startIndex..<angleStart].trimmingCharacters(in: .whitespaces)
            if !name.isEmpty { return name }
        }
        return s
    }
}
