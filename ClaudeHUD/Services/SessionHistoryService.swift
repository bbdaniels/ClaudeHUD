import AppKit
import Foundation
import os
import SQLite3

private let logger = Logger(subsystem: "com.claudehud", category: "SessionHistory")

// MARK: - Search Result

struct SessionSearchResult: Identifiable {
    let id: String           // session ID
    let snippet: String      // ~80 chars around the match
}

// MARK: - Session History Service

/// The History list: the Mac's sessions and the iMac's, from one scan
/// (`SessionScan`) over `~/.claude/projects` and the iMac's mirror, which
/// each refresh brings up to date in the background (`IMacMirror`). The
/// titles, the full-text index and the filing tallies cover both hosts.
@MainActor
class SessionHistoryService: ObservableObject {
    @Published var sessions: [SessionInfo] = []
    @Published var isLoading = false
    @Published var searchResults: [String: SessionSearchResult] = [:]  // sessionId -> result
    @Published var isSearching = false
    /// Session id → working directory → how many of its records ran there,
    /// from the transcript index. Published after each index pass; the
    /// filing rule (`VaultProjectService.primeFiling`) reads it.
    @Published private(set) var transcriptCwdCounts: [String: [String: Int]] = [:]
    /// Bumped whenever `transcriptCwdCounts` changes, so a view can key a
    /// re-prime on it without hashing the whole table.
    @Published private(set) var transcriptCwdGeneration = 0

    private var searchTask: Task<Void, Never>?

    /// Persistent full-text index over listed transcripts (user + assistant
    /// text only). Updated incrementally after every scan; the ONLY search path.
    private let transcriptIndex = TranscriptIndex()
    private var indexTask: Task<Void, Never>?
    private var currentQuery = ""

    /// Coalesces overlapping refreshes (launch, History appear, Projects
    /// appear) into one scan.
    private var refreshTask: Task<Void, Never>?
    /// The iMac mirror's rsync run, if one is in progress. Never two at once.
    private var mirrorTask: Task<Void, Never>?

    /// Scan both hosts now, from the iMac's mirror as it stands, then bring
    /// the mirror up to date in the background and scan again if it changed.
    /// The listing never waits for the iMac.
    func refresh() async {
        await rescan()
        startMirror()
    }

    private var periodic: DispatchSourceTimer?

    /// Rescan, and so retitle, every `SessionTitleSchedule.refreshEvery`
    /// while the app runs, not only when the panel opens (Ben, 2026-11-03:
    /// "do it every minute"). A GCD timer fires whatever the panel's run-loop
    /// mode (AgentsService.start). Idempotent.
    func startPeriodicRefresh() {
        guard periodic == nil else { return }
        let t = DispatchSource.makeTimerSource(queue: .main)
        let every = SessionTitleSchedule.refreshEvery
        t.schedule(deadline: .now() + every, repeating: every, leeway: .seconds(5))
        t.setEventHandler { [weak self] in Task { @MainActor in await self?.refresh() } }
        t.resume()
        periodic = t
    }

    private func rescan() async {
        if let inFlight = refreshTask { return await inFlight.value }
        let task = Task { await performRefresh() }
        refreshTask = task
        await task.value
        refreshTask = nil
    }

    /// One rsync of the iMac's transcripts and claims into the mirror
    /// (`IMacMirror`), off the main actor. A failure (the iMac asleep or
    /// unreachable, or the time limit) is logged and the mirror keeps its
    /// last copy; a run that changed the mirror, even one stopped at the
    /// limit with some files done, is followed by a rescan.
    private func startMirror() {
        guard mirrorTask == nil else { return }
        mirrorTask = Task { [weak self] in
            let started = Date()
            let (outcome, changed): (IMacMirror.Outcome, Bool) = await Task.detached(priority: .utility) {
                let before = IMacMirror.signature()
                let outcome = IMacMirror.run()
                return (outcome, IMacMirror.signature() != before)
            }.value
            let ms = Int(Date().timeIntervalSince(started) * 1000)
            switch outcome {
            case .synced:
                logger.info("iMac mirror: synced in \(ms, privacy: .public) ms, changed: \(changed, privacy: .public)")
            case .busy:
                break
            case .failed(let reason):
                logger.error("iMac mirror: \(reason, privacy: .public) (after \(ms, privacy: .public) ms, changed: \(changed, privacy: .public))")
            }
            guard let self else { return }
            self.mirrorTask = nil
            if changed { await self.rescan() }
        }
    }

