/// What a menu bar click or the hotkey does to the HUD panel (Ben, 2026-11-06).
///
/// Hide it only when it is in front: shown, on this desktop, and the key
/// window of the active app. A panel buried under another app's window is
/// brought forward instead. The old rule hid any panel that was visible on the
/// current desktop, so the first click on a buried panel hid it and only a
/// second click showed it.
///
/// Pure, so the rule is unit tested; `HUDPanelController.toggle` reads the
/// window state and acts.
enum PanelToggle {
    enum Action: Equatable { case show, hide }

    static func action(isVisible: Bool, isOnActiveSpace: Bool, appIsActive: Bool, isKeyWindow: Bool) -> Action {
        isVisible && isOnActiveSpace && appIsActive && isKeyWindow ? .hide : .show
    }
}
