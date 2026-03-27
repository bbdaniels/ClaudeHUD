import Foundation
import os

private let logger = Logger(subsystem: "com.claudehud", category: "PermissionWatcher")

// MARK: - Permission Request Model

struct PendingPermission: Identifiable {
    let id: String
    let toolName: String
    let summary: String
    let project: String
    let projectPath: String
    let timestamp: Date
}

// MARK: - Permission Watcher Service

@MainActor
class PermissionWatcherService: ObservableObject {
    @Published var pending: [PendingPermission] = []
    @Published private(set) var hookInstalled = false

    private let hudDir = "\(NSHomeDirectory())/.claude/hud"
    private var pendingDir: String { "\(hudDir)/pending" }
    private var decisionsDir: String { "\(hudDir)/decisions" }
    private var heartbeatPath: String { "\(hudDir)/heartbeat" }
    private var hookScriptPath: String {
        "\(NSHomeDirectory())/.claude/hooks/permission-watcher.sh"
    }

    private var pollTimer: Timer?
    private var heartbeatTimer: Timer?

    func start() {
        let fm = FileManager.default
        try? fm.createDirectory(atPath: pendingDir, withIntermediateDirectories: true)
        try? fm.createDirectory(atPath: decisionsDir, withIntermediateDirectories: true)

        installScript()
        installHook()
        writeHeartbeat()

        // Heartbeat every 5 seconds
        heartbeatTimer = Timer.scheduledTimer(withTimeInterval: 5, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.writeHeartbeat() }
        }

