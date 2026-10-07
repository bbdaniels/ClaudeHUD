import SwiftUI
import Cocoa
import GhosttyKit

@main
struct ClaudeHUDApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate

    /// Command-line mode for vault-ingest.sh: `ClaudeHUD --transcript-text
    /// <path> [maxChars]` prints the transcript's conversation text (the
    /// same extraction the search index uses) and exits before any UI starts.
    init() {
        let args = CommandLine.arguments
        // `ClaudeHUD --process-report`: print the menu's Background Jobs /
        // Orphans sections and the classification of every Claude worker,
        // then exit. Read-only; safe while the menu-bar app is running.
        if args.contains("--process-report") {
            FileHandle.standardOutput.write(Data(ProcessMenuText.dump(ClaudeProcessSnapshot.capture()).utf8))
            exit(0)
        }
        if let i = args.firstIndex(of: "--transcript-text"), i + 1 < args.count {
            let maxChars = i + 2 < args.count ? Int(args[i + 2]) ?? 240_000 : 240_000
            guard let text = TranscriptText.conversation(atPath: args[i + 1], maxChars: maxChars) else {
                FileHandle.standardError.write(Data("cannot read \(args[i + 1])\n".utf8))
                exit(1)
            }
            FileHandle.standardOutput.write(Data(text.utf8))
            exit(0)
        }
    }

    var body: some Scene {
        // No visible scenes — panel is managed by AppDelegate
        Settings {
            EmptyView()
        }
    }
}

// MARK: - App Delegate

