import AppKit
import CryptoKit
import Foundation

// MARK: - Terminal Service

@MainActor
class TerminalService: ObservableObject {
    @Published private(set) var selectedPath: String

    static let knownTerminals: [(name: String, path: String)] = [
        ("Ghostty",  "/Applications/Ghostty.app"),
        ("iTerm2",   "/Applications/iTerm.app"),
        ("Warp",     "/Applications/Warp.app"),
        ("Alacritty","/Applications/Alacritty.app"),
        ("kitty",    "/Applications/kitty.app"),
        ("Hyper",    "/Applications/Hyper.app"),
        ("Terminal", "/System/Applications/Utilities/Terminal.app"),
    ]

    static let knownLaunchers: [(name: String, path: String)] = [
        ("Ghostty",  "/Applications/Ghostty.app"),
        ("VS Code",  "/Applications/Visual Studio Code.app"),
    ]

    var installedTerminals: [(name: String, path: String)] {
        TerminalService.knownTerminals.filter {
            FileManager.default.fileExists(atPath: $0.path)
        }
    }

    var installedLaunchers: [(name: String, path: String)] {
        TerminalService.knownLaunchers.filter {
            FileManager.default.fileExists(atPath: $0.path)
        }
    }

    static func nameForPath(_ path: String) -> String {
        let all = knownTerminals + knownLaunchers
        return all.first { $0.path == path }?.name
            ?? URL(fileURLWithPath: path).deletingPathExtension().lastPathComponent
    }

    init() {
        let saved = UserDefaults.standard.string(forKey: "terminal.selectedPath") ?? ""
        // If saved path no longer exists, fall back to first installed
        if !saved.isEmpty && FileManager.default.fileExists(atPath: saved) {
            selectedPath = saved
        } else {
            selectedPath = TerminalService.knownTerminals
                .first { FileManager.default.fileExists(atPath: $0.path) }?.path ?? ""
            UserDefaults.standard.set(selectedPath, forKey: "terminal.selectedPath")
        }
    }

    func select(_ path: String) {
        selectedPath = path
        UserDefaults.standard.set(path, forKey: "terminal.selectedPath")
    }

    func launch() {
        guard !selectedPath.isEmpty else { return }
        let url = URL(fileURLWithPath: selectedPath)
        let config = NSWorkspace.OpenConfiguration()
        config.activates = true
        NSWorkspace.shared.openApplication(at: url, configuration: config) { _, _ in }
    }

    var selectedName: String {
        TerminalService.knownTerminals.first { $0.path == selectedPath }?.name
            ?? URL(fileURLWithPath: selectedPath).deletingPathExtension().lastPathComponent
    }