    private func performRefresh() async {
        isLoading = true
        defer { isLoading = false }

        let started = Date()
        let index = transcriptIndex
        let headCache = await index.loadHeads()
        let scan = await Task.detached(priority: .userInitiated) {
            SessionScan.scan(roots: SessionHost.allCases.map { (host: $0, dir: $0.projectsDir()) },
                             headCache: headCache, sidecarTitles: SessionScan.loadSidecarTitles())
        }.value
        let ms = Int(Date().timeIntervalSince(started) * 1000)
        let iMacCount = scan.sessions.filter { $0.host == .iMac }.count
        logger.info("session scan: \(scan.sessions.count, privacy: .public) sessions (\(iMacCount, privacy: .public) from the iMac), \(scan.changedHeads.count, privacy: .public) heads classified, in \(ms, privacy: .public) ms")

        sessions = scan.sessions
        await index.saveHeads(changed: scan.changedHeads, removed: scan.removedPaths)
        updateIndex()
        updateTitles()
    }

    // MARK: - Titles

    private let titler = SessionTitler()
    private var titleTask: Task<Void, Never>?

    /// Title sessions whose title is due (`SessionTitler`) in the background,
    /// one Haiku call at a time, and relabel each row as its title lands. One pass at a time; a
    /// refresh during a pass is picked up by the next refresh.
    /// The vault projects, set by `AppState`: each titling pass first files
    /// its sessions by the one rule (`VaultProjectService.primeFiling`), so a
    /// title names the session's own project whether or not any view is open.
    weak var vaultProjects: VaultProjectService?

    private func updateTitles() {
        guard titleTask == nil else { return }
        let sessions = sessions
        let cwdCounts = transcriptCwdCounts
        let titler = titler
        titleTask = Task { [weak self] in
            var filed: [String: String] = [:]
            if let projects = self?.vaultProjects {  // this task runs on the main actor
                await projects.primeFiling(sessions: sessions.map { ($0.id, $0.projectPath, $0.host) },
                                           cwdCounts: cwdCounts)
                for s in sessions {
                    if let f = projects.folder(forSession: s.id, cwd: s.projectPath) { filed[s.id] = f }
                }
            }
            let candidates = sessions.map { s in
                // The directory most of its records ran in (a phone session
                // starts in ~/Projects), else the one it started in.
                let folder = cwdCounts[s.id]?.max { $0.value < $1.value }?.key ?? s.projectPath
                return SessionTitler.Candidate(id: s.id, path: s.filePath, modified: s.timestamp,
                                               project: filed[s.id], folder: folder)
            }
            await titler.refreshTitles(candidates) { id, title in
                await MainActor.run { self?.relabel(id: id, title: title) }
            }
            await MainActor.run { self?.titleTask = nil }
        }
    }

    private func relabel(id: String, title: String) {
        guard let i = sessions.firstIndex(where: { $0.id == id }) else { return }
        sessions[i] = sessions[i].relabeled(title)
    }

    /// Bring the index up to date with the listed sessions, off the main
    /// actor. One pass at a time: a refresh during a pass is picked up by the
    /// next refresh (only changed/grown files are read, so passes are cheap
    /// once the first build is done). A live query re-runs when the pass ends
    /// so results filled in by a first build appear without retyping.
    private func updateIndex() {
        guard indexTask == nil else { return }
        let files = sessions.map { (id: $0.id, path: $0.filePath) }
        let index = transcriptIndex
        indexTask = Task { [weak self] in
            await index.update(files: files)
            let counts = await index.cwdCounts()
            guard let self else { return }
            if counts != self.transcriptCwdCounts {
                self.transcriptCwdCounts = counts
                self.transcriptCwdGeneration &+= 1
            }
            self.indexTask = nil
            if !self.currentQuery.isEmpty { self.search(query: self.currentQuery) }
        }
    }

