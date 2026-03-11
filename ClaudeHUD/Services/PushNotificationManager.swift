import Foundation
import os

private let logger = Logger(subsystem: "com.claudehud", category: "PushNotifications")

// MARK: - Push Notification Manager

@MainActor
class PushNotificationManager: ObservableObject {
    @Published private(set) var isEnabled: Bool
    @Published private(set) var desktopEnabled: Bool
    @Published private(set) var mobileEnabled: Bool
    @Published private(set) var ntfyTopic: String
    @Published private(set) var scriptInstalled: Bool = false

    init() {
        isEnabled = UserDefaults.standard.bool(forKey: "push.enabled")
        desktopEnabled = UserDefaults.standard.object(forKey: "push.desktop") as? Bool ?? true
        mobileEnabled = UserDefaults.standard.bool(forKey: "push.mobile")
        ntfyTopic = UserDefaults.standard.string(forKey: "push.topic") ?? ""
        checkScriptInstalled()
    }

    // MARK: - Public Setters

    func setEnabled(_ val: Bool) async {
        if val && !scriptInstalled {
            await installScript()
        }
        isEnabled = val
        UserDefaults.standard.set(val, forKey: "push.enabled")
        await syncHooks()
    }

    func setDesktopEnabled(_ val: Bool) async {
        desktopEnabled = val
        UserDefaults.standard.set(val, forKey: "push.desktop")
        await syncHooks()
    }

    func setMobileEnabled(_ val: Bool) async {
        mobileEnabled = val
        UserDefaults.standard.set(val, forKey: "push.mobile")
        await syncHooks()
    }

    func setNtfyTopic(_ val: String) async {
        ntfyTopic = val
        UserDefaults.standard.set(val, forKey: "push.topic")
        await syncHooks()
    }

    // MARK: - Test

    func sendTestNotification() {
        let script = "display notification \"ClaudeHUD notifications are working!\" with title \"Claude (test)\""
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        proc.arguments = ["-e", script]
        try? proc.run()
    }

    // MARK: - Script Installation

    var hookScriptURL: URL {
        URL(fileURLWithPath: NSHomeDirectory())
            .appendingPathComponent(".claude/hooks/ntfy-notify.sh")
    }

    func checkScriptInstalled() {
        scriptInstalled = FileManager.default.fileExists(atPath: hookScriptURL.path)
    }

    func installScript() async {
        let dest = hookScriptURL
        let hooksDir = dest.deletingLastPathComponent()

        do {
            try FileManager.default.createDirectory(at: hooksDir, withIntermediateDirectories: true)

            guard let bundleURL = Bundle.main.url(forResource: "ntfy-notify", withExtension: "sh") else {
                logger.error("ntfy-notify.sh not found in app bundle")
                return
            }

            if FileManager.default.fileExists(atPath: dest.path) {
                try FileManager.default.removeItem(at: dest)
            }
            try FileManager.default.copyItem(at: bundleURL, to: dest)
            try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: dest.path)

            scriptInstalled = true
            logger.info("ntfy-notify.sh installed to ~/.claude/hooks/")
        } catch {
            logger.error("Failed to install script: \(error)")
        }
    }

    // MARK: - Hook Sync

    private func syncHooks() async {
        let shouldActivate = isEnabled && (desktopEnabled || (mobileEnabled && !ntfyTopic.isEmpty))
        if shouldActivate {
            if !scriptInstalled { await installScript() }
            installHooks()
        } else {
            uninstallHooks()
        }
    }

    private func makeCommand(_ hookType: String) -> String {
        var envVars = ""
        if mobileEnabled && !ntfyTopic.isEmpty {
            envVars += "NTFY_TOPIC=\(ntfyTopic) "
        }
        if desktopEnabled {
            envVars += "NTFY_DESKTOP=1 "
        }
        return "\(envVars)~/.claude/hooks/ntfy-notify.sh \(hookType)"
    }

    private func installHooks() {
        var settings = loadSettings()
        var hooks = settings["hooks"] as? [String: Any] ?? [:]

        var preToolUse = hooks["PreToolUse"] as? [[String: Any]] ?? []
        removeOurHooks(from: &preToolUse)
        preToolUse.append([
            "matcher": "AskUserQuestion",
            "hooks": [["type": "command", "command": makeCommand("ask")]]
        ])
        hooks["PreToolUse"] = preToolUse

        var permReq = hooks["PermissionRequest"] as? [[String: Any]] ?? []
        removeOurHooks(from: &permReq)
        permReq.append([
            "hooks": [["type": "command", "command": makeCommand("permission")]]
        ])
        hooks["PermissionRequest"] = permReq

        settings["hooks"] = hooks
        saveSettings(settings)
        logger.info("Push hooks installed in ~/.claude/settings.json")
    }

    private func uninstallHooks() {
        var settings = loadSettings()
        guard var hooks = settings["hooks"] as? [String: Any] else { return }

        if var preToolUse = hooks["PreToolUse"] as? [[String: Any]] {
            removeOurHooks(from: &preToolUse)
            hooks["PreToolUse"] = preToolUse.isEmpty ? nil : preToolUse
        }
        if var permReq = hooks["PermissionRequest"] as? [[String: Any]] {
            removeOurHooks(from: &permReq)
            hooks["PermissionRequest"] = permReq.isEmpty ? nil : permReq
        }

        settings["hooks"] = hooks
        saveSettings(settings)
        logger.info("Push hooks removed from ~/.claude/settings.json")
    }

    private func removeOurHooks(from entries: inout [[String: Any]]) {
        entries.removeAll { entry in
            guard let innerHooks = entry["hooks"] as? [[String: Any]] else { return false }
            return innerHooks.contains { hook in
                (hook["command"] as? String)?.contains("ntfy-notify.sh") == true
            }
        }
    }

    // MARK: - Settings JSON

    private var claudeSettingsURL: URL {
        URL(fileURLWithPath: NSHomeDirectory())
            .appendingPathComponent(".claude/settings.json")
    }

    private func loadSettings() -> [String: Any] {
        guard let data = try? Data(contentsOf: claudeSettingsURL),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return [:]
        }
        return json
    }

    private func saveSettings(_ settings: [String: Any]) {
        let url = claudeSettingsURL
        do {
            try FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            var opts: JSONSerialization.WritingOptions = [.prettyPrinted]
            if #available(macOS 10.13, *) { opts.insert(.sortedKeys) }
            let data = try JSONSerialization.data(withJSONObject: settings, options: opts)
            try data.write(to: url)
        } catch {
            logger.error("Failed to save settings.json: \(error)")
        }
    }
}
