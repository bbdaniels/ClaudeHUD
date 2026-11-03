import SwiftUI
import AppKit
import CoreText

/// The Balatro text effect: each glyph bobs on its own phase, so a wave
/// travels along the line.
///
/// One layer per glyph, animated by Core Animation, so the motion runs in the
/// render server and costs the app nothing per frame. Two SwiftUI versions
/// (a `TimelineView` and an animatable `TextRenderer`) each cost 40 to 80% of
/// a core with the panel open, because every frame went through the hosting
/// view's layout pass.
///
/// The cost lands in WindowServer, which composites every moving glyph layer
/// on every display frame (2026-11-03: WindowServer at 60 to 75% of a core).
/// So the wave runs only while ClaudeHUD is focused (its window is key or the
/// app is active), and at most 30 frames a second; unfocused, the glyphs rest
/// on the baseline and nothing is redrawn.
///
/// Drawn as plain `Text` under Reduce Motion and when the "dancingText"
/// default is false.
struct DancingText: View {
    let text: String
    let size: CGFloat
    let weight: NSFont.Weight

    @AppStorage(DancingText.defaultsKey) private var enabled = true
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    static let defaultsKey = "dancingText"
    private static let family = "Fira Sans"

    var body: some View {
        if enabled, !reduceMotion {
            GlyphDance(text: text, font: Self.font(size: size, weight: weight))
                .allowsHitTesting(false)
        } else {
            Text(text)
                .font(Font(Self.font(size: size, weight: weight)))
                .foregroundColor(.primary)
                .lineLimit(1)
        }
    }

    private static func font(size: CGFloat, weight: NSFont.Weight) -> NSFont {
        let descriptor = NSFontDescriptor(fontAttributes: [
            .family: family,
            .traits: [NSFontDescriptor.TraitKey.weight: weight.rawValue],
        ])
        return NSFont(descriptor: descriptor, size: size)
            ?? .systemFont(ofSize: size, weight: weight)
    }
}

/// The settings switch for `DancingText`.
struct DancingTextToggle: View {
    @AppStorage(DancingText.defaultsKey) private var enabled = true

    var body: some View {
        Toggle("Dancing project names", isOn: $enabled)
            .toggleStyle(.switch)
            .controlSize(.mini)
            .font(.custom("Fira Sans", size: 12))
    }
}

private struct GlyphDance: NSViewRepresentable {
    let text: String
    let font: NSFont

    func makeNSView(context: Context) -> GlyphDanceView { GlyphDanceView() }

    func updateNSView(_ view: GlyphDanceView, context: Context) {
        view.set(text: text, font: font)
    }

    func sizeThatFits(_ proposal: ProposedViewSize, nsView: GlyphDanceView, context: Context) -> CGSize? {
        nsView.set(text: text, font: font)
        let ideal = nsView.idealSize
        return CGSize(width: min(ideal.width, proposal.width ?? ideal.width), height: ideal.height)
    }
}

private final class GlyphDanceView: NSView {
    /// Vertical travel in points, either side of the baseline.
    private static let lift: CGFloat = 0.7
    /// Seconds per full bob.
    private static let period: CFTimeInterval = 2.8
    /// Seconds each glyph lags its left neighbor: the wavelength of the wave.
    private static let glyphLag: CFTimeInterval = 0.25
    /// Room around each glyph layer so overhangs and the lift are not clipped.
    private static let pad: CGFloat = 2

    private var text = ""
    private var font = NSFont.systemFont(ofSize: 12)
    private var builtFor: (text: String, font: NSFont, width: CGFloat)?
    /// The focus observers of the current window, removed when it changes.
    private var focusObservers: [NSObjectProtocol] = []

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        setAccessibilityElement(true)
        setAccessibilityRole(.staticText)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    deinit { focusObservers.forEach(NotificationCenter.default.removeObserver) }

    func set(text: String, font: NSFont) {
        guard text != self.text || font != self.font else { return }
        self.text = text
        self.font = font
        setAccessibilityLabel(text)
        needsLayout = true
    }

    var idealSize: CGSize {
        let bounds = CTLineGetBoundsWithOptions(line(for: text), [])
        return CGSize(width: ceil(bounds.width), height: ceil(font.ascender - font.descender + font.leading))
    }

    private func line(for string: String) -> CTLine {
        CTLineCreateWithAttributedString(NSAttributedString(string: string, attributes: [.font: font]))
    }

    override func layout() {
        super.layout()
        if let built = builtFor, built.text == text, built.font == font, built.width == bounds.width { return }
        rebuild()
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        rebuild()
    }

