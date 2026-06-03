import Foundation
import os

private let logger = Logger(subsystem: "com.claudehud", category: "VaultScriptInstaller")

/// Versions, audits, and (when asked) installs the Karpathy vault-tooling
/// scripts (SessionEnd ingest hook, 15-min sync, reset, plus the launchd
/// plist) into their canonical locations under $HOME. Bundled copies in
/// `Resources/Scripts/` and `Resources/LaunchAgents/` carry a managed-by
/// header with a `script-version: X.Y.Z`; the installer reads that header
/// from the installed copy to decide what to do without clobbering local
/// edits.
///
/// Architecture rationale (cockpit / workers / cleaner three-layer split):
/// see `Documents/Obsidian/ClaudeHUD/Technical Notes.md` §Vault tooling
/// architecture. The HUD owns *distribution* + *view* + *manual triggers*;
/// it does NOT own the worker runtime — the SessionEnd hook is invoked by
/// Claude Code, the 15-min sync by launchd. This installer is purely the
/// ship-and-stamp step.
///
/// Phase 1 wires `audit()` only; `install(force:)` lands once the cockpit
/// UI exists to surface conflicts.
@MainActor
final class VaultScriptInstaller: ObservableObject {

    // MARK: - Public types

    enum Status: Equatable {
        case missing                       // not installed at all
        case unmanagedSameBody             // installed, no header, body matches → safe to stamp
        case unmanagedDifferentBody        // installed, no header, body differs → needs force
        case current(version: String)      // installed, header matches bundled version
        case outdated(installed: String, bundled: String)
        case userEdited(version: String)   // installed, header matches version, body differs
    }

    struct ManagedScript: Hashable {
        let bundleResource: String         // file name in app bundle (with extension)
        let installPath: URL
        let executable: Bool
        let kind: Kind

        enum Kind { case sh, md, plist }
    }

    @Published private(set) var lastAudit: [ManagedScript: Status] = [:]

    static let bundledVersion = "1.3.0"

    static let managed: [ManagedScript] = {
        let home = FileManager.default.homeDirectoryForCurrentUser
        return [
            .init(bundleResource: "vault-ingest.sh",
                  installPath: home.appending(path: ".claude/scripts/vault-ingest.sh"),
                  executable: true,
                  kind: .sh),
            .init(bundleResource: "vault-ingest-prompt.md",
                  installPath: home.appending(path: ".claude/scripts/vault-ingest-prompt.md"),
                  executable: false,
                  kind: .md),
            .init(bundleResource: "vault-reset.sh",
                  installPath: home.appending(path: ".claude/scripts/vault-reset.sh"),
                  executable: true,
                  kind: .sh),
            .init(bundleResource: "obsidian-sync.sh",
                  installPath: home.appending(path: ".local/bin/obsidian-sync.sh"),
                  executable: true,
                  kind: .sh),
            .init(bundleResource: "com.bbdaniels.obsidian-sync.plist",
                  installPath: home.appending(path: "Library/LaunchAgents/com.bbdaniels.obsidian-sync.plist"),
                  executable: false,
                  kind: .plist),
            // Periodic background drain of the ingest backlog. New in
            // 1.2.0 — pairs with vault-ingest.sh --backfill, runs every
            // 30 min via launchd. See com.bbdaniels.vault-backfill.plist
            // header for cadence + pause-flag semantics.
            .init(bundleResource: "com.bbdaniels.vault-backfill.plist",
                  installPath: home.appending(path: "Library/LaunchAgents/com.bbdaniels.vault-backfill.plist"),
                  executable: false,
                  kind: .plist),
        ]
    }()

    // MARK: - Audit (observation only; never writes)

    @discardableResult
    func audit() -> [ManagedScript: Status] {
        var out: [ManagedScript: Status] = [:]
        for script in Self.managed {
            out[script] = inspect(script)
        }
        lastAudit = out
        logAudit(out)
        return out
    }

    // MARK: - Install (writes; called from cockpit UI in Phase 3)

    /// Bring all managed scripts up to the bundled version.
    /// - Parameter force: also overwrite files flagged
    ///   `.unmanagedDifferentBody` or `.userEdited` (caller has confirmed).
    func install(force: Bool = false) throws {
        for script in Self.managed {
            try installOne(script, force: force)
        }
        audit()
    }

    // MARK: - Single-file logic

    private func inspect(_ script: ManagedScript) -> Status {
        guard let bundled = bundledContent(for: script) else {
            return .missing
        }
        guard FileManager.default.fileExists(atPath: script.installPath.path),
              let installed = try? String(contentsOf: script.installPath, encoding: .utf8) else {
            return .missing
        }

        let bundledBody = stripHeader(bundled)
        let installedBody = stripHeader(installed)
        let installedHeader = parseHeader(installed)
        let bundledHeader = parseHeader(bundled)

        if installedHeader == nil {
            return bundledBody == installedBody ? .unmanagedSameBody : .unmanagedDifferentBody
        }
        let iv = installedHeader!.version
        let bv = bundledHeader?.version ?? Self.bundledVersion
        if iv == bv {
            return bundledBody == installedBody ? .current(version: iv) : .userEdited(version: iv)
        } else {
            return .outdated(installed: iv, bundled: bv)
        }
    }