    /// Full-text search: an FTS5 prefix query against the transcript index,
    /// published in ONE batch (a per-match @Published mutation re-rendered the
    /// non-lazy history list once per hit). The view orders hits by recency.
    func search(query: String) {
        searchTask?.cancel()
        currentQuery = query

        guard !query.isEmpty else {
            searchResults = [:]
            isSearching = false
            return
        }

        isSearching = true
        let index = transcriptIndex
        searchTask = Task { [weak self] in
            let collected = await index.search(query)
            guard let self, !Task.isCancelled else { return }
            self.searchResults = collected
            self.isSearching = false
        }
    }

    /// Delete a session's JSONL file and remove it from the list. The Mac's
    /// own sessions only: an iMac session's file is the mirror's copy, which
    /// the next mirror run would restore, and the iMac's transcript is never
    /// touched from here.
    func deleteSession(id: String) {
        guard let session = sessions.first(where: { $0.id == id }), session.host == .mac else { return }
        try? FileManager.default.removeItem(atPath: session.filePath)

        sessions.removeAll { $0.id == id }
        let index = transcriptIndex
        Task { await index.remove(sessionID: id) }
    }

}

// MARK: - Transcript Text

/// THE extraction of a transcript's conversation text: user and assistant
/// text only; tool_use / tool_result payloads, thinking, attachments, and
/// base64 blobs are skipped. Used in-process by the search index.
enum TranscriptText {
    private static let textBlockMarker = Data("\"type\":\"text\"".utf8)
    private static let stringContentMarker = Data("\"content\":\"".utf8)

    /// Visit each user/assistant text message in complete JSONL lines.
    static func forEachMessage<D: DataProtocol>(in data: D, _ body: (_ role: String, _ text: String) -> Void)
        where D.SubSequence == D {
        for line in data.split(separator: 0x0A, omittingEmptySubsequences: true) {
            let bytes = Data(line)
            // Cheap byte pre-filter: skip records with no text content
            // (tool results, progress, snapshots) before JSON parsing.
            guard bytes.range(of: textBlockMarker) != nil || bytes.range(of: stringContentMarker) != nil,
                  let json = try? JSONSerialization.jsonObject(with: bytes) as? [String: Any],
                  let role = TranscriptRecord.role(from: json),
                  role == "user" || role == "assistant",
                  let text = TranscriptRecord.messageContent(from: json)?
                    .trimmingCharacters(in: .whitespacesAndNewlines),
                  !text.isEmpty
            else { continue }
            body(role, text)
        }
    }
}

// MARK: - Session Titler

