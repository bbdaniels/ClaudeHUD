import Foundation
import os

private let logger = Logger(subsystem: "com.claudehud", category: "RemoteControlServer")

/// Owns the persistent `claude remote-control` server that lets claude.ai/code
/// and the Claude app start new sessions on this Mac (the counterpart of the
/// Pi's `claude-rc.service`).
///
/// launchd runs the server, not the HUD: a user agent with `KeepAlive`, so it
/// survives the HUD quitting and restarts itself if it dies. The HUD writes,
/// loads, unloads and observes it. Enabled means the plist exists in
/// `~/Library/LaunchAgents`, so the state after a reboot is the state the
/// toggle shows: launchd loads the plist at login, and disabling deletes it.
///
/// The server's `--permission-mode` follows the header's global permission
/// picker (`LaunchPermissionMode`); when the picker changes, the plist is
/// rewritten and the agent reloaded so the server matches.
@MainActor
final class RemoteControlServerService: ObservableObject {
    /// True when the plist is installed (launchd loads it at login).
    @Published private(set) var isEnabled = false
    /// The server's pid while launchd reports it running.
    @Published private(set) var pid: Int?
    /// A load, unload or reload is in flight.
    @Published private(set) var isBusy = false

    nonisolated static let label = "com.bbdaniels.claude-remote-control"
    nonisolated static let serverName = "Mac"
    nonisolated static let capacity = 4
    /// Matches the Pi's RestartSec: a crash-looping server retries every 30 s.
    nonisolated static let throttleInterval = 30

    nonisolated static var plistURL: URL {
        URL(fileURLWithPath: NSHomeDirectory())
            .appendingPathComponent("Library/LaunchAgents/\(label).plist")
    }
    nonisolated static var logPath: String {
        "\(NSHomeDirectory())/Library/Logs/claude-remote-control.log"
    }
    nonisolated private static var serviceTarget: String { "gui/\(getuid())/\(label)" }
    nonisolated private static var domainTarget: String { "gui/\(getuid())" }

    private var timer: Timer?
    private var defaultsObserver: NSObjectProtocol?
    private static let pollInterval: TimeInterval = 15

    deinit {
        timer?.invalidate()
        if let defaultsObserver { NotificationCenter.default.removeObserver(defaultsObserver) }
    }

