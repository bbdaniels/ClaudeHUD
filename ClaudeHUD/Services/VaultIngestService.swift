import AppKit
import Foundation
import Combine
import os

private let logger = Logger(subsystem: "com.claudehud", category: "VaultIngestService")

/// Reads the local state produced by the three workers in the vault-
/// tooling pipeline — `vault-ingest.sh` (SessionEnd ingest), the launchd
/// `obsidian-sync.sh` job, and each project's append-only `Sessions.md`
/// ledger — and publishes three streams the Vault cockpit (Phase 5) and
/// Session-History badges (Phase 4) consume:
///
///   1. `sessionStatus[sessionID]` — per-session provenance (ingested /
///      failed / unknown), built from `Sessions.md` rows with `.failed`
///      markers merged in.
///   2. `queue` — pending + failed ingest lists + the global paused
///      flag, for the cockpit ingest section.
///   3. `sync` — last `obsidian-sync.sh` start/end + result, parsed
///      from `~/Library/Logs/obsidian-sync.log`.
///
/// Read-only; never writes. Polls every 30s — debuggable today, FSEvents
/// is an easy upgrade later if responsiveness needs it.
///
/// Architecture: see Documents/Obsidian/ClaudeHUD/Technical Notes.md
/// §Vault tooling architecture (workers are independent of the HUD;
/// this service is observer-only).
@MainActor
final class VaultIngestService: ObservableObject {

    // MARK: - Public types

    struct SessionStatus: Equatable {
        enum Kind: String { case ingested, failed, unknown }
        let kind: Kind
        let project: String?        // resolved project folder name, nil if no row
        let utc: Date?              // when the ledger row was written
        let transcript: String?     // basename, e.g. "<sid>.jsonl"
        let notes: String?
    }

    struct PendingTranscript: Hashable, Identifiable {
        let path: URL               // ~/.claude/projects/<dir>/<sid>.jsonl
        let bytes: Int
        let mtime: Date
        var id: URL { path }
        /// `<session_id>` extracted from `<session_id>.jsonl` basename.
        var sessionID: String { path.deletingPathExtension().lastPathComponent }
    }

    struct FailedMarker: Hashable, Identifiable {
        let path: URL               // ~/.claude/ingest-state/<sid>.jsonl.<bytes>.failed
        let sessionID: String
        let bytes: Int
        let mtime: Date             // when the marker was written (worker exit time)
        var id: URL { path }
    }

    struct IngestQueue: Equatable {
        var pending: [PendingTranscript] = []
        var failed: [FailedMarker] = []
        var paused: Bool = false
        var doneLifetimeCount: Int = 0     // total `.done` markers in state dir
    }

    struct SyncStatus: Equatable {
        enum Result: String { case ok, failed, unknown }
        var lastStart: Date? = nil
        var lastEnd: Date? = nil
        var lastResult: Result = .unknown
        var lastError: String? = nil
    }

    // MARK: - Published state

    @Published private(set) var sessionStatus: [String: SessionStatus] = [:]
    @Published private(set) var queue = IngestQueue()
    @Published private(set) var sync = SyncStatus()
    @Published private(set) var lastRefresh: Date = .distantPast

    // MARK: - Configuration

    private(set) var vaultPath: URL?

    /// Match `vault-ingest.sh` constants exactly so the HUD's notion of
    /// "pending" matches what the worker considers ingestable.
    private let pendingFloor: Int = 6000           // bash FLOOR=6000
    private let pendingMaxAge: TimeInterval = 14 * 24 * 3600   // bash `-mtime -14`
    private let pendingMinAge: TimeInterval = 2 * 3600         // skip very fresh
    private let pollInterval: TimeInterval = 30

    private let home = FileManager.default.homeDirectoryForCurrentUser
    private var stateDir: URL { home.appending(path: ".claude/ingest-state") }
    private var transcriptsDir: URL { home.appending(path: ".claude/projects") }
    private var syncLog: URL { home.appending(path: "Library/Logs/obsidian-sync.log") }
    private var pausedFlag: URL { stateDir.appending(path: "PAUSED") }

    // MARK: - Lifecycle

    private var pollTimer: Timer?

