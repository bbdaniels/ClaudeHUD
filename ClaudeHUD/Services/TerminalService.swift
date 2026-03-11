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
        NSWorkspace.shared.open(URL(fileURLWithPath: selectedPath))
    }

    var selectedName: String {
        TerminalService.knownTerminals.first { $0.path == selectedPath }?.name
            ?? URL(fileURLWithPath: selectedPath).deletingPathExtension().lastPathComponent
    }
}
