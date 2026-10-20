import SwiftUI

struct DockView: View {
    @Bindable var dock: DockModel

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 2) {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 2) {
                        ForEach(dock.logTabs) { tab in
                            DockTabButton(title: tab.title, selected: dock.selectedTab == tab.id) {
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
            if let tab = dock.logTabs.first(where: { $0.id == dock.selectedTab }) {
                LogView(model: tab).id(tab.id)
            } else {
                ContentUnavailableView("No Logs Open", systemImage: "text.alignleft")
            }
        }
    }
}

private struct DockTabButton: View {
    let title: String
    let selected: Bool
    let action: () -> Void
    let onClose: () -> Void

    var body: some View {
        HStack(spacing: 4) {
            Image(systemName: "text.alignleft").font(.caption)
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
