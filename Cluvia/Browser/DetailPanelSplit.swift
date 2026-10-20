import SwiftUI

/// Content with a detail panel on the right whose width the user drags and the app remembers. A system split view
/// divides space evenly instead of starting the panel at a sensible width.
struct DetailPanelSplit<Content: View, Panel: View>: View {
    let showsPanel: Bool
    let content: Content
    let panel: Panel
    @AppStorage("detailPanelWidth") private var width = 380.0

    static var contentMinWidth: Double { 360 }
    static var widthRange: ClosedRange<Double> { 300...640 }

    init(showsPanel: Bool, @ViewBuilder content: () -> Content, @ViewBuilder panel: () -> Panel) {
        self.showsPanel = showsPanel
        self.content = content()
        self.panel = panel()
    }

    var body: some View {
        GeometryReader { geometry in
            // The saved width may not fit a narrower window; the content keeps its minimum either way.
            let maxWidth = max(Self.widthRange.lowerBound, min(Self.widthRange.upperBound, geometry.size.width - Self.contentMinWidth - 1))
            let shown = min(width, maxWidth)
            HStack(spacing: 0) {
                content.frame(minWidth: Self.contentMinWidth, maxWidth: .infinity, maxHeight: .infinity)
                if showsPanel {
                    SplitResizeHandle(axis: .horizontal, current: shown, range: Self.widthRange.lowerBound...maxWidth,
                                      label: "Details Panel Width") { width = $0 }
                    panel.frame(width: shown).frame(maxHeight: .infinity)
                }
            }
        }
    }
}