    func start() {
        // The picker writes through @AppStorage, which posts this on every
        // UserDefaults write; `syncWithPermissionMode` is a no-op unless the
        // installed plist no longer matches the definition.
        defaultsObserver = NotificationCenter.default.addObserver(
            forName: UserDefaults.didChangeNotification, object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.syncWithPermissionMode() }
        }
        timer = Timer.scheduledTimer(withTimeInterval: Self.pollInterval, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.refresh() }
        }
        // Also catches a plist written by an older HUD build.
        syncWithPermissionMode()
        refresh()
    }

    // MARK: - Definition

    /// The launchd job, generated from the current global permission mode.
    nonisolated static func plist(mode: LaunchPermissionMode = .current) -> [String: Any] {
        let home = NSHomeDirectory()
        var args = ["\(home)/.local/bin/claude", "remote-control",
                    "--name", serverName, "--capacity", String(capacity)]
        args += mode.remoteControlArguments
        return [
            "Label": label,
            "ProgramArguments": args,
            "WorkingDirectory": "\(home)/Projects",
            "RunAtLoad": true,
            "KeepAlive": true,
            "ThrottleInterval": throttleInterval,
            "EnvironmentVariables": [
                "PATH": "\(home)/.local/bin:/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin",
            ],
            "StandardOutPath": logPath,
            "StandardErrorPath": logPath,
        ]
    }

    nonisolated private static func writePlist() throws {
        let data = try PropertyListSerialization.data(
            fromPropertyList: plist(), format: .xml, options: 0)
        try FileManager.default.createDirectory(
            at: plistURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: plistURL, options: .atomic)
    }

    nonisolated private static func installedPlistIsCurrent() -> Bool {
        guard let installed = NSDictionary(contentsOf: plistURL) else { return false }
        return installed.isEqual(to: plist())
    }

    // MARK: - Actions

    func setEnabled(_ enabled: Bool) {
        guard !isBusy else { return }
        isBusy = true
        Task {
            let result: String? = await Task.detached {
                enabled ? Self.load() : Self.unload()
            }.value
            if let result { logger.error("\(result, privacy: .public)") }
            isBusy = false
            refresh()
            // A picker change that arrived mid-reload was skipped; catch it.
            syncWithPermissionMode()
        }
    }

    /// Rewrite and reload when the installed plist differs from the one the
    /// current permission mode generates. Never enables a disabled server.
    func syncWithPermissionMode() {
        guard !isBusy,
              FileManager.default.fileExists(atPath: Self.plistURL.path),
              !Self.installedPlistIsCurrent() else { return }
        logger.info("Permission mode changed; reloading the Remote Control server")
        setEnabled(true)
    }

    func refresh() {
        Task {
            let (enabled, pid) = await Task.detached { Self.query() }.value
            isEnabled = enabled
            self.pid = pid
        }
    }

    /// `ClaudeHUD --remote-control on|off|status`. Returns the exit status.
    nonisolated static func commandLine(_ verb: String) -> Int32 {
        var error: String?
        switch verb {
        case "on": error = load()
        case "off": error = unload()
        case "status": break
        default: error = "Usage: ClaudeHUD --remote-control on|off|status"
        }
        if let error { FileHandle.standardError.write(Data((error + "\n").utf8)) }
        let (enabled, pid) = query()
        let state = pid.map { "running (pid \($0))" } ?? (enabled ? "enabled, not running" : "off")
        print("Remote Control: \(state)")
        return error == nil ? 0 : 1
    }

    // MARK: - launchctl (off the main thread)

    /// Write the plist and (re)bootstrap it. launchd caches a job's
    /// definition at bootstrap, so a changed plist needs a bootout first;
    /// bootstrap fails while the old job is still tearing down, so wait for
    /// it to leave the domain. Returns an error message, or nil.
    nonisolated private static func load() -> String? {
        do { try writePlist() } catch { return "Writing \(plistURL.path) failed: \(error)" }
        if isLoaded() {
            _ = launchctl(["bootout", serviceTarget])
            var waited = 0
            while isLoaded() && waited < 40 { usleep(250_000); waited += 1 }
        }
        let (status, output) = launchctl(["bootstrap", domainTarget, plistURL.path])
        return status == 0 ? nil : "launchctl bootstrap failed (\(status)): \(output)"
    }

    /// Bootout, then delete the plist so the server stays off after login.
    nonisolated private static func unload() -> String? {
        if isLoaded() { _ = launchctl(["bootout", serviceTarget]) }
        do {
            if FileManager.default.fileExists(atPath: plistURL.path) {
                try FileManager.default.removeItem(at: plistURL)
            }
        } catch { return "Removing \(plistURL.path) failed: \(error)" }
        return nil
    }

    nonisolated private static func isLoaded() -> Bool {
        launchctl(["print", serviceTarget]).status == 0
    }

    /// (plist installed, pid when launchd reports the job running).
    nonisolated private static func query() -> (Bool, Int?) {
        let enabled = FileManager.default.fileExists(atPath: plistURL.path)
        let (status, output) = launchctl(["print", serviceTarget])
        guard status == 0, output.contains("state = running") else { return (enabled, nil) }
        let pid = output.split(separator: "\n")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .first { $0.hasPrefix("pid = ") }
            .flatMap { Int($0.dropFirst("pid = ".count)) }
        return (enabled, pid)
    }

    nonisolated private static func launchctl(_ args: [String]) -> (status: Int32, output: String) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/launchctl")
        process.arguments = args
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        do { try process.run() } catch { return (-1, "\(error)") }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return (process.terminationStatus, String(decoding: data, as: UTF8.self))
    }
}
