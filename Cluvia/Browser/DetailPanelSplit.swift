import AppKit
import SwiftUI

/// Content with a detail panel on the right whose width the user drags and the app remembers. A system split view
/// divides space evenly instead of starting the panel at a sensible width.
struct DetailPanelSplit<Content: View, Panel: View>: View {
    let showsPanel: Bool
    let content: Content
    let panel: Panel
    @AppStorage("detailPanelWidth") private var width = 380.0
    @State private var dragStart: Double?

    init(showsPanel: Bool, @ViewBuilder content: () -> Content, @ViewBuilder panel: () -> Panel) {
        self.showsPanel = showsPanel
        self.content = content()
        self.panel = panel()
    }

    static var widthRange: ClosedRange<Double> { 300...640 }

    var body: some View {
        HStack(spacing: 0) {
            content.frame(minWidth: 360, maxWidth: .infinity, maxHeight: .infinity)
            if showsPanel {
                handle
                panel.frame(width: width).frame(maxHeight: .infinity)
            }
        }
    }

    private var handle: some View {
        Divider()
            .overlay {
                Color.clear
                    .frame(width: 8)
                    .contentShape(Rectangle())
                    .onHover { inside in if inside { NSCursor.resizeLeftRight.push() } else { NSCursor.pop() } }
                    .gesture(
                        DragGesture(minimumDistance: 1)
                            .onChanged { drag in
                                let start = dragStart ?? width
                                dragStart = start
                                width = min(max(start - drag.translation.width, Self.widthRange.lowerBound), Self.widthRange.upperBound)
                            }
                            .onEnded { _ in dragStart = nil }
                    )
            }
            .accessibilityLabel("Resize Details Panel")
    }
}