/// The one session-title generator. A title says what the session is doing
/// now (Ben, 2026-11-03): it is generated by a cheap, isolated Haiku call
/// (`SessionTitlePrompt`) from the session's project and folder and the whole
/// conversation, sampled (`SessionScan.titleContext`), and written to
/// ~/.claude/hud/session-titles/<id>.txt, the label source the scan and the
/// Projects lines read. Transcripts are only read, never modified.
///
/// When: an untitled session once it has three real prompts or has been idle
/// for 30 minutes (a one-word opener like "yes" alone makes a poor title); a
/// titled one again whenever its transcript has grown since its title was
/// written, background work included, at most once a minute (the sidecar's modification time is when
/// it was titled). Cost control: the newest sessions first, calls one at a
/// time with a pause between them and a cap per pass. A failed call is logged
/// with what it said (`SessionTitleFailure`), ends the pass, since the cause
/// (a usage limit, a login) is usually shared by every call, and its session
/// is tried again after `SessionTitleSchedule.retryAfter`.
actor SessionTitler {
    private static let titlesDir = "\(NSHomeDirectory())/.claude/hud/session-titles"
    private static let claudePath = "\(NSHomeDirectory())/.local/bin/claude"
    private static let perPass = 25
    private var failedAt: [String: Date] = [:]

    struct Candidate {
        let id: String
        let path: String
        let modified: Date
        let project: String?
        let folder: String
    }

    func refreshTitles(_ candidates: [Candidate],
                       onTitle: (String, String) async -> Void) async {
        guard FileManager.default.isExecutableFile(atPath: Self.claudePath) else { return }
        let now = Date()
        var calls = 0
        for c in candidates.sorted(by: { $0.modified > $1.modified })
        where SessionTitleSchedule.retryDue(failedAt: failedAt[c.id], now: now) {
            if calls >= Self.perPass || Task.isCancelled { break }
            let sidecar = "\(Self.titlesDir)/\(c.id).txt"
            let titledAt = (try? FileManager.default.attributesOfItem(atPath: sidecar))?[.modificationDate] as? Date
            // Cheap first: a transcript untouched since its title has no new prompt.
            if let titledAt, c.modified <= titledAt || now.timeIntervalSince(titledAt) < SessionTitleSchedule.refreshEvery { continue }

            var context = SessionScan.titleContext(in: c.path)
            guard SessionTitleSchedule.due(titledAt: titledAt, promptCount: context.prompts.count,
                           transcriptModified: c.modified, now: now) else { continue }
            context.project = c.project
            context.folder = c.folder

            calls += 1
            let outcome = await Self.generate(context)
            guard case .success(let title) = outcome else {
                if case .failure(let why) = outcome {
                    logger.error("session title: generation failed for \(c.id, privacy: .public): \(why.text, privacy: .public)")
                }
                failedAt[c.id] = Date()
                break   // the cause is usually shared: the next pass tries again
            }
            failedAt[c.id] = nil
            Self.writeSidecar(id: c.id, title: title)
            await onTitle(c.id, title)
            try? await Task.sleep(nanoseconds: 1_000_000_000)
        }
        if calls > 0 { logger.info("session titles: \(calls, privacy: .public) generated") }
    }

    struct Failure: Error { let text: String }

    private static func generate(_ context: SessionTitleContext) async -> Result<String, Failure> {
        let arguments = SessionTitlePrompt.arguments(for: context)
        return await withCheckedContinuation { cont in
            DispatchQueue.global(qos: .utility).async {
                let process = Process()
                process.executableURL = URL(fileURLWithPath: claudePath)
                process.arguments = arguments
                process.currentDirectoryURL = URL(fileURLWithPath: NSTemporaryDirectory())
                var env = ProcessInfo.processInfo.environment
                env.removeValue(forKey: "CLAUDECODE")
                process.environment = env
                let out = Pipe(), err = Pipe()
                process.standardOutput = out
                process.standardError = err
                do { try process.run() } catch {
                    let why = SessionTitleFailure.describe(status: nil, stdout: "", stderr: "",
                                                           launchError: error.localizedDescription)
                    cont.resume(returning: .failure(Failure(text: why))); return
                }
                let timer = DispatchWorkItem { if process.isRunning { process.terminate() } }
                DispatchQueue.global().asyncAfter(deadline: .now() + 90, execute: timer)
                // stderr is read beside stdout, so a full stderr pipe cannot stall the call.
                var errData = Data()
                let errRead = DispatchGroup()
                errRead.enter()
                DispatchQueue.global(qos: .utility).async {
                    errData = err.fileHandleForReading.readDataToEndOfFile()
                    errRead.leave()
                }
                let data = out.fileHandleForReading.readDataToEndOfFile()
                errRead.wait()
                process.waitUntilExit()
                timer.cancel()
                let text = String(decoding: data, as: UTF8.self)
                if process.terminationStatus == 0, let title = sanitize(text) {
                    cont.resume(returning: .success(title)); return
                }
                let why = SessionTitleFailure.describe(status: process.terminationStatus, stdout: text,
                                                       stderr: String(decoding: errData, as: UTF8.self))
                cont.resume(returning: .failure(Failure(text: why)))
            }
        }
    }

    private static func sanitize(_ raw: String) -> String? {
        guard let line = raw.split(whereSeparator: \.isNewline)
            .map({ $0.trimmingCharacters(in: .whitespaces) })
            .first(where: { !$0.isEmpty }) else { return nil }
        let t = line.trimmingCharacters(in: CharacterSet(charactersIn: "\"'`*#_ ."))
        guard !t.isEmpty, t.count <= 120 else { return nil }
        return String(t.prefix(90))
    }

    private static func writeSidecar(id: String, title: String) {
        let fm = FileManager.default
        try? fm.createDirectory(atPath: titlesDir, withIntermediateDirectories: true)
        let tmp = "\(titlesDir)/.tmp.\(id)"
        guard (try? (title + "\n").write(toFile: tmp, atomically: false, encoding: .utf8)) != nil else { return }
        _ = try? fm.replaceItemAt(URL(fileURLWithPath: "\(titlesDir)/\(id).txt"), withItemAt: URL(fileURLWithPath: tmp))
        if fm.fileExists(atPath: tmp) { try? fm.moveItem(atPath: tmp, toPath: "\(titlesDir)/\(id).txt") }
    }
}


