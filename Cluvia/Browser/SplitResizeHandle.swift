import AppKit
import SwiftUI

/// Divider the user drags to size the panel beside or below it. The panel is on the trailing/bottom side, so
/// dragging toward the content grows it.
struct SplitResizeHandle: View {
    let axis: Axis
    /// Panel size shown now, and the range the drag may set.
    let current: Double
    let range: ClosedRange<Double>
    let label: String
    let onResize: (Double) -> Void
    @State private var dragStart: Double?
    @State private var cursorPushed = false

    var body: some View {
        Divider()
            .overlay {
                Color.clear
                    .frame(width: axis == .horizontal ? 8 : nil, height: axis == .vertical ? 8 : nil)
                    .contentShape(Rectangle())
                    .onHover { inside in
                        // While dragging the pointer may leave the strip; keep the resize cursor until the drag ends.
                        if inside { pushCursor() } else if dragStart == nil { popCursor() }
                    }
                    .onDisappear { popCursor() }
                    // Global coordinates: the handle itself moves as the size changes, which would skew local ones.
                    .gesture(
                        DragGesture(minimumDistance: 1, coordinateSpace: .global)
                            .onChanged { drag in
                                let start = dragStart ?? current
                                dragStart = start
                                let delta = axis == .horizontal ? drag.translation.width : drag.translation.height
                                onResize(min(max(start - delta, range.lowerBound), range.upperBound))
                            }
                            .onEnded { _ in
                                dragStart = nil
                                popCursor()
                            }
                    )
            }
            .accessibilityElement()
            .accessibilityLabel(label)
            .accessibilityValue("\(Int(current)) points")
            .accessibilityAdjustableAction { direction in
                onResize(min(max(current + (direction == .increment ? 40 : -40), range.lowerBound), range.upperBound))
            }
    }

    private func pushCursor() {
        guard !cursorPushed else { return }
        (axis == .horizontal ? NSCursor.resizeLeftRight : NSCursor.resizeUpDown).push()
        cursorPushed = true
    }

    private func popCursor() {
        guard cursorPushed else { return }
        NSCursor.pop()
        cursorPushed = false
    }
}
