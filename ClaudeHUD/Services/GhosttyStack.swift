import CoreGraphics

/// Which Ghostty instances sit entirely under the front one, and so can be
/// hidden without changing what is visible.
///
/// Every HUD session is its own Ghostty process with a translucent window
/// (`background-opacity = 0.9`), so a buried window is never occluded:
/// macOS keeps compositing it, and each spinner frame or line of output in a
/// session nobody can see makes WindowServer redraw the stack. Measured
/// 2026-11-03 with six full-screen instances: WindowServer at 27 to 42% of a
/// core with all six shown, 20.5% (twice) with the five buried ones hidden.
///
/// Pure geometry, so the rule is unit tested; `GhosttyStackManager` reads the
/// window list and does the hiding.
enum GhosttyStack {
    /// Slack, in points, for window shadows and a frame nudged by a pixel or two.
    static let tolerance: CGFloat = 8

    /// The pids in `others` whose on-screen windows all lie inside some window
    /// of the front instance. An instance with any window outside (side by
    /// side, or overlapping only in part) stays visible, and one with no
    /// on-screen window is not touched.
    static func coveredPids(front: [CGRect], others: [Int32: [CGRect]]) -> [Int32] {
        let covers = front.map { $0.insetBy(dx: -tolerance, dy: -tolerance) }
        guard !covers.isEmpty else { return [] }
        return others.compactMap { pid, windows in
            guard !windows.isEmpty else { return nil }
            let allCovered = windows.allSatisfy { window in covers.contains { $0.contains(window) } }
            return allCovered ? pid : nil
        }.sorted()
    }
}
