//  Adapted from Lockpaw, Copyright (c) 2025 Erik Nielsen, MIT License,
//  https://github.com/sorkila/lockpaw

import AppKit
import CoreGraphics
import IOKit.pwr_mgt
import LocalAuthentication
import QuartzCore
import SwiftUI
import os

private let logger = Logger(subsystem: "com.claudehud", category: "ScreenCover")

extension Notification.Name {
    /// Posted from the event-tap thread when a physical key/click lands on a
    /// covered screen. The tap swallows the event itself, so this is the only
    /// channel the cover has for "someone touched the machine".
    static let claudeHUDCoverInput = Notification.Name("com.claudehud.cover.input")
    /// Escape hatch chord recognised inside the tap callback.
    static let claudeHUDCoverPanic = Notification.Name("com.claudehud.cover.panic")
}

private enum CoverTiming {
    static let fadeIn = 0.30
    static let fadeOut = 0.25
    static let tapStartDelayNs: UInt64 = 50_000_000
    static let inputThrottle = 0.35
    static let screenChangeDebounce = 0.30
    static let userActivityRefresh = 30.0
    static let errorAutoClear = 5.0
    static let errorBeforeForceUncover = 1.5
    static let maxAuthAttempts = 3
    static let authCooldown = 30.0
}

enum CoverDefaults {
    static let messageKey = "coverLockMessage"
    static let requireAuthKey = "coverRequireAuth"
    static let defaultMessage = "Agents are working. Don't turn me off."
}

/// Borderless windows refuse key status, and key status is what
/// `NSCursor.setHiddenUntilMouseMoves` needs.
private final class CoverWindow: NSWindow {
    override var canBecomeKey: Bool { true }
}

/// A `CFMachPort` is thread-safe for `tapEnable` and runloop-source use, but
/// carries no `Sendable` conformance, so hand it to the tap thread in a box.
private struct TapPort: @unchecked Sendable {
    let tap: CFMachPort
    init(_ tap: CFMachPort) { self.tap = tap }
}

/// Owns the tap port for the duration of the tap thread. Retained by the
/// refcon (+1) and released on the thread when the runloop exits, so the
/// callback can never dereference a freed context.
private final class CoverTapContext {
    var tap: CFMachPort?
    var lastInputPost: CFAbsoluteTime = 0
}

/// Holds the IOPM assertion outside the actor so `deinit` can release it
/// without touching main-actor state.
private final class SleepAssertionBox {
    private var assertionID: IOPMAssertionID = 0
    private var activityAssertionID: IOPMAssertionID = 0
    private(set) var isActive = false

    func prevent(reason: String) {
        guard !isActive else { return }
        let result = IOPMAssertionCreateWithName(
            kIOPMAssertionTypeNoDisplaySleep as CFString,
            IOPMAssertionLevel(kIOPMAssertionLevelOn),
            reason as CFString,
            &assertionID
        )
        guard result == kIOReturnSuccess else {
            logger.error("Display-sleep assertion failed: \(result)")
            return
        }
        isActive = true
    }

    /// The display assertion alone does not defeat the screensaver idle
    /// timer; declaring user activity does.
    func declareUserActivity() {
        let result = IOPMAssertionDeclareUserActivity(
            "ClaudeHUD screen cover" as CFString,
            kIOPMUserActiveLocal,
            &activityAssertionID
        )
        if result != kIOReturnSuccess {
            logger.error("DeclareUserActivity failed: \(result)")
        }
    }

    func release() {
        guard isActive else { return }
        let result = IOPMAssertionRelease(assertionID)
        if result != kIOReturnSuccess {
            logger.error("Failed to release display-sleep assertion: \(result)")
        }
        isActive = false
    }

    deinit { release() }
}