    /// A layer loses its animations when its view leaves the window.
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        observeFocus()
        if window != nil { rebuild() }
    }

    /// Focused: this view's window is key, or ClaudeHUD is the active app.
    private var isFocused: Bool {
        guard let window else { return false }
        return window.isKeyWindow || NSApp.isActive
    }

    private func observeFocus() {
        focusObservers.forEach(NotificationCenter.default.removeObserver)
        focusObservers = []
        guard let window else { return }
        let center = NotificationCenter.default
        let changed: (Notification) -> Void = { [weak self] _ in self?.updateDance() }
        for name in [NSWindow.didBecomeKeyNotification, NSWindow.didResignKeyNotification] {
            focusObservers.append(center.addObserver(forName: name, object: window, queue: .main, using: changed))
        }
        for name in [NSApplication.didBecomeActiveNotification, NSApplication.didResignActiveNotification] {
            focusObservers.append(center.addObserver(forName: name, object: NSApp, queue: .main, using: changed))
        }
    }

    /// Starts or stops the wave on every glyph to match focus. The fixed
    /// `beginTime` of `bob` means a restarted glyph rejoins the wave in step.
    private func updateDance() {
        let focused = isFocused
        for (index, glyphLayer) in (layer?.sublayers ?? []).enumerated() {
            if focused {
                if glyphLayer.animation(forKey: "bob") == nil { glyphLayer.add(Self.bob(index: index), forKey: "bob") }
            } else {
                glyphLayer.removeAnimation(forKey: "bob")
            }
        }
    }

    private func rebuild() {
        guard let layer else { return }
        layer.sublayers?.forEach { $0.removeFromSuperlayer() }
        builtFor = (text, font, bounds.width)
        guard bounds.width > 0, !text.isEmpty else { return }

        var line = line(for: text)
        if CTLineGetBoundsWithOptions(line, []).width > bounds.width,
           let truncated = CTLineCreateTruncatedLine(line, bounds.width, .end, self.line(for: "…")) {
            line = truncated
        }

        var color = NSColor.labelColor.cgColor
        effectiveAppearance.performAsCurrentDrawingAppearance { color = NSColor.labelColor.cgColor }
        let scale = window?.backingScaleFactor ?? NSScreen.main?.backingScaleFactor ?? 2
        let baseline = (bounds.height - (font.ascender - font.descender)) / 2 - font.descender

        var index = 0
        for run in CTLineGetGlyphRuns(line) as! [CTRun] {
            let count = CTRunGetGlyphCount(run)
            guard count > 0 else { continue }
            var glyphs = [CGGlyph](repeating: 0, count: count)
            var positions = [CGPoint](repeating: .zero, count: count)
            var advances = [CGSize](repeating: .zero, count: count)
            CTRunGetGlyphs(run, CFRange(), &glyphs)
            CTRunGetPositions(run, CFRange(), &positions)
            CTRunGetAdvances(run, CFRange(), &advances)
            // The run's own font: a fallback face when ours lacks the glyph.
            let attributes = CTRunGetAttributes(run) as NSDictionary
            let runFont = attributes[kCTFontAttributeName] as! CTFont

            for i in 0..<count {
                let glyphLayer = GlyphLayer(glyph: glyphs[i], font: runFont, color: color,
                                            origin: CGPoint(x: Self.pad, y: baseline + Self.pad))
                glyphLayer.contentsScale = scale
                glyphLayer.frame = CGRect(x: positions[i].x - Self.pad, y: -Self.pad,
                                          width: advances[i].width + 2 * Self.pad,
                                          height: bounds.height + 2 * Self.pad)
                glyphLayer.setNeedsDisplay()
                if isFocused { glyphLayer.add(Self.bob(index: index), forKey: "bob") }
                layer.addSublayer(glyphLayer)
                index += 1
            }
        }
    }

    /// A fixed `beginTime` puts every glyph of every label on one clock, so a
    /// rebuilt label rejoins the wave in step.
    private static func bob(index: Int) -> CABasicAnimation {
        let bob = CABasicAnimation(keyPath: "transform.translation.y")
        bob.fromValue = -lift
        bob.toValue = lift
        bob.duration = period / 2
        bob.autoreverses = true
        bob.repeatCount = .infinity
        bob.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
        bob.beginTime = 1 + Double(index) * glyphLag
        bob.isRemovedOnCompletion = false
        // A gentle bob reads the same at 30 frames a second as at 120, at a quarter of the compositing.
        bob.preferredFrameRateRange = CAFrameRateRange(minimum: 15, maximum: 30, preferred: 30)
        return bob
    }
}

private final class GlyphLayer: CALayer {
    private let glyph: CGGlyph
    private let font: CTFont
    private let color: CGColor
    private let origin: CGPoint

    init(glyph: CGGlyph, font: CTFont, color: CGColor, origin: CGPoint) {
        self.glyph = glyph
        self.font = font
        self.color = color
        self.origin = origin
        super.init()
    }

    /// Core Animation copies a layer for its presentation tree through this.
    override init(layer: Any) {
        let other = layer as! GlyphLayer
        glyph = other.glyph
        font = other.font
        color = other.color
        origin = other.origin
        super.init(layer: layer)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    override func draw(in ctx: CGContext) {
        ctx.setFillColor(color)
        var glyph = glyph
        var origin = origin
        CTFontDrawGlyphs(font, &glyph, &origin, 1, ctx)
    }
}
