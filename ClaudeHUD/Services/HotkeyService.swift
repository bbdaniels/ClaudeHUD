import Cocoa
import os

private let logger = Logger(subsystem: "com.claudehud", category: "Hotkey")

// MARK: - Hotkey Service

/// Registers a global hotkey (Cmd+Shift+Space) to toggle the HUD panel.
///
/// Uses NSEvent monitors: a global monitor for when the app is in the background,
/// and a local monitor for when the app is in the foreground.
@MainActor
class HotkeyService: ObservableObject {
    @Published var isRegistered = false

    private var globalMonitor: Any?
    private var localMonitor: Any?
    private var onToggle: (() -> Void)?

    // Default hotkey: Cmd+Shift+Space (keyCode 49 = Space)
    private let requiredModifiers: NSEvent.ModifierFlags = [.command, .shift]
    private let requiredKeyCode: UInt16 = 49

    // MARK: - Register

    /// Register the global hotkey. The `onToggle` closure is called on the main thread
    /// whenever the hotkey combination is pressed.
    func register(onToggle: @escaping () -> Void) {
        guard !isRegistered else {
            logger.warning("Hotkey already registered")
            return
        }

        self.onToggle = onToggle

        // Global monitor: fires when the app is NOT the key window / frontmost
        globalMonitor = NSEvent.addGlobalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self else { return }
            if self.matchesHotkey(event) {
                DispatchQueue.main.async {
                    self.onToggle?()
                }
            }
        }

        // Local monitor: fires when the app IS the key window
        localMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self else { return event }
            if self.matchesHotkey(event) {
                DispatchQueue.main.async {
                    self.onToggle?()
                }
                return nil // consume the event
            }
            return event // pass through
        }

        isRegistered = true
        logger.info("Global hotkey registered: Cmd+Shift+Space")
    }

    // MARK: - Unregister

    func unregister() {
        if let globalMonitor {
            NSEvent.removeMonitor(globalMonitor)
            self.globalMonitor = nil
        }
        if let localMonitor {
            NSEvent.removeMonitor(localMonitor)
            self.localMonitor = nil
        }

        onToggle = nil
        isRegistered = false
        logger.info("Global hotkey unregistered")
    }

    // MARK: - Helpers

    /// Check whether a keyboard event matches the configured hotkey.
    private nonisolated func matchesHotkey(_ event: NSEvent) -> Bool {
        // Check that exactly the required modifiers are held (ignoring caps lock, etc.)
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        let requiredOnly: NSEvent.ModifierFlags = [.command, .shift]
        return flags.contains(requiredOnly) && event.keyCode == requiredKeyCode
    }

    deinit {
        // Clean up monitors. Since deinit is nonisolated and NSEvent.removeMonitor
        // is thread-safe, this is fine.
        if let globalMonitor {
            NSEvent.removeMonitor(globalMonitor)
        }
        if let localMonitor {
            NSEvent.removeMonitor(localMonitor)
        }
    }
}
