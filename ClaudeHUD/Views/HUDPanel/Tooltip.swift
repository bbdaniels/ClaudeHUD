import SwiftUI

// Custom, pure-SwiftUI tooltip.
//
// Why this exists instead of `.help()`: ClaudeHUD is an `.accessory` menubar
// agent whose UI lives in an NSPanel hosted via NSHostingController. In that
// configuration AppKit's tooltip subsystem (`NSView.toolTip`, which SwiftUI
// `.help()` drives) never fires — verified empirically across hosting-view,
// styleMask, and inactive-app-tooltip fixes. `.onHover` *does* fire here
// (the same mouse events that make the buttons clickable), so we drive the
// tooltip ourselves and render it at the panel root via an anchor preference
// so List/ScrollView row clipping cannot swallow it.

private struct TooltipPreferenceKey: PreferenceKey {
    struct Item: Equatable {
        let anchor: Anchor<CGRect>
        let text: String
        static func == (l: Item, r: Item) -> Bool { l.text == r.text }
    }
    static var defaultValue: [Item] = []
    static func reduce(value: inout [Item], nextValue: () -> [Item]) {
        value.append(contentsOf: nextValue())
    }
}

private struct HUDTipModifier: ViewModifier {
    let text: String
    @State private var armed = false
    @State private var hoverTask: Task<Void, Never>?

    func body(content: Content) -> some View {
        content
            .onHover { hovering in
                hoverTask?.cancel()
                if hovering && !text.isEmpty {
                    hoverTask = Task { @MainActor in
                        try? await Task.sleep(nanoseconds: 400_000_000)
                        if !Task.isCancelled { armed = true }
                    }
                } else {
                    armed = false
                }
            }
            .anchorPreference(key: TooltipPreferenceKey.self, value: .bounds) { anchor in
                armed && !text.isEmpty
                    ? [TooltipPreferenceKey.Item(anchor: anchor, text: text)]
                    : []
            }
    }
}

private struct TooltipBubble: View {
    @Environment(\.fontScale) private var scale
    let text: String
    var body: some View {
        Text(text)
            .font(.captionFont(scale))          // same family as the HUD (Fira Sans)
            .foregroundColor(.primary)
            .lineLimit(1)
            .fixedSize()                        // chip hugs the text, no wide background
            .padding(.horizontal, 7)
            .padding(.vertical, 4)
            // Light chip, not a hard bordered/shadowed window.
            .background(
                RoundedRectangle(cornerRadius: 4)
                    .fill(Color(nsColor: .windowBackgroundColor).opacity(0.96))
            )
            .allowsHitTesting(false)
    }
}

private struct PositionedTooltip: View {
    let text: String
    let rect: CGRect
    let container: CGSize
    @State private var size: CGSize = .zero

    var body: some View {
        let pad: CGFloat = 8
        let gap: CGFloat = 6
        let x = min(max(pad, rect.minX), max(pad, container.width - size.width - pad))
        // Prefer ABOVE the element; only drop below if there is no room up top.
        let aboveY = rect.minY - size.height - gap
        let y = aboveY >= pad ? aboveY : rect.maxY + gap

        TooltipBubble(text: text)
            .background(
                GeometryReader { g in
                    Color.clear
                        .onChange(of: g.size, initial: true) { _, newValue in
                            size = newValue
                        }
                }
            )
            .offset(x: x, y: max(pad, y))
            .opacity(size == .zero ? 0 : 1)   // avoid a one-frame flash before measured
            .transition(.opacity)
    }
}

private struct HUDTooltipLayer: ViewModifier {
    func body(content: Content) -> some View {
        content.overlayPreferenceValue(TooltipPreferenceKey.self) { items in
            GeometryReader { proxy in
                if let item = items.last {
                    PositionedTooltip(
                        text: item.text,
                        rect: proxy[item.anchor],
                        container: proxy.size
                    )
                }
            }
            .allowsHitTesting(false)
            .animation(.easeInOut(duration: 0.12), value: items)
        }
    }
}

extension View {
    /// Attach a hover tooltip. Drop-in for `.help(_:)` inside the HUD panel.
    /// Requires an ancestor to apply `.hudTooltipLayer()`.
    func hudTip(_ text: String) -> some View { modifier(HUDTipModifier(text: text)) }

    /// Apply once at the panel root so tooltips render above all content.
    func hudTooltipLayer() -> some View { modifier(HUDTooltipLayer()) }
}