/// Persistent session store in Application Support: the cached head verdicts
/// that make the session scan cheap, and an incremental full-text index of
/// listed session transcripts:
/// SQLite FTS5 in Application Support. Only user and assistant TEXT is
/// indexed (tool payloads, tool results, and thinking blocks are skipped), so
/// base64 blobs and file dumps cannot produce false hits. Transcripts are
/// append-only JSONL, so a grown file is read from the last indexed line
/// boundary; a shrunk or rewritten file is reindexed from zero.
///
/// All SQLite access runs on one private serial queue, never on the Swift
/// concurrency pool or the main actor: callers await a continuation. `update`
/// takes the queue once per file, so a search issued mid-build waits at most
/// one file.
final class TranscriptIndex: @unchecked Sendable {
    private let queue = DispatchQueue(label: "com.claudehud.transcript-index", qos: .utility)
    private var db: OpaquePointer?
    /// Bump when the schema or the extraction rule changes: a mismatch drops
    /// and rebuilds the index. 4 (2026-11-03): the per-session working
    /// directory tally, and head verdicts re-evaluated so sessions started
    /// from the phone, which version 3 cached as machine runs, are listed.
    private static let schemaVersion: Int32 = 4
    private static let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

    init() {
        queue.sync { openDatabase() }
    }

    deinit {
        if let db { sqlite3_close(db) }
    }

    // MARK: Public API

    /// Index every listed session's new bytes and drop sessions no longer
    /// listed (deleted, or reclassified as machine one-shots).
    func update(files: [(id: String, path: String)]) async {
        guard !files.isEmpty else { return }  // a failed scan must not wipe the index
        let started = Date()
        let listed = Set(files.map(\.id))
        await onQueue { self.pruneUnlisted(listed) }
        var changed = 0
        for f in files {
            if await onQueue({ self.indexFile(id: f.id, path: f.path) }) { changed += 1 }
        }
        let ms = Int(Date().timeIntervalSince(started) * 1000)
        logger.info("transcript index: \(changed, privacy: .public)/\(files.count, privacy: .public) files updated in \(ms, privacy: .public) ms")
    }

    /// Sessions whose text matches every query token (prefix match), each
    /// with a snippet around its best-ranked matching message.
    func search(_ query: String) async -> [String: SessionSearchResult] {
        let tokens = query.lowercased()
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { !$0.isEmpty }
        guard !tokens.isEmpty else { return [:] }
        let match = tokens.map { "\"\($0)\"*" }.joined(separator: " ")

        return await onQueue(qos: .userInitiated) { self.runSearch(match) }
    }

    func remove(sessionID: String) async {
        await onQueue { self.deleteSession(sessionID) }
    }

    /// Session id → how many of its transcript's records ran in each working
    /// directory, for every indexed session. The input to the filing rule's
    /// second step (`SessionFiling.resolveFolder`): a session started from the
    /// phone runs in ~/Projects, and only the directories its records name
    /// say which project it worked in. Tallied incrementally with the text.
    func cwdCounts() async -> [String: [String: Int]] {
        await onQueue(qos: .userInitiated) {
            var out: [String: [String: Int]] = [:]
            guard let stmt = self.prepare("SELECT session_id, cwds FROM files WHERE cwds IS NOT NULL") else { return out }
            defer { sqlite3_finalize(stmt) }
            while sqlite3_step(stmt) == SQLITE_ROW {
                guard let id = sqlite3_column_text(stmt, 0), let c = sqlite3_column_text(stmt, 1) else { continue }
                out[String(cString: id)] = Self.decodeCounts(String(cString: c))
            }
            return out
        }
    }

