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
    ///
    /// The activate is not redundant with `kAXRaiseAction`: raising only
    /// reorders the window within its own app, so without also activating the
    /// owning process the window comes forward on a Space the user is not
    /// looking at and the click appears to do nothing.
    static func raise(_ window: GhosttyWindow) {
        NSRunningApplication(processIdentifier: window.pid)?.activate()
        if let ax = window.axWindow {
            AXUIElementSetAttributeValue(ax, kAXMinimizedAttribute as CFString, kCFBooleanFalse)
            AXUIElementPerformAction(ax, kAXRaiseAction as CFString)
        }
    }

    /// Raise the Ghostty window hosting one session, without prompting for
    /// anything.
    ///
    /// `hostPid` — the Ghostty process the roster saw hosting `claude attach
    /// <id>` — is authoritative and tried first: two sessions in one project
    /// share a window title, so matching on the title alone routes the click to
    /// the wrong one. `titleContains` is the fallback for rows that carry no
    /// host pid; Ghostty retitles windows from the running shell, so the launch
    /// title survives only as a case-insensitive substring.
    ///
    /// Returns false for every degraded path — Accessibility not granted, no
    /// Ghostty running, nothing matched — so the caller can fall back. This
    /// never prompts for the AX grant; the screen cover owns that UX.
    @discardableResult
    static func focusWindow(hostPid: pid_t? = nil, titleContains needle: String) -> Bool {
        guard checkAccessibility(prompt: false) else { return false }

        let windows = openWindows()
        if let hostPid, let win = windows.first(where: { $0.pid == hostPid }) {
            raise(win)
            return true
        }

        let key = needle.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !key.isEmpty else { return false }
        guard let win = windows.first(where: {
            $0.title.range(of: key, options: [.caseInsensitive]) != nil
        }) else { return false }
        raise(win)
        return true
    }

    /// Bring Ghostty forward without targeting a window — the degraded path
    /// when a session's window can't be identified but the app is running, so
    /// the click still lands the user in the terminal. Returns false when no
    /// Ghostty process exists.
    @discardableResult
    static func activateApp() -> Bool {
        for pid in ghosttyPIDs() {
            if NSRunningApplication(processIdentifier: pid)?.activate() == true { return true }
        }
        return false
    }

    // MARK: - Scripting (Ghostty's AppleScript dictionary, 1.3+)

    private static func fourCC(_ s: String) -> FourCharCode {
        s.utf8.reduce(0) { ($0 << 8) | FourCharCode($1) }
    }

    /// Open a new tab running `command` in the front window of ONE Ghostty
    /// process, through Ghostty's own `new tab` scripting command (`sdef
    /// /Applications/Ghostty.app`; needs Ghostty 1.3+ and its default
    /// `macos-applescript = true`). No keystrokes, no Accessibility grant.
    ///
    /// The event is addressed by pid, not by name. Every HUD launch is its own
    /// `open -na` Ghostty process, so `tell application "Ghostty"` (and JXA's
    /// `Application(pid)`, verified 2026-10-02 against 1.3.1) lands on
    /// whichever instance LaunchServices picks, which is the wrong project's
    /// window. That is why this builds the Apple event by hand instead of
    /// compiling AppleScript source.
    ///
    /// The surface configuration carries only `command`: the tab inherits the
    /// instance's `--title` and `--background`, and the explicit command
    /// overrides the instance's `--command`, whose launch script has already
    /// unlinked itself.
    ///
    /// Returns false on every failure (process gone, scripting disabled, an
    /// older Ghostty without the dictionary, Automation consent denied, a
    /// timeout) so the caller can fall back to a new window. The first call
    /// raises the system "ClaudeHUD wants to control Ghostty" prompt.
    @discardableResult
    static func newTab(inProcess pid: pid_t, command: String) -> Bool {
        // `front window` of the application, as an object specifier.
        let windowRecord = NSAppleEventDescriptor.record()
        windowRecord.setDescriptor(NSAppleEventDescriptor(typeCode: fourCC("prop")), forKeyword: fourCC("want"))
        windowRecord.setDescriptor(NSAppleEventDescriptor(enumCode: fourCC("prop")), forKeyword: fourCC("form"))
        windowRecord.setDescriptor(NSAppleEventDescriptor(typeCode: fourCC("GFWn")), forKeyword: fourCC("seld"))
        windowRecord.setDescriptor(NSAppleEventDescriptor.null(), forKeyword: fourCC("from"))
        guard let frontWindow = windowRecord.coerce(toDescriptorType: fourCC("obj ")) else { return false }

        // surface configuration {command: …}
        let configuration = NSAppleEventDescriptor.record()
        configuration.setDescriptor(NSAppleEventDescriptor(string: command), forKeyword: fourCC("GScC"))

        // new tab in <front window> with configuration <configuration>
        let event = NSAppleEventDescriptor(
            eventClass: fourCC("Ghst"), eventID: fourCC("NTab"),
            targetDescriptor: NSAppleEventDescriptor(processIdentifier: pid),
            returnID: AEReturnID(kAutoGenerateReturnID),
            transactionID: AETransactionID(kAnyTransactionID)
        )
        event.setParam(frontWindow, forKeyword: fourCC("GNtW"))
        event.setParam(configuration, forKeyword: fourCC("GNtS"))

        do {
            let reply = try event.sendEvent(options: [.waitForReply], timeout: 5)
            if let errn = reply.paramDescriptor(forKeyword: fourCC("errn")), errn.int32Value != 0 {
                let message = reply.paramDescriptor(forKeyword: fourCC("errs"))?.stringValue ?? ""
                ghosttyLog.info("new tab in pid=\(pid) refused: \(errn.int32Value) \(message, privacy: .public)")
                return false
            }
            // Success returns the new tab's specifier; no result means no tab.
            return reply.paramDescriptor(forKeyword: fourCC("----")) != nil
        } catch {
            ghosttyLog.info("new tab in pid=\(pid) failed: \(error.localizedDescription, privacy: .public)")
            return false
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
