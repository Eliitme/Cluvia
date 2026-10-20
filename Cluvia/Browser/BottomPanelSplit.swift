import SwiftUI

/// Content with a panel below it (logs, terminals, port forwards) whose height the user drags and the app remembers.
/// The content keeps its place whether or not the panel shows, so toggling it never rebuilds the content.
struct BottomPanelSplit<Content: View, Panel: View>: View {
    let showsPanel: Bool
    let content: Content
    let panel: Panel
    @AppStorage("bottomPanelHeight") private var height = 280.0

    static var contentMinHeight: Double { 160 }
    static var heightRange: ClosedRange<Double> { 120...900 }

    init(showsPanel: Bool, @ViewBuilder content: () -> Content, @ViewBuilder panel: () -> Panel) {
        self.showsPanel = showsPanel
        self.content = content()
        self.panel = panel()
    }

    var body: some View {
        GeometryReader { geometry in
            let maxHeight = max(Self.heightRange.lowerBound, min(Self.heightRange.upperBound, geometry.size.height - Self.contentMinHeight - 1))
            let shown = min(height, maxHeight)
            VStack(spacing: 0) {
                content.frame(maxWidth: .infinity, minHeight: Self.contentMinHeight, maxHeight: .infinity)
                if showsPanel {
                    SplitResizeHandle(axis: .vertical, current: shown, range: Self.heightRange.lowerBound...maxHeight,
                                      label: "Bottom Panel Height") { height = $0 }
                    panel.frame(height: shown).frame(maxWidth: .infinity)
                }
            }
        }
    }
}