private func coverTapCallback(
    proxy: CGEventTapProxy,
    type: CGEventType,
    event: CGEvent,
    refcon: UnsafeMutableRawPointer?
) -> Unmanaged<CGEvent>? {
    if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
        if let refcon {
            let ctx = Unmanaged<CoverTapContext>.fromOpaque(refcon).takeUnretainedValue()
            if let tap = ctx.tap { CGEvent.tapEnable(tap: tap, enable: true) }
        }
        return nil
    }

    if type == .keyDown {
        let flags = event.flags
        let keyCode = event.getIntegerValueField(.keyboardEventKeycode)
        if keyCode == 53,
           flags.contains(.maskControl), flags.contains(.maskAlternate), flags.contains(.maskCommand) {
            DispatchQueue.main.async {
                NotificationCenter.default.post(name: .claudeHUDCoverPanic, object: nil)
            }
            return nil
        }
    }

    let wakes = type == .keyDown
        || type == .leftMouseDown || type == .rightMouseDown || type == .otherMouseDown
        || type == .scrollWheel
    if wakes, let refcon {
        let ctx = Unmanaged<CoverTapContext>.fromOpaque(refcon).takeUnretainedValue()
        let now = CFAbsoluteTimeGetCurrent()
        if now - ctx.lastInputPost >= CoverTiming.inputThrottle {
            ctx.lastInputPost = now
            DispatchQueue.main.async {
                NotificationCenter.default.post(name: .claudeHUDCoverInput, object: nil)
            }
        }
    }

    return nil
}

/// Covers every display with an opaque black window while background agents
/// work, holds the display awake, and (with Accessibility) swallows input so
/// a passing keystroke cannot interrupt a running session.
@MainActor
final class ScreenCoverService: ObservableObject {
    @Published private(set) var isCovered = false
    @Published private(set) var isAuthenticating = false
    @Published private(set) var inputBlocked = false
    @Published private(set) var lastError: String?

    private let agents: AgentsService
    private let sleep = SleepAssertionBox()

    private var windows: [NSWindow] = []
    private let shieldLevel = NSWindow.Level(rawValue: Int(CGShieldingWindowLevel()))

    private var eventTap: CFMachPort?
    private var tapThread: Thread?
    private var localMonitor: Any?
    private var wantsInputBlocking = false

    private var activityTimer: Timer?
    private var accessibilityTimer: Timer?
    private var errorClearTask: Task<Void, Never>?
    private var screenChangeWork: DispatchWorkItem?
    private var observers: [NSObjectProtocol] = []
    private var workspaceObservers: [NSObjectProtocol] = []

    private var authInProgress = false
    private var activeContext: LAContext?
    private var failCount = 0
    private var lastFailAt: Date?

    var lockMessage: String {
        let stored = UserDefaults.standard.string(forKey: CoverDefaults.messageKey)
        let trimmed = stored?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return trimmed.isEmpty ? CoverDefaults.defaultMessage : trimmed
    }

    var requiresAuthentication: Bool {
        UserDefaults.standard.object(forKey: CoverDefaults.requireAuthKey) as? Bool ?? true
    }

    init(agents: AgentsService) {
        self.agents = agents

        observers.append(NotificationCenter.default.addObserver(
            forName: .claudeHUDCoverInput, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.handleCoverInput() }
        })