    private static func decodeCounts(_ json: String) -> [String: Int] {
        (try? JSONSerialization.jsonObject(with: Data(json.utf8))) as? [String: Int] ?? [:]
    }

    private static func encodeCounts(_ counts: [String: Int]) -> String {
        (try? JSONSerialization.data(withJSONObject: counts, options: [.sortedKeys]))
            .flatMap { String(data: $0, encoding: .utf8) } ?? "{}"
    }

    /// Every cached head verdict, keyed by transcript path.
    func loadHeads() async -> [String: CachedHead] {
        await onQueue(qos: .userInitiated) {
            var out: [String: CachedHead] = [:]
            guard let stmt = self.prepare("SELECT path, mtime, size, kind, label FROM heads") else { return out }
            defer { sqlite3_finalize(stmt) }
            while sqlite3_step(stmt) == SQLITE_ROW {
                guard let p = sqlite3_column_text(stmt, 0), let k = sqlite3_column_text(stmt, 3),
                      let kind = CachedHead.Kind(rawValue: String(cString: k)) else { continue }
                out[String(cString: p)] = CachedHead(
                    mtime: sqlite3_column_double(stmt, 1),
                    size: sqlite3_column_int64(stmt, 2),
                    kind: kind,
                    label: sqlite3_column_text(stmt, 4).map { String(cString: $0) })
            }
            return out
        }
    }

    func saveHeads(changed: [String: CachedHead], removed: [String]) async {
        guard !changed.isEmpty || !removed.isEmpty else { return }
        await onQueue {
            self.exec("BEGIN")
            if let upsert = self.prepare("INSERT OR REPLACE INTO heads(path, mtime, size, kind, label) VALUES(?, ?, ?, ?, ?)") {
                for (path, h) in changed {
                    sqlite3_reset(upsert)
                    self.bind(upsert, 1, path)
                    sqlite3_bind_double(upsert, 2, h.mtime)
                    sqlite3_bind_int64(upsert, 3, h.size)
                    self.bind(upsert, 4, h.kind.rawValue)
                    if let t = h.label { self.bind(upsert, 5, t) } else { sqlite3_bind_null(upsert, 5) }
                    sqlite3_step(upsert)
                }
                sqlite3_finalize(upsert)
            }
            if let delete = self.prepare("DELETE FROM heads WHERE path = ?") {
                for path in removed {
                    sqlite3_reset(delete)
                    self.bind(delete, 1, path)
                    sqlite3_step(delete)
                }
                sqlite3_finalize(delete)
            }
            self.exec("COMMIT")
        }
    }

    /// Run `work` on the index queue and await its result without holding a
    /// concurrency-pool thread.
    private func onQueue<T>(qos: DispatchQoS = .utility, _ work: @escaping () -> T) async -> T {
        await withCheckedContinuation { cont in
            queue.async(qos: qos) { cont.resume(returning: work()) }
        }
    }

    // MARK: Search (queue-confined)

    private func runSearch(_ match: String) -> [String: SessionSearchResult] {
        guard db != nil else { return [:] }
        var ids: [String] = []
        if let stmt = prepare("SELECT DISTINCT session_id FROM messages WHERE messages MATCH ?") {
            bind(stmt, 1, match)
            while sqlite3_step(stmt) == SQLITE_ROW {
                if let c = sqlite3_column_text(stmt, 0) { ids.append(String(cString: c)) }
            }
            sqlite3_finalize(stmt)
        }
        var out: [String: SessionSearchResult] = [:]
        guard let stmt = prepare("""
            SELECT snippet(messages, 1, '', '', '…', 14) FROM messages
            WHERE messages MATCH ? AND session_id = ? ORDER BY rank LIMIT 1
            """) else { return out }
        defer { sqlite3_finalize(stmt) }
        for id in ids {
            sqlite3_reset(stmt)
            bind(stmt, 1, match)
            bind(stmt, 2, id)
            var snippet = ""
            if sqlite3_step(stmt) == SQLITE_ROW, let c = sqlite3_column_text(stmt, 0) {
                snippet = String(cString: c)
                    .replacingOccurrences(of: "\n", with: " ")
                    .trimmingCharacters(in: .whitespaces)
            }
            out[id] = SessionSearchResult(id: id, snippet: snippet)
        }
        return out
    }