    /// (Re-)start polling. Safe to call repeatedly when the active vault
    /// changes; replaces any existing timer.
    func start(vaultPath: URL?) {
        self.vaultPath = vaultPath
        refresh()
        pollTimer?.invalidate()
        pollTimer = Timer.scheduledTimer(withTimeInterval: pollInterval, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.refresh() }
        }
    }

    func stop() {
        pollTimer?.invalidate()
        pollTimer = nil
    }

    // MARK: - One-shot refresh

    func refresh() {
        let stateDirEntries = (try? FileManager.default.contentsOfDirectory(
            at: stateDir, includingPropertiesForKeys: [.contentModificationDateKey]
        )) ?? []

        let (doneKeys, doneCount) = classifyDoneMarkers(stateDirEntries)
        let failed = classifyFailedMarkers(stateDirEntries)
        let pending = scanPendingTranscripts(doneKeys: doneKeys)
        let paused = FileManager.default.fileExists(atPath: pausedFlag.path)
        var sessions = scanVaultSessionsLedgers()
        mergeFailedMarkersIntoSessions(failed, into: &sessions)

        self.sessionStatus = sessions
        self.queue = IngestQueue(pending: pending, failed: failed, paused: paused, doneLifetimeCount: doneCount)
        self.sync = parseSyncLog()
        self.lastRefresh = Date()
    }

    // MARK: - Convenience accessors

    func status(forSessionID sid: String) -> SessionStatus {
        sessionStatus[sid] ?? SessionStatus(kind: .unknown, project: nil, utc: nil, transcript: nil, notes: nil)
    }

    var pendingCount: Int { queue.pending.count }
    var failedCount: Int { queue.failed.count }

    // MARK: - Scanners

    /// Returns the set of `<sid>.jsonl.<bytes>` keys with a `.done`
    /// marker, plus the total `.done` count.
    private func classifyDoneMarkers(_ entries: [URL]) -> (Set<String>, Int) {
        var keys: Set<String> = []
        var count = 0
        for url in entries where url.pathExtension == "done" {
            count += 1
            let name = url.lastPathComponent
            if name.hasSuffix(".done") {
                keys.insert(String(name.dropLast(".done".count)))
            }
        }
        return (keys, count)
    }

    private func classifyFailedMarkers(_ entries: [URL]) -> [FailedMarker] {
        var out: [FailedMarker] = []
        for url in entries where url.pathExtension == "failed" {
            guard let parsed = parseMarkerName(url.lastPathComponent) else { continue }
            let mtime = (try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? Date.distantPast
            out.append(FailedMarker(path: url, sessionID: parsed.sessionID, bytes: parsed.bytes, mtime: mtime))
        }
        return out.sorted { $0.mtime > $1.mtime }
    }

    /// Parse `<sid>.jsonl.<bytes>.<done|failed>` → (sessionID, bytes).
    /// Returns nil on any unexpected shape so a stray file in the state
    /// dir cannot corrupt the view model.
    private func parseMarkerName(_ name: String) -> (sessionID: String, bytes: Int)? {
        var base = name
        for suffix in [".done", ".failed"] where base.hasSuffix(suffix) {
            base = String(base.dropLast(suffix.count))
            break
        }
        let parts = base.components(separatedBy: ".")
        guard parts.count >= 3,
              let bytes = Int(parts.last!),
              parts[parts.count - 2] == "jsonl" else { return nil }
        let sid = parts.dropLast(2).joined(separator: ".")
        guard !sid.isEmpty else { return nil }
        return (sid, bytes)
    }

    /// Walk `~/.claude/projects/*/*.jsonl`, list transcripts the worker
    /// would consider ingest-eligible but for which no `.done` key matches.
    ///
    /// Filters must match `vault-ingest.sh::is_ingest_eligible_path`:
    /// skip subagent transcripts (the parent session already covers
    /// them) and skip the home-cwd dir (sessions launched from `~`,
    /// which the worker already excludes in its phase-1 filter — old
    /// pre-filter ones shouldn't show up in the queue forever).
    private func scanPendingTranscripts(doneKeys: Set<String>) -> [PendingTranscript] {
        let now = Date()
        let projectDirs = (try? FileManager.default.contentsOfDirectory(
            at: transcriptsDir, includingPropertiesForKeys: nil
        )) ?? []
        let homeCwdDirName = "-Users-bbdaniels"
        var out: [PendingTranscript] = []
        for projectDir in projectDirs {
            if projectDir.lastPathComponent == homeCwdDirName { continue }
            let files = (try? FileManager.default.contentsOfDirectory(
                at: projectDir,
                includingPropertiesForKeys: [.fileSizeKey, .contentModificationDateKey]
            )) ?? []
            for url in files where url.pathExtension == "jsonl" {
                // `contentsOfDirectory` doesn't recurse, so subagent
                // transcripts under `<project>/subagents/` are never
                // walked. Belt-and-suspenders: defensive path check in
                // case we ever switch to a recursive enumerator.
                if url.path.contains("/subagents/") { continue }
                guard let attrs = try? url.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey]),
                      let size = attrs.fileSize,
                      let mtime = attrs.contentModificationDate else { continue }
                guard size > pendingFloor else { continue }
                let age = now.timeIntervalSince(mtime)
                guard age < pendingMaxAge, age > pendingMinAge else { continue }
                let key = "\(url.lastPathComponent).\(size)"
                if doneKeys.contains(key) { continue }
                // Machine one-shots (skill-tip selectors, liveness probes,
                // digest runs) are skipped by the worker without a model
                // call — keep them out of the cockpit count too. Checked
                // last: the 16 KB head read only happens for files that
                // would otherwise be counted pending.
                if Self.isMachineTranscript(url) { continue }
                out.append(PendingTranscript(path: url, bytes: size, mtime: mtime))
            }
        }
        return out.sorted { $0.mtime > $1.mtime }
    }

    /// Whether a transcript is a programmatic `claude -p` one-shot rather
    /// than a person's session. Mirrors `vault-ingest.sh::is_machine_transcript`
    /// (canonical) and `SessionHistoryService.classifyHead`: the first user
    /// record of an SDK run carries `entrypoint: "sdk-cli"` /
    /// `promptSource: "sdk"`; prefix checks cover older transcripts that
    /// predate those fields.
    nonisolated private static func isMachineTranscript(_ url: URL) -> Bool {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return false }
        defer { try? handle.close() }
        let data = handle.readData(ofLength: 16384)
        guard let text = String(data: data, encoding: .utf8) else { return false }

        let machinePrefixes = [
            "You select the single most relevant skill",
            "# Session Ingest",
            "<!-- === Managed by ClaudeHUD",
            "Reply with exactly",
            "Return ONLY this JSON object",
        ]
        for line in text.components(separatedBy: "\n").prefix(50) {
            guard !line.isEmpty,
                  let lineData = line.data(using: .utf8),
                  let json = try? JSONSerialization.jsonObject(with: lineData) as? [String: Any],
                  json["type"] as? String == "user"
            else { continue }
            if json["entrypoint"] as? String == "sdk-cli"
                || json["promptSource"] as? String == "sdk" { return true }
            if let msg = json["message"] as? [String: Any],
               let content = msg["content"] as? String {
                let trimmed = content.trimmingCharacters(in: .whitespacesAndNewlines)
                if machinePrefixes.contains(where: { trimmed.hasPrefix($0) }) { return true }
            }
            return false  // first user record is a real prompt
        }
        return false
    }

    /// Walk `<vault>/*/Sessions.md` and build `session_id → SessionStatus`.
    /// No-op if no vault is configured.
    private func scanVaultSessionsLedgers() -> [String: SessionStatus] {
        guard let vault = vaultPath else { return [:] }
        var out: [String: SessionStatus] = [:]
        let folders = (try? FileManager.default.contentsOfDirectory(
            at: vault, includingPropertiesForKeys: [.isDirectoryKey]
        )) ?? []
        for folder in folders {
            guard let isDir = try? folder.resourceValues(forKeys: [.isDirectoryKey]).isDirectory, isDir,
                  !folder.lastPathComponent.hasPrefix(".") else { continue }
            let ledger = folder.appending(path: "Sessions.md")
            guard let content = try? String(contentsOf: ledger, encoding: .utf8) else { continue }
            parseSessionsTable(content, project: folder.lastPathComponent, into: &out)
        }
        return out
    }

    /// Parse a Sessions.md table. Rows look like:
    ///   `| <utc> | <session_id> | <cwd> | <transcript> | <status> | <notes> |`
    /// Skip frontmatter, header lines, the column header, and the `|---|` separator.
    /// Append-only convention: later rows overwrite earlier (latest wins).
    private func parseSessionsTable(_ content: String, project: String, into out: inout [String: SessionStatus]) {
        let iso = ISO8601DateFormatter()
        iso.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let isoBasic = ISO8601DateFormatter()
        isoBasic.formatOptions = [.withInternetDateTime]

        for raw in content.components(separatedBy: "\n") {
            let trimmed = raw.trimmingCharacters(in: .whitespaces)
            guard trimmed.hasPrefix("|"), trimmed.hasSuffix("|") else { continue }
            // Skip the alignment row: `|---|---|...`
            if trimmed.contains("---") && !trimmed.contains(" ") { continue }
            let parts = trimmed.split(separator: "|", omittingEmptySubsequences: false)
                .map { $0.trimmingCharacters(in: .whitespaces) }
            // Expect 8 cells (leading + 6 columns + trailing) for a proper row.
            guard parts.count >= 7 else { continue }
            let utcStr = parts[1]
            let sid = parts[2]
            let transcript = parts[4]
            let status = parts[5]
            let notes = parts[6]
            // Filter header row + any non-UUID-shaped sid.
            guard sid != "session_id", sid.contains("-"), !sid.isEmpty else { continue }

            let kind: SessionStatus.Kind
            switch status.lowercased() {
            case "ingested", "reassigned", "manual": kind = .ingested
            case "failed": kind = .failed
            default: kind = .unknown
            }
            let date = iso.date(from: utcStr) ?? isoBasic.date(from: utcStr)
            out[sid] = SessionStatus(
                kind: kind,
                project: project,
                utc: date,
                transcript: transcript.isEmpty ? nil : transcript,
                notes: notes.isEmpty ? nil : notes
            )
        }
    }

    /// Bring `.failed` markers into the session map for IDs that have no
    /// ledger row yet. Ledger rows (with status `ingested`) take priority
    /// — a once-failed session that later succeeds shows as ingested.
    private func mergeFailedMarkersIntoSessions(_ failed: [FailedMarker], into out: inout [String: SessionStatus]) {
        for f in failed {
            if let existing = out[f.sessionID], existing.kind == .ingested { continue }
            out[f.sessionID] = SessionStatus(
                kind: .failed,
                project: out[f.sessionID]?.project,
                utc: f.mtime,
                transcript: "\(f.sessionID).jsonl",
                notes: out[f.sessionID]?.notes
            )
        }
    }

    /// Read the sync log tail and pull the most recent start/end pair.
    /// Format (per `obsidian-sync.sh`):
    ///   `===== 2026-05-26T16:20:09Z sync start =====`
    ///   `===== 2026-05-26T16:20:13Z sync ok =====`
    /// Failure mode contains the literal `REBASE FAILED` or `FAILED after`.
    private func parseSyncLog() -> SyncStatus {
        guard let content = try? String(contentsOf: syncLog, encoding: .utf8) else {
            return SyncStatus()
        }
        let iso = ISO8601DateFormatter()
        iso.formatOptions = [.withInternetDateTime]
        // Walk from end so the most recent markers win.
        let lines = content.components(separatedBy: "\n").reversed()
        var status = SyncStatus()
        var lastFailureLine: String?
        for line in lines {
            if status.lastEnd == nil, line.contains("sync ok =====") {
                status.lastEnd = extractSyncTimestamp(line, formatter: iso)
                status.lastResult = .ok
                continue
            }
            if status.lastResult == .unknown, line.contains("FAILED") || line.contains("sync error") {
                lastFailureLine = line
                status.lastResult = .failed
                continue
            }
            if status.lastStart == nil, line.contains("sync start =====") {
                status.lastStart = extractSyncTimestamp(line, formatter: iso)
                // We have what we need (start + end or start + failure); stop.
                if status.lastEnd != nil || status.lastResult == .failed { break }
            }
        }
        if status.lastResult == .failed { status.lastError = lastFailureLine }
        return status
    }

    private func extractSyncTimestamp(_ line: String, formatter: ISO8601DateFormatter) -> Date? {
        let pattern = #"\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}Z"#
        guard let regex = try? NSRegularExpression(pattern: pattern),
              let match = regex.firstMatch(in: line, options: [], range: NSRange(line.startIndex..., in: line)),
              let range = Range(match.range, in: line) else { return nil }
        return formatter.date(from: String(line[range]))
    }

    // MARK: - Actions (cockpit-only writes)
    //
    // Polling (everything above) is observer-only. The actions below are
    // the deliberate exception: they write into the same shared state
    // the workers read, but only in response to explicit cockpit clicks.
    // Each one triggers a refresh() so the UI reflects the new state
    // without waiting for the 30s poll.

    /// Delete a `.failed` marker so the next SessionEnd retries the
    /// session (the worker scans pending transcripts against `.done`
    /// keys, not `.failed`, so removing the marker is sufficient).
    func retryFailed(_ marker: FailedMarker) {
        try? FileManager.default.removeItem(at: marker.path)
        refresh()
    }

    /// Bulk variant — clears every `.failed` marker the worker wrote.
    /// Does not invoke the worker directly; the next SessionEnd hook
    /// picks up the pending list. Use `triggerIngestNow` to force.
    func retryAllFailed() {
        for marker in queue.failed {
            try? FileManager.default.removeItem(at: marker.path)
        }
        refresh()
    }

    /// Touch / remove `~/.claude/ingest-state/PAUSED`. The worker
    /// short-circuits when this file exists, leaving the queue intact.
    func setPaused(_ paused: Bool) {
        if paused {
            FileManager.default.createFile(atPath: pausedFlag.path, contents: nil)
        } else {
            try? FileManager.default.removeItem(at: pausedFlag)
        }
        refresh()
    }

    /// Fire `~/.local/bin/obsidian-sync.sh` in the background — this is
    /// where `VaultScriptInstaller` installs it and what the launchd job
    /// runs, so the "Sync now" button hits the same script as the cron.
    /// Best-effort — failures land in `~/Library/Logs/obsidian-sync.log`
    /// and surface via `parseSyncLog()` on the next refresh.
    func triggerSync() {
        let script = home.appending(path: ".local/bin/obsidian-sync.sh").path
        guard FileManager.default.isExecutableFile(atPath: script) else {
            logger.warning("obsidian-sync.sh not installed at \(script)")
            return
        }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/bash")
        process.arguments = [script]
        do {
            try process.run()
        } catch {
            logger.error("failed to launch obsidian-sync.sh: \(error.localizedDescription)")
        }
    }

    /// Fire `~/.claude/scripts/vault-ingest.sh --run` to immediately
    /// process the current pending list. Synchronous-ish — caller
    /// should expect a refresh() after a short delay.
    func triggerIngestNow() {
        let script = home.appending(path: ".claude/scripts/vault-ingest.sh").path
        guard FileManager.default.isExecutableFile(atPath: script) else {
            logger.warning("vault-ingest.sh not installed at \(script)")
            return
        }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/bash")
        process.arguments = [script, "--run"]
        do {
            try process.run()
        } catch {
            logger.error("failed to launch vault-ingest.sh: \(error.localizedDescription)")
        }
    }

    /// Process up to `limit` pending eligible transcripts in sequence
    /// via `vault-ingest.sh --backfill <N>`. One click in the cockpit
    /// burns down the historical backlog in batches; default N=10 keeps
    /// the LLM cost predictable. Launched detached because each session
    /// runs `claude -p` (multi-second), and the user wants the UI to
    /// stay responsive.
    func runBacklog(limit: Int = 10) {
        let script = home.appending(path: ".claude/scripts/vault-ingest.sh").path
        guard FileManager.default.isExecutableFile(atPath: script) else {
            logger.warning("vault-ingest.sh not installed at \(script)")
            return
        }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/bash")
        process.arguments = [script, "--backfill", String(limit)]
        do {
            try process.run()
        } catch {
            logger.error("failed to launch vault-ingest.sh --backfill: \(error.localizedDescription)")
        }
    }

    /// Open `~/.claude/scripts/` in Finder so the user can inspect the
    /// managed scripts directly.
    func revealScriptsInFinder() {
        let scriptsDir = home.appending(path: ".claude/scripts")
        NSWorkspace.shared.activateFileViewerSelecting([scriptsDir])
    }

    /// Open `~/.claude/ingest-state/` in Finder so the user can inspect
    /// markers directly (advanced — usually the per-row reveal buttons
    /// on Session History badges are enough).
    func revealStateDirInFinder() {
        NSWorkspace.shared.activateFileViewerSelecting([stateDir])
    }
}
