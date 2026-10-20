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
    @State private var cursorPushed = false

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
                    handle(current: shown, maxWidth: maxWidth)
                    panel.frame(width: shown).frame(maxHeight: .infinity)
                }
            }
        }
    }

    private func handle(current: Double, maxWidth: Double) -> some View {
        Divider()
            .overlay {
                Color.clear
                    .frame(width: 8)
                    .contentShape(Rectangle())
                    .onHover { inside in
                        // While dragging the pointer may leave the strip; keep the resize cursor until the drag ends.
                        if inside { pushCursor() } else if dragStart == nil { popCursor() }
                    }
                    .onDisappear { popCursor() }
                    // Global coordinates: the handle itself moves as the width changes, which would skew local ones.
                    .gesture(
                        DragGesture(minimumDistance: 1, coordinateSpace: .global)
                            .onChanged { drag in
                                let start = dragStart ?? current
                                dragStart = start
                                width = min(max(start - drag.translation.width, Self.widthRange.lowerBound), maxWidth)
                            }
                            .onEnded { _ in
                                dragStart = nil
                                popCursor()
                            }
                    )
            }
            .accessibilityElement()
            .accessibilityLabel("Details Panel Width")
            .accessibilityValue("\(Int(current)) points")
            .accessibilityAdjustableAction { direction in
                let step = direction == .increment ? 40.0 : -40.0
                width = min(max(current + step, Self.widthRange.lowerBound), maxWidth)
            }
    }

    private func pushCursor() {
        guard !cursorPushed else { return }
        NSCursor.resizeLeftRight.push()
        cursorPushed = true
    }

    private func popCursor() {
        guard cursorPushed else { return }
        NSCursor.pop()
        cursorPushed = false
    }
}