@MainActor
class AppDelegate: NSObject, NSApplicationDelegate {
    let appState = AppState()
    private var panelController: HUDPanelController?
    private var statusItem: NSStatusItem?

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)

        // libghostty requires global init before any ghostty_* API is called.
        // Must run before WorkspaceWindowController touches Ghostty.App.
        if ghostty_init(UInt(CommandLine.argc), CommandLine.unsafeArgv) != GHOSTTY_SUCCESS {
            NSLog("ClaudeHUD: ghostty_init failed — workspace terminal disabled")
        }

        panelController = HUDPanelController(appState: appState)
        setupStatusItem()
        appState.processMonitor.onUpdate = { [weak self] report in
            self?.updateOrphanBadge(report.orphans.count)
        }

        appState.hotkeyService.register { [weak self] in
            self?.panelController?.toggle()
        }

        Task {
            await appState.setup()
        }
    }

    private func setupStatusItem() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)

        if let button = statusItem?.button {
            let icon = NSImage(named: "MenuBarIcon")
            icon?.isTemplate = true
            button.image = icon
            button.action = #selector(statusItemClicked(_:))
            button.target = self
            button.sendAction(on: [.leftMouseUp, .rightMouseUp])
        }
    }

    @objc private func statusItemClicked(_ sender: NSStatusBarButton) {
        // `NSApp.currentEvent` is nil when the item is activated without a real
        // mouse event — e.g. an accessibility/synthetic click (VoiceOver, UI
        // automation) or programmatic `performClick`. Force-unwrapping it
        // trapped in those cases; treat a missing event (and any non-right-
        // click) as a normal left-click that toggles the panel.
        if NSApp.currentEvent?.type == .rightMouseUp {
            showContextMenu(sender)
        } else {
            panelController?.toggle()
        }
    }

    private var ghosttyWindowsForMenu: [GhosttyWindow] = []
    private var backgroundJobsForMenu: [ClassifiedWorker] = []
    private var orphansForMenu: [ClassifiedWorker] = []

    /// Orphan count beside the menu-bar icon; plain icon when there are none.
    private func updateOrphanBadge(_ n: Int) {
        guard let item = statusItem, let button = item.button else { return }
        if n > 0 {
            item.length = NSStatusItem.variableLength
            button.imagePosition = .imageLeading
            button.title = "\(n)"
            button.toolTip = "\(n) orphaned Claude process\(n == 1 ? "" : "es"): right-click to review"
        } else {
            button.title = ""
            button.imagePosition = .imageOnly
            item.length = NSStatusItem.squareLength
            button.toolTip = nil
        }
    }

    private func showContextMenu(_ sender: NSStatusBarButton) {
        let menu = NSMenu()

        menu.addItem(withTitle: "New Claude Session", action: #selector(newClaudeSession), keyEquivalent: "n")
            .target = self

        // Open Ghostty sessions — enumerated fresh each click
        let windows = GhosttyWindowService.openWindows()
            .sorted { $0.title.localizedCaseInsensitiveCompare($1.title) == .orderedAscending }
        ghosttyWindowsForMenu = windows

        if !windows.isEmpty {
            menu.addItem(.separator())
            let header = NSMenuItem(title: "Open Sessions", action: nil, keyEquivalent: "")
            header.isEnabled = false
            menu.addItem(header)

            for (i, window) in windows.enumerated() {
                let item = NSMenuItem(
                    title: window.title,
                    action: #selector(focusGhosttyWindow(_:)),
                    keyEquivalent: ""
                )
                item.target = self
                item.tag = i
                menu.addItem(item)
            }
        } else if !GhosttyWindowService.checkAccessibility(prompt: false) {
            menu.addItem(.separator())
            let hint = NSMenuItem(
                title: "Grant Accessibility to list sessions…",
                action: #selector(promptAccessibility),
                keyEquivalent: ""
            )
            hint.target = self
            menu.addItem(hint)
        }

        addProcessSections(to: menu)

        menu.addItem(.separator())

        menu.addItem(
            withTitle: appState.screenCoverService.isCovered ? "Uncover Screen" : "Cover Screen",
            action: #selector(toggleScreenCover),
            keyEquivalent: "c"
        ).target = self

        menu.addItem(.separator())

        let footer = NSMenuItem(title: processFooter, action: nil, keyEquivalent: "")
        footer.isEnabled = false
        menu.addItem(footer)

        menu.addItem(withTitle: "Quit ClaudeHUD", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")

        statusItem?.menu = menu
        statusItem?.button?.performClick(nil)
        statusItem?.menu = nil
    }

    @objc private func newClaudeSession() {
        appState.terminalService.launchClaudeAtHome()
    }

    @objc private func focusGhosttyWindow(_ sender: NSMenuItem) {
        guard ghosttyWindowsForMenu.indices.contains(sender.tag) else { return }
        GhosttyWindowService.raise(ghosttyWindowsForMenu[sender.tag])
    }

    // MARK: - Background jobs and orphans

    private var processFooter = ""

    /// Background jobs (daemon sessions nobody is attached to) and orphans,
    /// from a fresh scan. The warm spare and attached sessions are counted in
    /// the footer only.
    private func addProcessSections(to menu: NSMenu) {
        let report = appState.processMonitor.refreshNow()
        backgroundJobsForMenu = report.backgroundJobs
        orphansForMenu = report.orphans
        let now = Date()

        if !report.backgroundJobs.isEmpty || !report.recentlyEnded.isEmpty {
            menu.addItem(.separator())
            menu.addItem(Self.header("Background Jobs"))
            for (i, w) in report.backgroundJobs.enumerated() {
                let l = ProcessMenuText.backgroundJob(w, now: now)
                let item = NSMenuItem(title: w.project, action: #selector(attachBackgroundJob(_:)), keyEquivalent: "")
                item.attributedTitle = Self.twoLine(l.top, l.bottom)
                item.toolTip = "\(w.job?.name ?? w.project)\nclaude attach \(w.short ?? "")\nClick to attach in a new window; closing that window only detaches."
                item.target = self
                item.tag = i
                menu.addItem(item)
            }
            for j in report.recentlyEnded {
                let l = ProcessMenuText.ended(j, now: now)
                let item = NSMenuItem(title: l.top, action: nil, keyEquivalent: "")
                item.attributedTitle = Self.twoLine(l.top, l.bottom, dim: true)
                item.toolTip = "\(j.name)\nNo worker is running. Resume with: claude attach \(j.short)"
                item.isEnabled = false
                menu.addItem(item)
            }
        }

        if !report.orphans.isEmpty {
            menu.addItem(.separator())
            menu.addItem(Self.header("Orphans (\(report.orphans.count))"))
            for (i, w) in report.orphans.enumerated() {
                let l = ProcessMenuText.orphan(w)
                let item = NSMenuItem(title: w.project, action: #selector(closeOrphan(_:)), keyEquivalent: "")
                item.attributedTitle = Self.twoLine(l.top, l.bottom)
                item.toolTip = "pid \(w.rootPid)\(w.short.map { ", session \($0)" } ?? "")\nClick to close (asks first)."
                item.target = self
                item.tag = i
                menu.addItem(item)
            }
        }

        processFooter = ProcessMenuText.footer(report)
    }

    private static func header(_ title: String) -> NSMenuItem {
        let h = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        h.isEnabled = false
        return h
    }

    private static func twoLine(_ top: String, _ bottom: String, dim: Bool = false) -> NSAttributedString {
        let s = NSMutableAttributedString(string: top, attributes: [
            .font: NSFont.menuFont(ofSize: 0),
            .foregroundColor: dim ? NSColor.secondaryLabelColor : NSColor.labelColor,
        ])
        if !bottom.isEmpty {
            let clipped = bottom.count > 90 ? String(bottom.prefix(89)) + "…" : bottom
            s.append(NSAttributedString(string: "\n" + clipped, attributes: [
                .font: NSFont.menuFont(ofSize: NSFont.smallSystemFontSize),
                .foregroundColor: NSColor.secondaryLabelColor,
            ]))
        }
        return s
    }

    @objc private func attachBackgroundJob(_ sender: NSMenuItem) {
        guard backgroundJobsForMenu.indices.contains(sender.tag),
              let short = backgroundJobsForMenu[sender.tag].short else { return }
        let w = backgroundJobsForMenu[sender.tag]
        AgentsService.openAttachWindow(id: short, cwd: w.cwd ?? "", terminalService: appState.terminalService)
    }

    /// Never automatic: every close is this click plus a confirmation.
    @objc private func closeOrphan(_ sender: NSMenuItem) {
        guard orphansForMenu.indices.contains(sender.tag) else { return }
        let w = orphansForMenu[sender.tag]
        guard case .orphan(let reason) = w.cls else { return }
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "Close \(w.project)?"
        let how = w.short.map { "Runs `claude stop \($0)`, then SIGTERM to anything still running and SIGKILL after 5 s." }
            ?? "Sends SIGTERM, then SIGKILL after 5 s."
        alert.informativeText = """
            \(reason). Running \(ClaudeProcessClassifier.ageString(w.age)), \(ClaudeProcessClassifier.memoryString(kb: w.rssKB)) across \(w.killList.count) processes (pid \(w.rootPid)\(w.short.map { ", session \($0)" } ?? "")).
            \(w.cwd ?? "")

            \(how) Make sure this is not a job you still want: a long-running monitor can look idle.
            """
        alert.addButton(withTitle: "Close")
        alert.addButton(withTitle: "Cancel")
        NSApp.activate(ignoringOtherApps: true)
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        Task { await appState.processMonitor.close(w) }
    }

    @objc private func promptAccessibility() {
        GhosttyWindowService.checkAccessibility(prompt: true)
    }

    @objc private func toggleScreenCover() {
        appState.screenCoverService.toggle()
    }

    func applicationWillTerminate(_ notification: Notification) {
        appState.hotkeyService.unregister()
        appState.screenCoverService.forceUncover()
    }
}
