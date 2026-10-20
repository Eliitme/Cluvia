import KubeKit
import SwiftUI

/// Main window sidebar: every kubeconfig context grouped by file (favorites first). Opened clusters expand into
/// their resource kinds.
struct WorkspaceSidebarView: View {
    @Environment(ClusterCatalogModel.self) private var catalog
    @Environment(AppSettingsStore.self) private var settings
    @State private var search = ""
    /// Clusters showing their resource kinds; normally just the one in use.
    @State private var expanded: Set<String> = []
    @State private var editing: ContextEditing?
    @State private var failure: String?

    private var visible: [ContextSummary] {
        search.isEmpty ? catalog.contexts : catalog.contexts.filter { $0.name.localizedCaseInsensitiveContains(search) }
    }

    /// Favorites, then one group per kubeconfig file (titled by file name, path in the tooltip); each context
    /// appears once.
    private var groups: [(id: String, title: String, help: String?, contexts: [ContextSummary])] {
        let favorites = visible.filter { settings.isFavorite($0.name) }
        var result = favorites.isEmpty ? [] : [(id: "\u{0}favorites", title: "Favorites", help: String?.none, contexts: favorites)]
        let others = visible.filter { !settings.isFavorite($0.name) }
        for file in catalog.files {
            let contexts = others.filter { catalog.contextSources[$0.name] == file }
            if !contexts.isEmpty { result.append((id: file.path, title: file.lastPathComponent, help: Self.displayPath(file), contexts: contexts)) }
        }
        return result
    }

    var body: some View {
        List(selection: selection) {
            let groups = groups
            // A single kubeconfig file needs no heading.
            if groups.count == 1, let only = groups.first, only.help != nil {
                rows(only.contexts)
            } else {
                // Keyed by full path: two files may share a name (e.g. two "config"s).
                ForEach(groups, id: \.id) { group in
                    Section {
                        rows(group.contexts)
                    } header: {
                        Text(group.title).help(group.help ?? "")
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
        // Switching to a cluster that is open (selected in the palette, auto-connected, connected from its pane)
        // shows its kinds and folds the others.
        .onChange(of: focusKey, initial: true) {
            if let name = catalog.selectedContext, catalog.sessions[name] != nil { expanded = [name] }
        }
        .safeAreaInset(edge: .bottom) { bottomBar }
        .modifier(ContextEditingModifier(editing: $editing, failure: $failure))
        .alert("Cannot Update Kubeconfig", isPresented: Binding(get: { failure != nil }, set: { if !$0 { failure = nil } })) {
            Button("OK") {}
        } message: {
            Text(failure ?? "")
        }
    }

    private func rows(_ contexts: [ContextSummary]) -> some View {
        ForEach(SidebarRow.rows(for: contexts, sessions: catalog.sessions, expanded: expanded)) { row in
            if case let .context(context, open) = row {
                ContextRow(context: context, expanded: open, editing: $editing, failure: $failure) { toggle(context.name, open: open) }
                    .tag(SidebarItem.context(context.name))
            } else {
                SidebarChildRow(row: row)
            }
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

    private var focusKey: String {
        "\(catalog.selectedContext ?? "")|\(catalog.selectedContext.flatMap { catalog.sessions[$0] } != nil)"
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

    /// The chevron opens a cluster (connecting it if needed) or folds it away.
    private func toggle(_ name: String, open: Bool) {
        if open { expanded.remove(name) } else { connect(name) }
    }

    /// Opens a cluster and folds the others away, so the sidebar shows one cluster's kinds at a time.
    private func connect(_ name: String) {
        expanded = [name]
        catalog.open(name, settings: settings)
    }

    static func displayPath(_ url: URL) -> String {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        return url.path.hasPrefix(home) ? "~" + url.path.dropFirst(home.count) : url.path
    }
}
