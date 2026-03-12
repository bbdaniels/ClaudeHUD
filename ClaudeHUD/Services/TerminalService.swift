import AppKit
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

    var installedTerminals: [(name: String, path: String)] {
        TerminalService.knownTerminals.filter {
            FileManager.default.fileExists(atPath: $0.path)
        }
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

    /// Launch the selected terminal with a command.
    /// Returns `true` if auto-executed (Terminal.app/iTerm2), `false` if copied to clipboard.
    @discardableResult
    func launchWithCommand(_ command: String, inDirectory: String? = nil) -> Bool {
        var fullCommand = command
        if let dir = inDirectory {
            let quoted = dir.replacingOccurrences(of: "'", with: "'\\''")
            fullCommand = "cd '\(quoted)' && \(command)"
        }

        let name = selectedName

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
            let scriptContent = "#!/bin/zsh\nunset CLAUDECODE\n\(fullCommand)\nrm -f \"$0\"\nexec zsh\n"

            guard (try? scriptContent.write(toFile: tmpScript, atomically: true, encoding: .utf8)) != nil,
                  (try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: tmpScript)) != nil
            else {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(fullCommand, forType: .string)
                launch()
                return false
            }

            // Use `open -na` as recommended by Ghostty docs for macOS.
            // Opens a new Ghostty window running the resume command.
            let open = Process()
            open.executableURL = URL(fileURLWithPath: "/usr/bin/open")
            open.arguments = ["-na", selectedPath, "--args", "--command=\(tmpScript)"]
            try? open.run()
            return true
        }

        // Others: copy command to clipboard, bring terminal to front.
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(fullCommand, forType: .string)
        launch()
        return false
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
}
