import SwiftUI

/// Actions for the inspected object. Buttons show titles when the panel is wide enough and collapse to icons
/// otherwise; Delete stands apart, in red, so it is never mistaken for a neighbor.
struct ResourceActionBar: View {
    let kind: ResourceKind
    let actions: [ResourceAction]
    let perform: (ResourceAction) -> Void

    var body: some View {
        ViewThatFits(in: .horizontal) {
            bar(titled: true)
            bar(titled: false)
        }
        .controlSize(.small)
    }

    private func bar(titled: Bool) -> some View {
        HStack(spacing: 4) {
            ForEach(actions.filter { $0 != .delete }) { button($0, titled: titled) }
            Spacer(minLength: 12)
            if actions.contains(.delete) {
                // Icon only: red and set apart, it reads as Delete without a title, leaving room for the others'.
                button(.delete, titled: false).foregroundStyle(.red)
            }
        }
    }

    private func button(_ action: ResourceAction, titled: Bool) -> some View {
        Button { perform(action) } label: {
            Label(action.shortTitle(for: kind), systemImage: action.symbol)
                .labelStyle(TitledLabelStyle(titled: titled))
        }
        .help(action.helpText)
        .accessibilityLabel(action.title(for: kind))
    }
}

private struct TitledLabelStyle: LabelStyle {
    let titled: Bool

    func makeBody(configuration: Configuration) -> some View {
        HStack(spacing: 3) {
            configuration.icon
            if titled { configuration.title }
        }
        .fixedSize()
    }
}
