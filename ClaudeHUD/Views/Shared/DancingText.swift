import SwiftUI

/// The Balatro text effect: each glyph bobs on its own phase, so a
/// wave travels along the line. Applied with `.dancing()`.
///
/// Needs `TextRenderer` (macOS 15); on 14 the text is drawn still. Off under
/// Reduce Motion and when the "dancingText" default is false.
@available(macOS 15.0, *)
private struct DanceRenderer: TextRenderer, Animatable {
    /// Position in the wave, radians. Animatable, so SwiftUI redraws the
    /// glyphs per frame without re-evaluating the row that holds the text.
    var phase: Double

    var animatableData: Double {
        get { phase }
        set { phase = newValue }
    }

    /// Vertical travel in points, either side of the baseline.
    private static let lift: CGFloat = 0.7
    /// Seconds per full bob.
    static let period: Double = 2.8
    /// Phase lag between neighboring glyphs: the wavelength of the wave.
    private static let glyphLag: Double = 0.55

    func draw(layout: Text.Layout, in ctx: inout GraphicsContext) {
        var index = 0
        for line in layout {
            for run in line {
                for glyph in run {
                    let phase = self.phase - Double(index) * Self.glyphLag
                    // Translation only. A rotated glyph misses the glyph
                    // cache and is rasterized as a path on every frame.
                    var copy = ctx
                    copy.translateBy(x: 0, y: Self.lift * sin(phase))
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

    @State private var phase: Double = 0

    static let defaultsKey = "dancingText"

    func body(content: Content) -> some View {
        if #available(macOS 15.0, *), enabled, !reduceMotion {
            content
                .textRenderer(DanceRenderer(phase: phase))
                .onAppear {
                    phase = 0
                    withAnimation(.linear(duration: DanceRenderer.period).repeatForever(autoreverses: false)) {
                        phase = 2 * .pi
                    }
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