        // Poll pending directory every 0.5 seconds
        pollTimer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.pollPending() }
        }
    }

    func stop() {
        pollTimer?.invalidate()
        pollTimer = nil
        heartbeatTimer?.invalidate()
        heartbeatTimer = nil
        // Remove heartbeat so hooks fall through immediately
        try? FileManager.default.removeItem(atPath: heartbeatPath)
    }

    // MARK: - Approve / Deny

    func approve(_ id: String) {
        let decision: [String: Any] = [
            "hookSpecificOutput": [
                "hookEventName": "PermissionRequest",
                "decision": ["behavior": "allow"]
            ]
        ]
        writeDecision(id: id, decision: decision)
        pending.removeAll { $0.id == id }
    }

    func deny(_ id: String) {
        let decision: [String: Any] = [
            "hookSpecificOutput": [
                "hookEventName": "PermissionRequest",
                "decision": [
                    "behavior": "deny",
                    "message": "Denied from ClaudeHUD"
                ]
            ]
        ]
        writeDecision(id: id, decision: decision)
        pending.removeAll { $0.id == id }
    }

    // MARK: - Private

    private func writeHeartbeat() {
        let ts = "\(Int(Date().timeIntervalSince1970))"
        try? ts.write(toFile: heartbeatPath, atomically: true, encoding: .utf8)
    }

    private func pollPending() {
        let fm = FileManager.default
        guard let files = try? fm.contentsOfDirectory(atPath: pendingDir) else { return }

        let jsonFiles = files.filter { $0.hasSuffix(".json") }
        let now = Date()

        // Remove files older than 2 minutes (hook timeout is 90s, so these are stale)
        for file in jsonFiles {
            let path = "\(pendingDir)/\(file)"
            if let attrs = try? fm.attributesOfItem(atPath: path),
               let mtime = attrs[.modificationDate] as? Date,
               now.timeIntervalSince(mtime) > 120 {
                try? fm.removeItem(atPath: path)
            }
        }

        // Re-read after cleanup
        let liveFiles = (try? fm.contentsOfDirectory(atPath: pendingDir))?.filter { $0.hasSuffix(".json") } ?? []
        let activeIds = Set(liveFiles.map { String($0.dropLast(5)) }) // remove .json

        // Build the new pending list without mutating @Published until the end
        var newPending = pending.filter { activeIds.contains($0.id) }

        // Detect requests that were resolved in the terminal
        let resolvedIds = Set(newPending.filter { entry in
            sessionHasProgressedSince(projectPath: entry.projectPath, since: entry.timestamp)
        }.map(\.id))
        for id in resolvedIds {
            try? fm.removeItem(atPath: "\(pendingDir)/\(id).json")
        }
        newPending.removeAll { resolvedIds.contains($0.id) }

        // Add new entries (and clean up empty/unparseable files)
        let existingIds = Set(newPending.map(\.id))
        for file in liveFiles {
            let id = String(file.dropLast(5))
            guard !existingIds.contains(id) else { continue }

            let path = "\(pendingDir)/\(file)"
            guard let data = fm.contents(atPath: path),
                  !data.isEmpty,
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
            else {
                try? fm.removeItem(atPath: "\(pendingDir)/\(file)")
                continue
            }

            let toolName = json["tool_name"] as? String ?? "Unknown"
            let toolInput = json["tool_input"] as? [String: Any] ?? [:]
            let project = json["project"] as? String ?? "Unknown"
            let projectPath = json["project_path"] as? String ?? ""
            let ts = json["timestamp"] as? TimeInterval ?? Date().timeIntervalSince1970

            let summary = Self.summarize(tool: toolName, input: toolInput)

            newPending.append(PendingPermission(
                id: id,
                toolName: toolName,
                summary: summary,
                project: project,
                projectPath: projectPath,
                timestamp: Date(timeIntervalSince1970: ts)
            ))
        }

        newPending.sort { $0.timestamp > $1.timestamp }

        // Only publish if the list actually changed — avoids triggering
        // SwiftUI view graph updates every 0.5s when nothing changed
        let newIds = newPending.map(\.id)
        let oldIds = pending.map(\.id)
        if newIds != oldIds {
            pending = newPending
        }
    }

    /// Check if the Claude session for a project has written new events since a given time.
    /// When the user approves in terminal, Claude proceeds and writes to the session JSONL,
    /// making the most recent file's mtime advance past the permission request time.
    private func sessionHasProgressedSince(projectPath: String, since: Date) -> Bool {
        let fm = FileManager.default
        // Claude stores sessions in ~/.claude/projects/<encoded-path>/
        // The encoded path replaces / with -
        let encoded = projectPath.replacingOccurrences(of: "/", with: "-")
        let sessionDir = "\(NSHomeDirectory())/.claude/projects/\(encoded)"

        guard let files = try? fm.contentsOfDirectory(atPath: sessionDir) else { return false }
        let jsonlFiles = files.filter { $0.hasSuffix(".jsonl") }

        // Find the most recently modified JSONL file
        var latestMtime: Date?
        for file in jsonlFiles {
            let path = "\(sessionDir)/\(file)"
            if let attrs = try? fm.attributesOfItem(atPath: path),
               let mtime = attrs[.modificationDate] as? Date {
                if latestMtime == nil || mtime > latestMtime! {
                    latestMtime = mtime
                }
            }
        }

        // If the latest session file was modified after the permission request
        // (with a small buffer for the hook write), Claude has moved on
        guard let mtime = latestMtime else { return false }
        return mtime.timeIntervalSince(since) > 1.0
    }

    private func writeDecision(id: String, decision: [String: Any]) {
        let path = "\(decisionsDir)/\(id).json"
        if let data = try? JSONSerialization.data(withJSONObject: decision) {
            try? data.write(to: URL(fileURLWithPath: path))
        }
        // Also remove the pending file
        try? FileManager.default.removeItem(atPath: "\(pendingDir)/\(id).json")
    }

    private static func summarize(tool: String, input: [String: Any]) -> String {
        switch tool {
        case "Bash":
            let cmd = input["command"] as? String ?? ""
            return String(cmd.prefix(120))
        case "Edit":
            let file = input["file_path"] as? String ?? ""
            let name = URL(fileURLWithPath: file).lastPathComponent
            return "Edit \(name)"
        case "Write":
            let file = input["file_path"] as? String ?? ""
            let name = URL(fileURLWithPath: file).lastPathComponent
            return "Write \(name)"
        case "NotebookEdit":
            let file = input["file_path"] as? String ?? ""
            let name = URL(fileURLWithPath: file).lastPathComponent
            return "Edit notebook \(name)"
        default:
            return tool
        }
    }

    // MARK: - Script & Hook Installation

    private func installScript() {
        let dest = URL(fileURLWithPath: hookScriptPath)
        let hooksDir = dest.deletingLastPathComponent()

        do {
            try FileManager.default.createDirectory(at: hooksDir, withIntermediateDirectories: true)

            guard let bundleURL = Bundle.main.url(forResource: "permission-watcher", withExtension: "sh") else {
                logger.error("permission-watcher.sh not found in app bundle")
                return
            }

            if FileManager.default.fileExists(atPath: dest.path) {
                try FileManager.default.removeItem(at: dest)
            }
            try FileManager.default.copyItem(at: bundleURL, to: dest)
            try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: dest.path)
            logger.info("permission-watcher.sh installed")
        } catch {
            logger.error("Failed to install permission-watcher.sh: \(error)")
        }
    }

    private func installHook() {
        let settingsURL = URL(fileURLWithPath: NSHomeDirectory())
            .appendingPathComponent(".claude/settings.json")

        var settings: [String: Any] = [:]
        if let data = try? Data(contentsOf: settingsURL),
           let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            settings = json
        }

        var hooks = settings["hooks"] as? [String: Any] ?? [:]

        // Clean up any old PermissionRequest registration
        if var permReq = hooks["PermissionRequest"] as? [[String: Any]] {
            permReq.removeAll { entry in
                guard let innerHooks = entry["hooks"] as? [[String: Any]] else { return false }
                return innerHooks.contains { ($0["command"] as? String)?.contains("permission-watcher.sh") == true }
            }
            hooks["PermissionRequest"] = permReq.isEmpty ? nil : permReq
        }

        // Clean up any old PreToolUse registration
        if var preToolUse = hooks["PreToolUse"] as? [[String: Any]] {
            preToolUse.removeAll { entry in
                guard let innerHooks = entry["hooks"] as? [[String: Any]] else { return false }
                return innerHooks.contains { ($0["command"] as? String)?.contains("permission-watcher.sh") == true }
            }
            hooks["PreToolUse"] = preToolUse.isEmpty ? nil : preToolUse
        }

        // Register as PermissionRequest hook — fires when permission dialog is about to show
        var permReq = hooks["PermissionRequest"] as? [[String: Any]] ?? []
        permReq.removeAll { entry in
            guard let innerHooks = entry["hooks"] as? [[String: Any]] else { return false }
            return innerHooks.contains { ($0["command"] as? String)?.contains("permission-watcher.sh") == true }
        }
        permReq.append([
            "hooks": [["type": "command", "command": hookScriptPath]]
        ])
        hooks["PermissionRequest"] = permReq

        settings["hooks"] = hooks

        do {
            try FileManager.default.createDirectory(
                at: settingsURL.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            var opts: JSONSerialization.WritingOptions = [.prettyPrinted]
            opts.insert(.sortedKeys)
            let data = try JSONSerialization.data(withJSONObject: settings, options: opts)
            try data.write(to: settingsURL)
            hookInstalled = true
            logger.info("Permission watcher hook installed in settings.json")
        } catch {
            logger.error("Failed to install hook: \(error)")
        }
    }
}