    // MARK: Schema

    private func openDatabase() {
        let fm = FileManager.default
        guard let support = fm.urls(for: .applicationSupportDirectory, in: .userDomainMask).first else { return }
        let dir = support.appendingPathComponent("ClaudeHUD", isDirectory: true)
        try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
        let path = dir.appendingPathComponent("transcript-index.sqlite").path
        guard sqlite3_open(path, &db) == SQLITE_OK else {
            logger.error("transcript index: cannot open \(path, privacy: .public)")
            if let db { sqlite3_close(db) }
            db = nil
            return
        }
        exec("PRAGMA journal_mode=WAL")
        exec("PRAGMA synchronous=NORMAL")

        var version: Int32 = 0
        if let stmt = prepare("PRAGMA user_version") {
            if sqlite3_step(stmt) == SQLITE_ROW { version = sqlite3_column_int(stmt, 0) }
            sqlite3_finalize(stmt)
        }
        guard version != Self.schemaVersion else { return }
        exec("DROP TABLE IF EXISTS heads")
        exec("DROP TABLE IF EXISTS files")
        exec("DROP TABLE IF EXISTS messages")
        exec("""
            CREATE TABLE heads(
                path TEXT PRIMARY KEY,
                mtime REAL NOT NULL,
                size INTEGER NOT NULL,
                kind TEXT NOT NULL,
                label TEXT)
            """)
        exec("""
            CREATE TABLE files(
                session_id TEXT PRIMARY KEY,
                mtime REAL NOT NULL,
                indexed_bytes INTEGER NOT NULL,
                cwds TEXT)
            """)
        exec("""
            CREATE VIRTUAL TABLE messages USING fts5(
                session_id UNINDEXED, body,
                tokenize = 'unicode61 remove_diacritics 2')
            """)
        exec("PRAGMA user_version = \(Self.schemaVersion)")
    }

    // MARK: Indexing (queue-confined)

    private func pruneUnlisted(_ listed: Set<String>) {
        var stale: [String] = []
        if let stmt = prepare("SELECT session_id FROM files") {
            while sqlite3_step(stmt) == SQLITE_ROW {
                if let c = sqlite3_column_text(stmt, 0) {
                    let id = String(cString: c)
                    if !listed.contains(id) { stale.append(id) }
                }
            }
            sqlite3_finalize(stmt)
        }
        guard !stale.isEmpty else { return }
        exec("BEGIN")
        for id in stale { deleteSession(id) }
        exec("COMMIT")
    }

    private func deleteSession(_ id: String) {
        for sql in ["DELETE FROM messages WHERE session_id = ?", "DELETE FROM files WHERE session_id = ?"] {
            if let stmt = prepare(sql) {
                bind(stmt, 1, id)
                sqlite3_step(stmt)
                sqlite3_finalize(stmt)
            }
        }
    }

