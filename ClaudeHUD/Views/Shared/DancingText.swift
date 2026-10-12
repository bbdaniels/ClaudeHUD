import SwiftUI

/// The Balatro text effect: each glyph bobs and tilts on its own phase, so a
/// wave travels along the line. Applied with `.dancing()`.
///
/// Needs `TextRenderer` (macOS 15); on 14 the text is drawn still. Off under
/// Reduce Motion and when the "dancingText" default is false.
@available(macOS 15.0, *)
private struct DanceRenderer: TextRenderer {
    var time: TimeInterval

    /// Vertical travel in points, either side of the baseline.
    private static let lift: CGFloat = 1.3
    /// Peak tilt in radians.
    private static let tilt: Double = 0.05
    /// Radians per second.
    private static let speed: Double = 3.2
    /// Phase lag between neighboring glyphs: the wavelength of the wave.
    private static let glyphLag: Double = 0.55

    func draw(layout: Text.Layout, in ctx: inout GraphicsContext) {
        var index = 0
        for line in layout {
            for run in line {
                for glyph in run {
                    let phase = time * Self.speed - Double(index) * Self.glyphLag
                    let box = glyph.typographicBounds.rect
                    var copy = ctx
                    copy.translateBy(x: box.midX, y: box.midY + Self.lift * sin(phase))
                    copy.rotate(by: .radians(Self.tilt * cos(phase)))
                    copy.translateBy(x: -box.midX, y: -box.midY)
                    copy.draw(glyph)
                    index += 1
                }
            }
        }
    }
}

private struct DancingText: ViewModifier {
    @AppStorage(DancingText.defaultsKey) private var enabled = true
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    static let defaultsKey = "dancingText"

    func body(content: Content) -> some View {
        if #available(macOS 15.0, *), enabled, !reduceMotion {
            TimelineView(.animation(minimumInterval: 1.0 / 30)) { timeline in
                content.textRenderer(
                    DanceRenderer(time: timeline.date.timeIntervalSinceReferenceDate))
            }
        } else {
            content
        }
    }
}

extension View {
    /// Makes the text in this view dance, one glyph at a time.
    func dancing() -> some View { modifier(DancingText()) }
}

/// The settings switch for `.dancing()`.
struct DancingTextToggle: View {
    @AppStorage(DancingText.defaultsKey) private var enabled = true

    var body: some View {
        Toggle("Dancing project names", isOn: $enabled)
            .toggleStyle(.switch)
            .controlSize(.mini)
            .font(.custom("Fira Sans", size: 12))
    }
}
