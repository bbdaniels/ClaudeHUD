import AppKit
import os

private let stackLog = Logger(subsystem: "com.claudehud", category: "GhosttyStack")

/// Hides the Ghostty instances buried under the one that comes to the front
/// (rule and measurement: `GhosttyStack`). A hidden instance comes back by
/// itself when it is activated, by Cmd-Tab, the Dock or a HUD badge click
/// (`GhosttyWindowService.raise` also unhides it), and the HUD's open-session
/// dot still shows it is running. Nothing is closed and no session is touched.
///
/// Off with `defaults write com.claudehud.app hideCoveredGhostty -bool false`.
@MainActor
final class GhosttyStackManager {
    static let defaultsKey = "hideCoveredGhostty"
    nonisolated private static let ghosttyBundleID = "com.mitchellh.ghostty"

    private var observer: NSObjectProtocol?
    private var pending: DispatchWorkItem?

    func start() {
        UserDefaults.standard.register(defaults: [Self.defaultsKey: true])
        observer = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main
        ) { [weak self] note in
            guard let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication,
                  app.bundleIdentifier == Self.ghosttyBundleID else { return }
            let pid = app.processIdentifier
            MainActor.assumeIsolated { self?.schedule(front: pid) }
        }
    }

    deinit {
        if let observer { NSWorkspace.shared.notificationCenter.removeObserver(observer) }
    }

    /// Waits a beat so the window list reflects the new front window (an
    /// activation can arrive before the raise lands), then hides what it covers.
    private func schedule(front pid: pid_t) {
        pending?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.hideCovered(by: pid) }
        pending = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4, execute: work)
    }

    private func hideCovered(by frontPid: pid_t) {
        guard UserDefaults.standard.bool(forKey: Self.defaultsKey),
              NSWorkspace.shared.frontmostApplication?.processIdentifier == frontPid else { return }
        // By pid, not `runningApplications`, which can miss `open -n` instances.
        let ghostty = GhosttyWindowService.ghosttyPIDs()
            .compactMap { NSRunningApplication(processIdentifier: $0) }
            .filter { !$0.isHidden }
        let pids = Set(ghostty.map(\.processIdentifier))
        let windows = Self.onScreenWindows(of: pids)
        let front = windows[frontPid] ?? []
        var others = windows
        others[frontPid] = nil
        for pid in GhosttyStack.coveredPids(front: front, others: others) {
            guard let app = ghostty.first(where: { $0.processIdentifier == pid }) else { continue }
            stackLog.info("hiding Ghostty pid=\(pid), covered by pid=\(frontPid)")
            app.hide()
        }
    }

    /// Ordinary (layer 0) on-screen windows of the given processes, in global
    /// screen coordinates. Needs no Accessibility or Screen Recording grant:
    /// owner pid and bounds are always readable.
    private static func onScreenWindows(of pids: Set<pid_t>) -> [pid_t: [CGRect]] {
        guard let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements],
                                                    kCGNullWindowID) as? [[String: Any]] else { return [:] }
        var result: [pid_t: [CGRect]] = [:]
        for info in list {
            guard let pid = info[kCGWindowOwnerPID as String] as? pid_t, pids.contains(pid),
                  (info[kCGWindowLayer as String] as? Int) == 0,
                  let boundsDict = info[kCGWindowBounds as String] as? NSDictionary,
                  let bounds = CGRect(dictionaryRepresentation: boundsDict as CFDictionary),
                  bounds.width > 50, bounds.height > 50 else { continue }
            result[pid, default: []].append(bounds)
        }
        return result
    }
}