    /// Index a file's unseen complete lines. Returns false when unchanged.
    @discardableResult
    private func indexFile(id: String, path: String) -> Bool {
        guard db != nil,
              let attrs = try? FileManager.default.attributesOfItem(atPath: path),
              let size = (attrs[.size] as? NSNumber)?.int64Value,
              let mtime = (attrs[.modificationDate] as? Date)?.timeIntervalSince1970
        else { return false }

        var from: Int64 = 0
        var reset = false
        var cwds: [String: Int] = [:]
        if let stmt = prepare("SELECT mtime, indexed_bytes, cwds FROM files WHERE session_id = ?") {
            bind(stmt, 1, id)
            if sqlite3_step(stmt) == SQLITE_ROW {
                let storedMtime = sqlite3_column_double(stmt, 0)
                let storedBytes = sqlite3_column_int64(stmt, 1)
                if storedMtime == mtime && storedBytes <= size {
                    sqlite3_finalize(stmt)
                    return false  // unchanged
                }
                if size >= storedBytes {
                    from = storedBytes
                    cwds = sqlite3_column_text(stmt, 2).map { Self.decodeCounts(String(cString: $0)) } ?? [:]
                } else {
                    reset = true
                }
            }
            sqlite3_finalize(stmt)
        }

        guard let handle = FileHandle(forReadingAtPath: path) else { return false }
        defer { handle.closeFile() }
        handle.seek(toFileOffset: UInt64(from))
        let data = handle.readDataToEndOfFile()

        // Only complete lines: a transcript being written may end mid-record.
        let consumed: Int
        if let nl = data.lastIndex(of: 0x0A) {
            consumed = data.distance(from: data.startIndex, to: nl) + 1
        } else {
            consumed = 0
        }

        exec("BEGIN")
        if reset { deleteSession(id) }
        if consumed > 0, let insert = prepare("INSERT INTO messages(session_id, body) VALUES(?, ?)") {
            TranscriptText.forEachMessage(in: data.prefix(consumed)) { _, text in
                sqlite3_reset(insert)
                bind(insert, 1, id)
                bind(insert, 2, text)
                sqlite3_step(insert)
            }
            sqlite3_finalize(insert)
        }
        if consumed > 0 { TranscriptRecord.tallyCwds(in: data.prefix(consumed), into: &cwds) }
        if let upsert = prepare("""
            INSERT INTO files(session_id, mtime, indexed_bytes, cwds) VALUES(?, ?, ?, ?)
            ON CONFLICT(session_id) DO UPDATE SET mtime = excluded.mtime,
                indexed_bytes = excluded.indexed_bytes, cwds = excluded.cwds
            """) {
            bind(upsert, 1, id)
            sqlite3_bind_double(upsert, 2, mtime)
            sqlite3_bind_int64(upsert, 3, from + Int64(consumed))
            bind(upsert, 4, Self.encodeCounts(cwds))
            sqlite3_step(upsert)
            sqlite3_finalize(upsert)
        }
        exec("COMMIT")
        return true
    }


    // MARK: SQLite helpers

    private func exec(_ sql: String) {
        guard let db else { return }
        if sqlite3_exec(db, sql, nil, nil, nil) != SQLITE_OK {
            logger.error("transcript index: \(String(cString: sqlite3_errmsg(db)), privacy: .public)")
        }
    }

    private func prepare(_ sql: String) -> OpaquePointer? {
        guard let db else { return nil }
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
            logger.error("transcript index: \(String(cString: sqlite3_errmsg(db)), privacy: .public)")
            return nil
        }
        return stmt
    }

    private func bind(_ stmt: OpaquePointer, _ index: Int32, _ text: String) {
        sqlite3_bind_text(stmt, index, text, -1, Self.transient)
    }
}

// MARK: - Relative Date Formatting

extension Date {
    /// Shared formatter for week-plus-old dates. `DateFormatter` instantiation is
    /// expensive (ICU/locale setup); `relativeString` is read by every row in the
    /// Projects and Sessions lists, so allocating one per call made scrolling
    /// beach-ball as `LazyVStack` realized rows. A configured `DateFormatter` is
    /// safe to share for read-only formatting across threads.
    private static let monthDayFormatter: DateFormatter = {
        let fmt = DateFormatter()
        fmt.dateFormat = "MMM d"
        return fmt
    }()

    var relativeString: String {
        let diff = Date().timeIntervalSince(self)
        if diff < 60 { return "just now" }
        if diff < 3600 { return "\(Int(diff / 60))m ago" }
        if diff < 86400 { return "\(Int(diff / 3600))h ago" }
        if diff < 604800 { return "\(Int(diff / 86400))d ago" }
        return Self.monthDayFormatter.string(from: self)
    }
}
