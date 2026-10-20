import KubeKit
import SwiftUI

/// Cmd+K: fuzzy search over kinds, namespaces, clusters, loaded objects and actions on the selection.
struct CommandPaletteView: View {
    let session: ClusterSession
    @Environment(ClusterCatalogModel.self) private var catalog
    @Environment(\.dismiss) private var dismiss
    @State private var query = ""
    @State private var selection: PaletteItem.ID?
    @State private var allItems: [PaletteItem] = []
    /// Objects of any kind matching the query by name, found asynchronously.
    @State private var remoteItems: [PaletteItem] = []
    @FocusState private var focused: Bool

    private var results: [PaletteItem] {
        let local = CommandPaletteIndex.search(query, in: allItems)
        let seen = Set(local.map(\.id))
        return local + remoteItems.filter { !seen.contains($0.id) }
    }

    var body: some View {
        let results = results
        VStack(spacing: 0) {
            TextField("Search kinds, namespaces, objects, actions…", text: $query)
                .textFieldStyle(.plain)
                .font(.title3)
                .padding(12)
                .focused($focused)
                .onSubmit { run(results.first { $0.id == selection } ?? results.first) }
                .onKeyPress(.downArrow) { move(1, in: results); return .handled }
                .onKeyPress(.upArrow) { move(-1, in: results); return .handled }
            Divider()
            List(results, selection: $selection) { item in
                HStack {
                    Image(systemName: item.symbol).frame(width: 20).foregroundStyle(.secondary)
                    Text(item.title).lineLimit(1)
                    Spacer()
                    Text(item.subtitle).foregroundStyle(.secondary).lineLimit(1)
                }
                .tag(item.id)
                .contentShape(Rectangle())
                .onTapGesture(count: 2) { run(item) }
            }
            .listStyle(.plain)
        }
        .frame(width: 620, height: 420)
        .onAppear {
            allItems = CommandPaletteIndex.items(session: session, contexts: catalog.contexts.map(\.name))
            focused = true
            #if DEBUG
            if let preset = UserDefaults.standard.string(forKey: "CluviaPaletteQuery") { query = preset }
            #endif
        }
        .onChange(of: query) { selection = results.first?.id }
        .task(id: query) {
            try? await Task.sleep(for: .milliseconds(250))
            guard !Task.isCancelled else { return }
            let found = await session.searchIndex.search(query, session: session)
            guard !Task.isCancelled else { return }
            remoteItems = found.map { kind, key in
                PaletteItem(id: "obj:\(kind.gvr):\(key)", title: key.name, subtitle: "\(kind.kind)\(key.namespace.map { " · \($0)" } ?? "")",
                            symbol: "magnifyingglass", command: .reveal(kind, key))
            }
        }
        .onExitCommand { dismiss() }
    }

    private func move(_ offset: Int, in results: [PaletteItem]) {
        guard !results.isEmpty else { return }
        let current = results.firstIndex { $0.id == selection } ?? -1
        selection = results[min(max(current + offset, 0), results.count - 1)].id
    }

    private func run(_ item: PaletteItem?) {
        guard let item else { return }
        session.paletteCommand = item.command
        dismiss()
    }
}
