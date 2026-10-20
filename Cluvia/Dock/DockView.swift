import SwiftUI

struct DockView: View {
    @Bindable var dock: DockModel
    let portForwards: PortForwardManager

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 2) {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 2) {
                        ForEach(dock.tabs) { tab in
                            DockTabButton(title: tab.title, symbol: tab.symbol, selected: dock.selectedTab == tab.id) {
                                dock.selectedTab = tab.id
                            } onClose: {
                                dock.close(tab.id)
                            }
                        }
                    }
                }
                Button { dock.isVisible = false } label: { Image(systemName: "chevron.down") }
                    .buttonStyle(.borderless)
                    .help("Hide Panel")
            }
            .padding(.horizontal, 6)
            .padding(.vertical, 3)
            .background(.bar)
            Divider()
            if let tab = dock.tabs.first(where: { $0.id == dock.selectedTab }) {
                switch tab.content {
                case let .logs(model): LogView(model: model).id(tab.id)
                case let .terminal(model): TerminalTabView(model: model).id(tab.id)
                case .portForwards: PortForwardListView(manager: portForwards)
                }
            } else {
                ContentUnavailableView("Nothing Open", systemImage: "rectangle.bottomhalf.inset.filled")
            }
        }
        // Tabs stay at the top and the content fills the rest, whatever the content's own preferred height.
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    }
}

private struct DockTabButton: View {
    let title: String
    let symbol: String
    let selected: Bool
    let action: () -> Void
    let onClose: () -> Void

    var body: some View {
        HStack(spacing: 4) {
            Image(systemName: symbol).font(.caption)
            Text(title).lineLimit(1)
            Button(action: onClose) { Image(systemName: "xmark").font(.caption2) }
                .buttonStyle(.borderless)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 3)
        .background(selected ? Color.accentColor.opacity(0.2) : .clear, in: RoundedRectangle(cornerRadius: 5))
        .contentShape(Rectangle())
        .onTapGesture(perform: action)
    }
}
