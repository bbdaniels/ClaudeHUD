import AppKit
import ApplicationServices
import Darwin
import os

private let ghosttyLog = Logger(subsystem: "com.claudehud", category: "GhosttyWindows")

struct GhosttyWindow: Identifiable {
    let id = UUID()
    let pid: pid_t
    let title: String
    fileprivate let axWindow: AXUIElement?   // nil when enumerated via ps fallback
}

enum GhosttyWindowService {
    /// All running Ghostty processes, including helper instances spawned via `open -n`
    /// that don't always show up in `NSWorkspace.runningApplications`.
    private static func ghosttyPIDs() -> [pid_t] {
        var pids = [pid_t](repeating: 0, count: 4096)
        let bytes = proc_listpids(
            UInt32(PROC_ALL_PIDS), 0,
            &pids,
            Int32(pids.count * MemoryLayout<pid_t>.size)
        )
        guard bytes > 0 else { return [] }
        let count = Int(bytes) / MemoryLayout<pid_t>.size

        let maxPath = 4096
        var pathBuf = [CChar](repeating: 0, count: maxPath)
        var result: [pid_t] = []
        for i in 0..<count {
            let pid = pids[i]
            guard pid > 0 else { continue }
            let r = proc_pidpath(pid, &pathBuf, UInt32(pathBuf.count))
            guard r > 0 else { continue }
            let path = String(cString: pathBuf)
            if path.hasSuffix("/Ghostty.app/Contents/MacOS/ghostty") {
                result.append(pid)
            }
        }
        return result
    }

    /// Parse the Ghostty `--title=` flag out of a process's command line via `/bin/ps`.
    /// Used as a fallback when AX fails to enumerate windows for a Ghostty PID
    /// (some `open -n` helper processes own windows at the CG level but don't
    /// expose an AX window tree).
    private static func launchTitle(for pid: pid_t) -> String? {
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/bin/ps")
        task.arguments = ["-o", "command=", "-p", String(pid)]
        let pipe = Pipe()
        task.standardOutput = pipe
        task.standardError = Pipe()
        do { try task.run() } catch { return nil }
        task.waitUntilExit()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        guard let cmd = String(data: data, encoding: .utf8) else { return nil }

        guard let range = cmd.range(of: "--title=") else { return nil }
        let tail = cmd[range.upperBound...]
        let end = tail.firstIndex(where: { $0 == " " || $0 == "\n" }) ?? tail.endIndex
        let title = String(tail[..<end]).trimmingCharacters(in: .whitespaces)
        return title.isEmpty ? nil : title
    }

    /// Enumerate open Ghostty windows across every Ghostty process.
    /// Primary path: AX (lets us raise a specific window).
    /// Fallback: parse the Ghostty launch title from `ps` when AX returns no windows,
    /// so the menu still lists the session even though we can only activate the whole app.
    static func openWindows() -> [GhosttyWindow] {
        var result: [GhosttyWindow] = []
        let pids = ghosttyPIDs()
        ghosttyLog.info("Enumerating Ghostty windows across \(pids.count) processes: \(pids.map { String($0) }.joined(separator: ","), privacy: .public)")
        for pid in pids {
            let appEl = AXUIElementCreateApplication(pid)
            var windowsRef: CFTypeRef?
            let err = AXUIElementCopyAttributeValue(appEl, kAXWindowsAttribute as CFString, &windowsRef)
            let axWindows = (err == .success ? (windowsRef as? [AXUIElement]) : nil) ?? []
            if err != .success {
                ghosttyLog.info("pid=\(pid) AX err=\(err.rawValue, privacy: .public)")
            } else {
                ghosttyLog.info("pid=\(pid) has \(axWindows.count) AX window(s)")
            }

            if axWindows.isEmpty {
                if let title = launchTitle(for: pid) {
                    ghosttyLog.info("pid=\(pid) fallback title from ps: \(title, privacy: .public)")
                    result.append(GhosttyWindow(pid: pid, title: title, axWindow: nil))
                }
                continue
            }

            for (i, axWindow) in axWindows.enumerated() {
                var roleRef: CFTypeRef?
                AXUIElementCopyAttributeValue(axWindow, kAXRoleAttribute as CFString, &roleRef)
                let role = (roleRef as? String) ?? ""
                guard role == kAXWindowRole as String else { continue }

                var subroleRef: CFTypeRef?
                AXUIElementCopyAttributeValue(axWindow, kAXSubroleAttribute as CFString, &subroleRef)
                let subrole = (subroleRef as? String) ?? ""
                if subrole == kAXDialogSubrole as String || subrole == kAXSystemDialogSubrole as String { continue }

                var titleRef: CFTypeRef?
                AXUIElementCopyAttributeValue(axWindow, kAXTitleAttribute as CFString, &titleRef)
                let rawTitle = (titleRef as? String) ?? ""
                // Ghostty retitles windows based on the running shell, so a finished
                // Claude session may no longer carry its launch title. Keep those
                // windows instead of dropping them.
                let title = rawTitle.isEmpty ? "Window \(i + 1) (pid \(pid))" : rawTitle

                result.append(GhosttyWindow(pid: pid, title: title, axWindow: axWindow))
            }
        }
        return result
    }

    /// Activate Ghostty and raise the specific window to the front.
    /// When the window was enumerated via the ps fallback we only have a PID,
    /// so we can only activate that whole Ghostty process.
    static func raise(_ window: GhosttyWindow) {
        NSRunningApplication(processIdentifier: window.pid)?.activate()
        if let ax = window.axWindow {
            AXUIElementSetAttributeValue(ax, kAXMinimizedAttribute as CFString, kCFBooleanFalse)
            AXUIElementPerformAction(ax, kAXRaiseAction as CFString)
        }
    }

    /// Returns true if Accessibility permission is granted for this process.
    /// `prompt: true` shows the system dialog if not yet granted.
    @discardableResult
    static func checkAccessibility(prompt: Bool = false) -> Bool {
        let key = kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String
        let options = [key: prompt] as CFDictionary
        return AXIsProcessTrustedWithOptions(options)
    }
}