        // The panic observer lives for the life of the service, not just the
        // life of a cover, so the chord can never be swallowed by a torn
        // observer list.
        observers.append(NotificationCenter.default.addObserver(
            forName: .claudeHUDCoverPanic, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                logger.critical("Cover panic chord — force uncovering")
                self?.forceUncover()
            }
        })
    }

    // MARK: - Cover

    func toggle() {
        if isCovered {
            requestUncover()
        } else {
            cover()
        }
    }

    func cover() {
        guard !isCovered else { return }

        // Without Accessibility the tap would be dead, so the cover shows
        // degraded (visible, input passes through) rather than presenting a
        // black screen that silently eats nothing.
        let trusted = GhosttyWindowService.checkAccessibility(prompt: false)
        if !trusted {
            GhosttyWindowService.checkAccessibility(prompt: true)
            logger.warning("Accessibility not granted — covering without input blocking")
        }

        guard !NSScreen.screens.isEmpty else {
            logger.error("No screens — refusing to cover")
            return
        }

        failCount = 0
        lastFailAt = nil
        lastError = nil
        agents.start()
        sleep.prevent(reason: "ClaudeHUD: screen covered — agents running")
        startActivityTimer()

        buildWindows()
        guard !windows.isEmpty else {
            stopActivityTimer()
            sleep.release()
            logger.error("Failed to build cover windows — rolled back")
            return
        }

        isCovered = true
        installObservers()
        installLocalInputMonitor()
        concealCursor()

        wantsInputBlocking = trusted
        guard trusted else { return }

        // Shield first, tap second: the windows must be on screen before
        // input dies, or a failure leaves input blocked with nothing shown.
        Task { [weak self] in
            try? await Task.sleep(nanoseconds: CoverTiming.tapStartDelayNs)
            guard let self, self.isCovered else { return }
            self.startInputBlocking()
        }
        startAccessibilityMonitoring()
    }

    func requestUncover() {
        guard isCovered else { return }
        if requiresAuthentication {
            requestAuthenticatedUncover()
        } else {
            uncover(animated: true)
        }
    }

    func uncover(animated: Bool = true) {
        guard isCovered || !windows.isEmpty else { return }
        stopAccessibilityMonitoring()
        stopInputBlocking()
        removeLocalInputMonitor()
        removeObservers()
        screenChangeWork?.cancel()
        screenChangeWork = nil
        errorClearTask?.cancel()
        errorClearTask = nil
        activeContext?.invalidate()
        activeContext = nil
        authInProgress = false
        isAuthenticating = false
        wantsInputBlocking = false
        lastError = nil
        isCovered = false
        dismissWindows(animated: animated)
        stopActivityTimer()
        sleep.release()
    }

    /// Unconditional teardown. Assigns state directly and dismisses without
    /// animation so nothing depends on a completion handler that may not run.
    func forceUncover() {
        uncover(animated: false)
    }

    // MARK: - Windows

    private func buildWindows() {
        for (index, screen) in NSScreen.screens.enumerated() {
            let isPrimary = index == 0
            let window = CoverWindow(
                contentRect: screen.frame,
                styleMask: .borderless,
                backing: .buffered,
                defer: false,
                screen: screen
            )
            window.setFrame(screen.frame, display: true)
            window.level = shieldLevel
            window.collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary, .ignoresCycle]
            window.isOpaque = false
            window.backgroundColor = .clear
            window.hasShadow = false
            window.isRestorable = false
            window.isExcludedFromWindowsMenu = true
            window.ignoresMouseEvents = !isPrimary

            let host = NSHostingView(
                rootView: ScreenCoverView(service: self, agents: agents, isPrimary: isPrimary)
            )
            // Defaults to 0, which leaves the content unstretched on scaled
            // and external displays.
            host.autoresizingMask = [.width, .height]
            host.frame = window.contentLayoutRect
            window.contentView = host

            window.alphaValue = 0
            window.orderFrontRegardless()
            NSAnimationContext.runAnimationGroup { ctx in
                ctx.duration = CoverTiming.fadeIn
                ctx.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
                window.animator().alphaValue = 1
            }

            windows.append(window)
        }
    }

    /// Never `close()` — closing during the fade animation crashes in
    /// `_NSWindowTransformAnimation` dealloc.
    private func dismissWindows(animated: Bool) {
        let dismissing = windows
        windows.removeAll()
        NSCursor.setHiddenUntilMouseMoves(false)

        guard animated, !dismissing.isEmpty else {
            for window in dismissing {
                window.orderOut(nil)
                window.contentView = nil
            }
            return
        }

        NSAnimationContext.runAnimationGroup({ ctx in
            ctx.duration = CoverTiming.fadeOut
            ctx.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            for window in dismissing {
                window.animator().alphaValue = 0
            }
        }, completionHandler: {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                for window in dismissing {
                    window.orderOut(nil)
                    window.contentView = nil
                }
            }
        })
    }

    private func rebuildWindows() {
        guard isCovered else { return }
        dismissWindows(animated: false)
        buildWindows()
        concealCursor()
    }

    private func allowSystemDialogs() {
        for window in windows { window.level = .statusBar }
    }

    private func blockSystemDialogs() {
        for window in windows { window.level = shieldLevel }
    }

    private func concealCursor() {
        NSApp.activate(ignoringOtherApps: true)
        windows.first?.makeKey()
        NSCursor.setHiddenUntilMouseMoves(true)
        DispatchQueue.main.async {
            NSCursor.setHiddenUntilMouseMoves(true)
        }
    }

    // MARK: - Input blocking

    private func startInputBlocking() {
        guard eventTap == nil else { return }
        // `tapCreate` succeeds without Accessibility and hands back a dead
        // tap, so trust — not the nil check — is the real gate.
        guard AXIsProcessTrusted() else {
            inputBlocked = false
            return
        }

        let types: [CGEventType] = [
            .keyDown, .keyUp, .flagsChanged, .scrollWheel,
            .leftMouseDown, .leftMouseUp,
            .rightMouseDown, .rightMouseUp,
            .otherMouseDown, .otherMouseUp
        ]
        let mask = types.reduce(CGEventMask(0)) { $0 | (1 << $1.rawValue) }

        let ctx = CoverTapContext()
        let refcon = Unmanaged.passRetained(ctx).toOpaque()

        guard let tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .defaultTap,
            eventsOfInterest: mask,
            callback: coverTapCallback,
            userInfo: refcon
        ) else {
            Unmanaged<CoverTapContext>.fromOpaque(refcon).release()
            // Trusted but the tap would not create: an unexpected failure, so
            // show why and get out rather than sitting behind a cover whose
            // whole point has silently gone missing.
            logger.error("Could not create event tap — force uncovering")
            inputBlocked = false
            lastError = "Input blocking failed"
            Task { [weak self] in
                try? await Task.sleep(
                    nanoseconds: UInt64(CoverTiming.errorBeforeForceUncover * 1_000_000_000))
                self?.forceUncover()
            }
            return
        }

        ctx.tap = tap
        eventTap = tap

        let port = TapPort(tap)
        let thread = Thread {
            guard let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, port.tap, 0) else {
                Unmanaged<CoverTapContext>.fromOpaque(refcon).release()
                return
            }
            let runLoop = CFRunLoopGetCurrent()
            CFRunLoopAddSource(runLoop, source, .commonModes)
            CGEvent.tapEnable(tap: port.tap, enable: true)
            while !Thread.current.isCancelled {
                CFRunLoopRunInMode(.defaultMode, 0.25, false)
            }
            CGEvent.tapEnable(tap: port.tap, enable: false)
            CFRunLoopRemoveSource(runLoop, source, .commonModes)
            Unmanaged<CoverTapContext>.fromOpaque(refcon).release()
        }
        thread.name = "com.claudehud.screencover.tap"
        thread.qualityOfService = .userInteractive
        thread.start()
        tapThread = thread
        inputBlocked = true
    }

    /// Second, independent route to the unlock flow. The tap swallows events
    /// before any NSEvent monitor sees them, so this only ever fires when the
    /// tap is absent — which is exactly the degraded, no-Accessibility case
    /// where it is the user's only way out.
    private func installLocalInputMonitor() {
        guard localMonitor == nil else { return }
        localMonitor = NSEvent.addLocalMonitorForEvents(
            matching: [.keyDown, .leftMouseDown, .rightMouseDown, .otherMouseDown, .scrollWheel]
        ) { [weak self] event in
            let consumed = MainActor.assumeIsolated { () -> Bool in
                guard let self, self.isCovered, !self.authInProgress else { return false }
                self.handleCoverInput()
                return true
            }
            return consumed ? nil : event
        }
    }

    private func removeLocalInputMonitor() {
        if let localMonitor {
            NSEvent.removeMonitor(localMonitor)
            self.localMonitor = nil
        }
    }

    private func stopInputBlocking() {
        if let eventTap {
            CGEvent.tapEnable(tap: eventTap, enable: false)
        }
        tapThread?.cancel()
        tapThread = nil
        eventTap = nil
        inputBlocked = false
    }

    private func cycleInputBlocking() {
        guard isCovered, wantsInputBlocking else { return }
        stopInputBlocking()
        startInputBlocking()
        blockSystemDialogs()
    }

    // MARK: - Unlock

    private func handleCoverInput() {
        guard isCovered, !authInProgress else { return }
        if requiresAuthentication {
            requestAuthenticatedUncover()
        } else {
            uncover(animated: true)
        }
    }

    private func requestAuthenticatedUncover() {
        guard isCovered, !authInProgress else { return }

        if failCount >= CoverTiming.maxAuthAttempts, let lastFailAt,
           Date().timeIntervalSince(lastFailAt) < CoverTiming.authCooldown {
            let remaining = Int(CoverTiming.authCooldown - Date().timeIntervalSince(lastFailAt))
            lastError = "Too many attempts. Wait \(remaining)s."
            scheduleErrorClear()
            return
        }

        let context = LAContext()
        context.localizedCancelTitle = "Cancel"
        context.localizedFallbackTitle = "Use Password…"

        var policyError: NSError?
        guard context.canEvaluatePolicy(.deviceOwnerAuthentication, error: &policyError) else {
            // No credential is available at all, so requiring one would trap
            // the user behind a cover nothing can dismiss.
            logger.error("Authentication unavailable: \(policyError?.localizedDescription ?? "unknown")")
            forceUncover()
            return
        }

        authInProgress = true
        isAuthenticating = true
        lastError = nil
        activeContext = context
        allowSystemDialogs()
        stopInputBlocking()

        Task { [weak self] in
            let granted = await Self.evaluate(context, reason: "Uncover the ClaudeHUD screen")
            guard let self else { return }
            self.activeContext = nil
            guard self.isCovered, self.authInProgress else {
                self.authInProgress = false
                self.isAuthenticating = false
                return
            }
            if granted {
                self.uncover(animated: true)
            } else {
                self.handleAuthFailure()
            }
        }
    }

    /// Evaluated off the main actor: the system dialog itself needs the main
    /// thread, so awaiting it there deadlocks.
    private nonisolated static func evaluate(_ context: LAContext, reason: String) async -> Bool {
        await Task.detached { [context] in
            do {
                return try await context.evaluatePolicy(.deviceOwnerAuthentication, localizedReason: reason)
            } catch {
                return false
            }
        }.value
    }

    private func handleAuthFailure() {
        failCount += 1
        lastFailAt = Date()
        lastError = failCount >= CoverTiming.maxAuthAttempts
            ? "Too many attempts. Wait \(Int(CoverTiming.authCooldown)) seconds."
            : "Try again"
        authInProgress = false
        isAuthenticating = false
        blockSystemDialogs()
        if wantsInputBlocking { startInputBlocking() }
        scheduleErrorClear()
    }

    private func scheduleErrorClear() {
        errorClearTask?.cancel()
        errorClearTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(CoverTiming.errorAutoClear * 1_000_000_000))
            guard !Task.isCancelled else { return }
            self?.lastError = nil
        }
    }

    // MARK: - Keep awake

    private func startActivityTimer() {
        stopActivityTimer()
        sleep.declareUserActivity()
        activityTimer = Timer.scheduledTimer(
            withTimeInterval: CoverTiming.userActivityRefresh, repeats: true
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.sleep.declareUserActivity() }
        }
    }

    private func stopActivityTimer() {
        activityTimer?.invalidate()
        activityTimer = nil
    }

    // MARK: - Watchdog

    /// Revoking Accessibility mid-cover would otherwise leave an unblockable
    /// shield over every display forever.
    private func startAccessibilityMonitoring() {
        accessibilityTimer?.invalidate()
        accessibilityTimer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, self.isCovered, self.wantsInputBlocking,
                      !AXIsProcessTrusted() else { return }
                logger.critical("Accessibility revoked while covered — force uncovering")
                self.lastError = "Accessibility permission revoked"
                self.accessibilityTimer?.invalidate()
                self.accessibilityTimer = nil
                DispatchQueue.main.asyncAfter(deadline: .now() + CoverTiming.errorBeforeForceUncover) {
                    self.forceUncover()
                }
            }
        }
    }

    private func stopAccessibilityMonitoring() {
        accessibilityTimer?.invalidate()
        accessibilityTimer = nil
    }

    // MARK: - Observers

    private func installObservers() {
        workspaceObservers.append(NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.scheduleScreenRebuild() }
        })

        let workspace = NSWorkspace.shared.notificationCenter
        workspaceObservers.append(workspace.addObserver(
            forName: NSWorkspace.screensDidWakeNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.cycleInputBlocking() }
        })
        workspaceObservers.append(workspace.addObserver(
            forName: NSWorkspace.sessionDidBecomeActiveNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.cycleInputBlocking() }
        })
        workspaceObservers.append(workspace.addObserver(
            forName: NSWorkspace.sessionDidResignActiveNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.handleSessionLost() }
        })
    }

    private func removeObservers() {
        for observer in workspaceObservers {
            NotificationCenter.default.removeObserver(observer)
            NSWorkspace.shared.notificationCenter.removeObserver(observer)
        }
        workspaceObservers.removeAll()
    }

    private func handleSessionLost() {
        guard isCovered, authInProgress else { return }
        activeContext?.invalidate()
        activeContext = nil
        authInProgress = false
        isAuthenticating = false
        lastError = "Session interrupted — try again"
        blockSystemDialogs()
        if wantsInputBlocking { startInputBlocking() }
        scheduleErrorClear()
    }

    private func scheduleScreenRebuild() {
        screenChangeWork?.cancel()
        let work = DispatchWorkItem { [weak self] in
            MainActor.assumeIsolated { self?.rebuildWindows() }
        }
        screenChangeWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + CoverTiming.screenChangeDebounce, execute: work)
    }

    deinit {
        for observer in observers {
            NotificationCenter.default.removeObserver(observer)
        }
    }
}
