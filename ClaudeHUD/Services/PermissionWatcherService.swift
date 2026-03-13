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

        // Remove stale entries that no longer have pending files
        let activeIds = Set(jsonFiles.map { String($0.dropLast(5)) }) // remove .json
        pending.removeAll { !activeIds.contains($0.id) }

        // Add new entries
        let existingIds = Set(pending.map(\.id))
        for file in jsonFiles {
            let id = String(file.dropLast(5))
            guard !existingIds.contains(id) else { continue }

            let path = "\(pendingDir)/\(file)"
            guard let data = fm.contents(atPath: path),
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
            else { continue }

            let toolName = json["tool_name"] as? String ?? "Unknown"
            let toolInput = json["tool_input"] as? [String: Any] ?? [:]
            let project = json["project"] as? String ?? "Unknown"
            let projectPath = json["project_path"] as? String ?? ""
            let ts = json["timestamp"] as? TimeInterval ?? Date().timeIntervalSince1970

            let summary = Self.summarize(tool: toolName, input: toolInput)

            pending.append(PendingPermission(
                id: id,
                toolName: toolName,
                summary: summary,
                project: project,
                projectPath: projectPath,
                timestamp: Date(timeIntervalSince1970: ts)
            ))
        }

        // Sort newest first
        pending.sort { $0.timestamp > $1.timestamp }
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
