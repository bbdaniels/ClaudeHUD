import AppKit
import Foundation
import Combine
import os

private let logger = Logger(subsystem: "com.claudehud", category: "VaultIngestService")

/// Reads two pieces of local state the vault's workers leave behind and
/// publishes them for the Vault tab:
///
///   1. `sessionStatus[sessionID]`: per-session provenance (ingested /
///      failed / unknown), built from each project's append-only
///      `Sessions.md` ledger. The daily review (personal repo,
///      `vault/daily_review`) is the automation that appends those rows.
///   2. `sync`: last `obsidian-sync.sh` start/end and result, parsed from
///      `~/Library/Logs/obsidian-sync.log`.
///
/// The polling is read-only. Polls every 30s. The one action, `triggerSync`,
/// starts the same sync script launchd runs. Nothing here starts, pauses or
/// retries the daily review.
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

    struct SyncStatus: Equatable {
        enum Result: String { case ok, failed, unknown }
        var lastStart: Date? = nil
        var lastEnd: Date? = nil
        var lastResult: Result = .unknown
        var lastError: String? = nil
    }

    // MARK: - Published state

    @Published private(set) var sessionStatus: [String: SessionStatus] = [:]
    @Published private(set) var sync = SyncStatus()
    @Published private(set) var lastRefresh: Date = .distantPast

    // MARK: - Configuration

    private(set) var vaultPath: URL?

    private let pollInterval: TimeInterval = 30

    private let home = FileManager.default.homeDirectoryForCurrentUser
    // nonisolated: read from the off-main scan in refresh(). It derives only
    // from the immutable `home` let, so it is safe to touch outside the
    // MainActor.
    nonisolated private var syncLog: URL { home.appending(path: "Library/Logs/obsidian-sync.log") }

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
        // Snapshot the one mutable config (vaultPath) on the main actor, then
        // do all filesystem work off-main. Both scanners below are
        // `nonisolated` and read only immutable config, so summoning the HUD
        // and the 30s poll never block the main thread. The scan is read-only
        // and idempotent, so overlapping runs are harmless: last assignment
        // wins and the next poll reconciles.
        let vaultPath = self.vaultPath
        Task.detached(priority: .utility) { [weak self] in
            guard let self else { return }
            let sessions = self.scanVaultSessionsLedgers(vaultPath: vaultPath)
            let sync = self.parseSyncLog()

            await MainActor.run {
                self.sessionStatus = sessions
                self.sync = sync
                self.lastRefresh = Date()
            }
        }
    }

    // MARK: - Scanners

    /// Walk `<vault>/*/Sessions.md` and build `session_id → SessionStatus`.
    /// No-op if no vault is configured.
    nonisolated private func scanVaultSessionsLedgers(vaultPath: URL?) -> [String: SessionStatus] {
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
    nonisolated private func parseSessionsTable(_ content: String, project: String, into out: inout [String: SessionStatus]) {
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

    /// Read the sync log tail and pull the most recent start/end pair.
    /// Format (per `obsidian-sync.sh`):
    ///   `===== 2026-05-26T16:20:09Z sync start =====`
    ///   `===== 2026-05-26T16:20:13Z sync ok =====`
    /// Failure mode contains the literal `REBASE FAILED` or `FAILED after`.
    nonisolated private func parseSyncLog() -> SyncStatus {
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

    nonisolated private func extractSyncTimestamp(_ line: String, formatter: ISO8601DateFormatter) -> Date? {
        let pattern = #"\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}Z"#
        guard let regex = try? NSRegularExpression(pattern: pattern),
              let match = regex.firstMatch(in: line, options: [], range: NSRange(line.startIndex..., in: line)),
              let range = Range(match.range, in: line) else { return nil }
        return formatter.date(from: String(line[range]))
    }

    // MARK: - Actions

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

    /// Open `~/.claude/scripts/` in Finder so the user can inspect the
    /// managed scripts directly.
    func revealScriptsInFinder() {
        let scriptsDir = home.appending(path: ".claude/scripts")
        NSWorkspace.shared.activateFileViewerSelecting([scriptsDir])
    }
}
