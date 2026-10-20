import KubeKit
import SwiftUI

/// Main window sidebar: every kubeconfig context grouped by file (favorites first). Opened clusters expand into
/// their resource kinds.
struct WorkspaceSidebarView: View {
    @Environment(ClusterCatalogModel.self) private var catalog
    @Environment(AppSettingsStore.self) private var settings
    @State private var search = ""
    @State private var collapsed: Set<String> = []
    @State private var editing: ContextEditing?
    @State private var failure: String?

    private var visible: [ContextSummary] {
        search.isEmpty ? catalog.contexts : catalog.contexts.filter { $0.name.localizedCaseInsensitiveContains(search) }
    }

    /// Favorites, then one group per kubeconfig file; each context appears once.
    private var groups: [(title: String, contexts: [ContextSummary])] {
        let favorites = visible.filter { settings.isFavorite($0.name) }
        var result = favorites.isEmpty ? [] : [(title: "Favorites", contexts: favorites)]
        let others = visible.filter { !settings.isFavorite($0.name) }
        for file in catalog.files {
            let contexts = others.filter { catalog.contextSources[$0.name] == file }
            if !contexts.isEmpty { result.append((title: Self.displayPath(file), contexts: contexts)) }
        }
        return result
    }

    var body: some View {
        List(selection: selection) {
            ForEach(groups, id: \.title) { group in
                Section(group.title) {
                    ForEach(group.contexts) { context in
                        DisclosureGroup(isExpanded: expanded(context.name)) {
                            if let session = catalog.sessions[context.name] {
                                ClusterResourceTree(session: session)
                            }
                        } label: {
                            ContextRow(context: context)
                        }
                        .tag(SidebarItem.context(context.name))
                    }
                }
            }
        }
        .listStyle(.sidebar)
        // Selecting only selects; connecting is explicit (double-click, Return, expand or Connect), so moving through
        // the list never starts connections or credential-plugin sign-ins.
        .contextMenu(forSelectionType: SidebarItem.self) { items in
            if case let .context(name) = items.first, let context = catalog.contexts.first(where: { $0.name == name }) {
                ContextRowMenu(context: context, editing: $editing, failure: $failure)
            }
        } primaryAction: { items in
            if case let .context(name) = items.first { connect(name) }
        }
        .searchable(text: $search, placement: .sidebar, prompt: "Filter clusters")
        .safeAreaInset(edge: .bottom) { bottomBar }
        .modifier(ContextEditingModifier(editing: $editing, failure: $failure))
        .alert("Cannot Update Kubeconfig", isPresented: Binding(get: { failure != nil }, set: { if !$0 { failure = nil } })) {
            Button("OK") {}
        } message: {
            Text(failure ?? "")
        }
    }

    private var bottomBar: some View {
        HStack {
            Menu {
                Button("New Context…") { editing = .create }
                Button("Import from File…") { editing = .importFile }
                Button("Import from Clipboard…") { editing = .importPaste }
            } label: {
                Image(systemName: "plus")
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
            .accessibilityLabel("Add Context")
            .help("Add a context to \(catalog.primaryFile?.path ?? "the kubeconfig")")
            Spacer()
            if catalog.isLoading { ProgressView().controlSize(.small) }
            Button { Task { await catalog.reload() } } label: { Image(systemName: "arrow.clockwise") }
                .buttonStyle(.borderless)
                .help("Reload kubeconfig files")
                .accessibilityLabel("Reload Kubeconfig")
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        // Opaque, so rows scrolled underneath never show through the buttons.
        .background(.bar)
        .overlay(alignment: .top) { Divider() }
    }

    private var selection: Binding<SidebarItem?> {
        Binding {
            guard let name = catalog.selectedContext else { return nil }
            guard let session = catalog.sessions[name], session.state == .connected else { return .context(name) }
            if session.showingHelm { return .helm(name) }
            return session.selectedKind.map { .kind(name, $0) } ?? .context(name)
        } set: { item in
            switch item {
            case let .context(name):
                catalog.selectedContext = name
            case let .kind(name, kind):
                catalog.selectedContext = name
                // Set through the session, not the observed dictionary, so only this cluster's rows update.
                if let session = catalog.sessions[name] { session.selectedKind = kind }
            case let .helm(name):
                catalog.selectedContext = name
                if let session = catalog.sessions[name] { session.showingHelm = true }
            case nil:
                break
            }
        }
    }

    /// Open clusters are expanded unless collapsed by hand; expanding a closed one connects it.
    private func expanded(_ name: String) -> Binding<Bool> {
        Binding {
            catalog.sessions[name] != nil && !collapsed.contains(name)
        } set: { open in
            if open { connect(name) } else { collapsed.insert(name) }
        }
    }

    private func connect(_ name: String) {
        collapsed.remove(name)
        catalog.open(name, settings: settings)
    }

    static func displayPath(_ url: URL) -> String {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        return url.path.hasPrefix(home) ? "~" + url.path.dropFirst(home.count) : url.path
    }
}