    private func installOne(_ script: ManagedScript, force: Bool) throws {
        let status = inspect(script)
        switch status {
        case .current:
            return
        case .missing, .unmanagedSameBody, .outdated:
            try write(script)
        case .unmanagedDifferentBody, .userEdited:
            if force {
                try write(script)
            } else {
                logger.warning("skipping \(script.bundleResource): \(self.label(status)) — pass force: true to overwrite")
            }
        }
    }

    private func write(_ script: ManagedScript) throws {
        guard let bundled = bundledContent(for: script) else {
            throw NSError(
                domain: "VaultScriptInstaller",
                code: 1,
                userInfo: [NSLocalizedDescriptionKey: "bundled resource \(script.bundleResource) not found"]
            )
        }
        let dir = script.installPath.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try bundled.write(to: script.installPath, atomically: true, encoding: .utf8)
        let mode: NSNumber = script.executable ? 0o755 : 0o644
        try FileManager.default.setAttributes([.posixPermissions: mode], ofItemAtPath: script.installPath.path)
        logger.info("installed \(script.installPath.path)")
        // launchd jobs need to be (re)loaded after their plist lands;
        // otherwise the new file just sits on disk while the old one
        // (or nothing) keeps running. Idempotent: unload silently fails
        // if the job wasn't loaded.
        if script.kind == .plist {
            runLaunchctl(["unload", script.installPath.path])
            runLaunchctl(["load", "-w", script.installPath.path])
        }
    }

    private func runLaunchctl(_ args: [String]) {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/launchctl")
        p.arguments = args
        p.standardOutput = Pipe()
        p.standardError = Pipe()
        do {
            try p.run()
            p.waitUntilExit()
        } catch {
            logger.error("launchctl \(args.first ?? "") failed: \(error.localizedDescription)")
        }
    }

    // MARK: - Bundle access

    private func bundledContent(for script: ManagedScript) -> String? {
        let base = (script.bundleResource as NSString).deletingPathExtension
        let ext = (script.bundleResource as NSString).pathExtension
        guard let url = Bundle.main.url(forResource: base, withExtension: ext) else {
            logger.error("bundled resource not found: \(script.bundleResource)")
            return nil
        }
        return try? String(contentsOf: url, encoding: .utf8)
    }

    // MARK: - Header parsing

    private struct Header { let version: String }

    /// Extract `script-version: X.Y.Z` from a managed-by header if present.
    private func parseHeader(_ content: String) -> Header? {
        guard content.contains("Managed by ClaudeHUD") else { return nil }
        let pattern = #"script-version:\s*([^\s\n]+)"#
        guard let regex = try? NSRegularExpression(pattern: pattern, options: []) else { return nil }
        let range = NSRange(content.startIndex..., in: content)
        guard let match = regex.firstMatch(in: content, options: [], range: range),
              let versionRange = Range(match.range(at: 1), in: content) else {
            return nil
        }
        return Header(version: String(content[versionRange]))
    }

    /// Strip the managed-by header (if present) so body-only comparison
    /// is stable across stamping. The header spans from the `=== Managed
    /// by ClaudeHUD ===` opener line to the next `===` closer line; for
    /// `.md` / `.plist` files the surrounding `<!--` / `-->` are removed
    /// too, and a trailing blank line is collapsed.
    private func stripHeader(_ content: String) -> String {
        guard content.contains("Managed by ClaudeHUD") else { return content }
        var lines = content.components(separatedBy: "\n")
        var openerIdx: Int?
        var closerIdx: Int?
        for (i, line) in lines.enumerated() {
            if line.contains("Managed by ClaudeHUD") && line.contains("===") {
                openerIdx = i
            } else if let oi = openerIdx, i > oi, line.contains("===") {
                closerIdx = i
                break
            }
        }
        guard let oi = openerIdx, let ci = closerIdx else { return content }
        var lo = oi
        var hi = ci
        if lo > 0 && lines[lo - 1].trimmingCharacters(in: .whitespaces) == "<!--" {
            lo -= 1
        }
        if hi + 1 < lines.count && lines[hi + 1].trimmingCharacters(in: .whitespaces) == "-->" {
            hi += 1
        }
        lines.removeSubrange(lo...hi)
        // If removal left a leading blank line (e.g. plist had `<?xml…?>`
        // then blank then header), keep `<?xml…?>` but not the blank.
        if lo > 0 && lo < lines.count && lines[lo].trimmingCharacters(in: .whitespaces).isEmpty {
            lines.remove(at: lo)
        } else if lo == 0 && !lines.isEmpty && lines[0].trimmingCharacters(in: .whitespaces).isEmpty {
            lines.removeFirst()
        }
        return lines.joined(separator: "\n")
    }

    // MARK: - Logging

    private func logAudit(_ statuses: [ManagedScript: Status]) {
        let summary = statuses
            .sorted { $0.key.bundleResource < $1.key.bundleResource }
            .map { "\($0.key.bundleResource): \(label($0.value))" }
            .joined(separator: "; ")
        logger.info("vault scripts audit — \(summary)")
    }

    fileprivate func label(_ s: Status) -> String {
        switch s {
        case .missing: return "missing"
        case .unmanagedSameBody: return "unmanaged (ready to stamp)"
        case .unmanagedDifferentBody: return "unmanaged (different — needs force)"
        case .current(let v): return "current (v\(v))"
        case .outdated(let i, let b): return "outdated (v\(i) → v\(b))"
        case .userEdited(let v): return "user-edited (v\(v) — needs force)"
        }
    }
}