    /// Launch an app with a command.
    /// When `usingApp` is provided, that app is used instead of the global selection.
    /// Returns `true` if auto-executed, `false` if copied to clipboard.
    @discardableResult
    func launchWithCommand(_ command: String, inDirectory: String? = nil, usingApp overridePath: String? = nil, backgroundColor: String? = nil) -> Bool {
        let appPath = overridePath ?? selectedPath
        guard !appPath.isEmpty else { return false }

        var fullCommand = command
        if let dir = inDirectory {
            let quoted = dir.replacingOccurrences(of: "'", with: "'\\''")
            fullCommand = "cd '\(quoted)' && \(command)"
        }

        let name = Self.nameForPath(appPath)

        // Terminal.app: AppleScript `do script` (auto-executes in new window)
        if name == "Terminal" {
            let escaped = appleScriptEscape(fullCommand)
            runAppleScript("""
                tell application "Terminal"
                    do script "\(escaped)"
                    activate
                end tell
                """)
            return true
        }

        // iTerm2: AppleScript (auto-executes in new window)
        if name == "iTerm2" {
            let escaped = appleScriptEscape(fullCommand)
            runAppleScript("""
                tell application "iTerm2"
                    create window with default profile command "\(escaped)"
                    activate
                end tell
                """)
            return true
        }

        // Ghostty: split right, paste, execute via osascript subprocess.
        // Using Process instead of NSAppleScript for reliable execution.
        // Command is also on clipboard as fallback if Accessibility isn't granted.
        if name == "Ghostty" {
            // Write a temp script that cd's, runs the command, then drops into zsh.
            let scriptId = UUID().uuidString.prefix(8)
            let tmpScript = "/tmp/claude-resume-\(scriptId).sh"
            let scriptContent = "#!/bin/zsh\nsource ~/.zshrc 2>/dev/null\nunset CLAUDECODE\n\(fullCommand)\nrm -f \"$0\"\nexec zsh\n"

            guard (try? scriptContent.write(toFile: tmpScript, atomically: true, encoding: .utf8)) != nil,
                  (try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: tmpScript)) != nil
            else {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(fullCommand, forType: .string)
                launchApp(at: appPath)
                return false
            }

            // Use `open -na` as recommended by Ghostty docs for macOS.
            // Opens a new Ghostty window running the resume command.
            // --quit-after-last-window-closed ensures the instance exits (and its
            // dock icon disappears) once the user closes the window.
            // --title sets the window title to the project name for easy identification.
            let projectName = inDirectory.flatMap { URL(fileURLWithPath: $0).lastPathComponent } ?? "Claude Code"
            var ghosttyArgs = ["-na", appPath, "--args",
                               "--quit-after-last-window-closed",
                               "--title=\(projectName)"]
            if let bg = backgroundColor {
                ghosttyArgs.append("--background=\(bg)")
            }
            ghosttyArgs.append("--command=\(tmpScript)")
            let open = Process()
            open.executableURL = URL(fileURLWithPath: "/usr/bin/open")
            open.arguments = ghosttyArgs
            try? open.run()
            return true
        }

        // VS Code: open the project folder, copy command to clipboard for integrated terminal.
        if name == "VS Code" {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(fullCommand, forType: .string)
            if let dir = inDirectory {
                let open = Process()
                open.executableURL = URL(fileURLWithPath: "/usr/bin/open")
                open.arguments = ["-a", appPath, dir]
                try? open.run()
            } else {
                launchApp(at: appPath)
            }
            return false
        }

        // Others: copy command to clipboard, bring terminal to front.
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(fullCommand, forType: .string)
        launchApp(at: appPath)
        return false
    }

    private func launchApp(at path: String) {
        let url = URL(fileURLWithPath: path)
        let config = NSWorkspace.OpenConfiguration()
        config.activates = true
        NSWorkspace.shared.openApplication(at: url, configuration: config) { _, _ in }
    }

    private func appleScriptEscape(_ s: String) -> String {
        s.replacingOccurrences(of: "\\", with: "\\\\")
         .replacingOccurrences(of: "\"", with: "\\\"")
    }

    private func runAppleScript(_ source: String) {
        let script = NSAppleScript(source: source)
        var error: NSDictionary?
        script?.executeAndReturnError(&error)
    }

    /// Derive a stable, distinct background color from a project name.
    /// Uses golden-ratio hue spacing seeded by SHA-256 for maximum spread.
    static func projectNSColor(for name: String) -> NSColor {
        let digest = SHA256.hash(data: Data(name.utf8))
        let bytes = Array(digest)

        let seed = Double(UInt32(bytes[0]) << 24 | UInt32(bytes[1]) << 16
                        | UInt32(bytes[2]) << 8  | UInt32(bytes[3]))
        let golden = 0.618033988749895
        let hue = (seed * golden).truncatingRemainder(dividingBy: 1.0)

        let saturation = 0.55 + (Double(bytes[4]) / 255.0) * 0.35   // 0.55–0.90
        let lightness  = 0.20 + (Double(bytes[5]) / 255.0) * 0.06   // 0.20–0.26

        return NSColor(hue: hue, saturation: saturation, brightness: lightness * 2, alpha: 1.0)
    }

    static func projectColor(for name: String) -> String {
        let color = projectNSColor(for: name)
        let r = Int(color.redComponent * 255)
        let g = Int(color.greenComponent * 255)
        let b = Int(color.blueComponent * 255)
        return String(format: "%02x%02x%02x", r, g, b)
    }
}
