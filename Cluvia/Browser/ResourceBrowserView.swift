import KubeKit
import SwiftUI

/// Live table for one resource kind, with filter, namespace scope and the detail inspector.
struct ResourceBrowserView: View {
    @Bindable var session: ClusterSession
    let kind: ResourceKind
    /// One store per watched scope (all namespaces, or each selected namespace).
    @State private var stores: [ResourceStore<ResourceTableRow>] = []
    @State private var filter = ""
    @State private var showInspector = false

    private var scopes: [String?] {
        kind.namespaced ? session.watchNamespaces : [nil]
    }

    /// The namespace column is redundant only when exactly one namespace is shown.
    private var showNamespace: Bool {
        kind.namespaced && !(scopes.count == 1 && scopes[0] != nil)
    }

    private var columns: [ResourceTableColumn] {
        stores.first { !$0.columns.isEmpty }?.columns ?? []
    }

    /// The least healthy phase across scopes, which is what the user needs to know about.
    private var phase: ReflectorPhase? {
        let phases = stores.map(\.phase)
        return phases.first { if case .failed = $0 { true } else { false } }
            ?? phases.first { if case .reconnecting = $0 { true } else { false } }
            ?? phases.first { $0 == .connecting }
            ?? phases.first
    }

    private var visibleRows: [ResourceTableRow] {
        let all = stores.count == 1 ? stores[0].items : stores.flatMap(\.items)
        let query = RowFilter(filter)
        guard !query.isEmpty else { return all }
        let columns = columns
        return all.filter { query.matches($0, columns: columns) }
    }

    var body: some View {
        let rows = visibleRows
        ResourceTableView(
            columns: columns, rows: rows, showNamespace: showNamespace, selection: $session.selectedObject,
            actions: ResourceAction.available(for: kind)
        ) { action, row in
            session.request(action, kind: kind, key: row.id)
        }
            .overlay { overlay(rowCount: rows.count) }
            .safeAreaInset(edge: .bottom, spacing: 0) { phaseBanner }
            .inspector(isPresented: $showInspector) {
                Group {
                    if let key = session.selectedObject, let row = rows.first(where: { $0.id == key }) {
                        ResourceDetailView(session: session, kind: kind, row: row)
                            .id(row.id) // fresh model per object: never show the previous object's data or hide its error
                    } else {
                        ContentUnavailableView("No Selection", systemImage: "sidebar.right")
                    }
                }
                .inspectorColumnWidth(min: 320, ideal: 420, max: 700)
            }
            .searchable(text: $filter, placement: .toolbar, prompt: "Filter (name, label, status:running)")
            .toolbar {
                ToolbarItem {
                    Button { session.createResource(of: kind) } label: { Label("New \(kind.kind)", systemImage: "plus") }
                        .help("New \(kind.kind) from template")
                }
                ToolbarItem { if kind.namespaced { NamespacePicker(session: session) } }
                ToolbarItem {
                    Button { showInspector.toggle() } label: { Label("Details", systemImage: "sidebar.right") }
                        .keyboardShortcut("i", modifiers: [.command, .option])
                }
            }
            .navigationSubtitle("\(kind.title) · \(rows.count)")
            .onChange(of: session.selectedObject, initial: true) { _, selected in
                if selected != nil { showInspector = true }
            }
            .task(id: scopes) {
                guard let registry = session.registry else { return }
                let scopes = scopes
                stores = scopes.map { registry.acquire(kind.gvr, namespace: $0) }
                defer { scopes.forEach { registry.release(kind.gvr, namespace: $0) } }
                // Holds the watches until the view goes away or the scopes change.
                try? await Task.sleep(for: .seconds(1_000_000_000))
            }
    }

    @ViewBuilder
    private func overlay(rowCount: Int) -> some View {
        if rowCount == 0, let phase {
            switch phase {
            case .connecting:
                ProgressView()
            case let .failed(reason):
                ContentUnavailableView("Cannot List \(kind.title)", systemImage: "lock", description: Text(reason))
            default:
                ContentUnavailableView(filter.isEmpty ? "No \(kind.title)" : "No Matches", systemImage: "tray")
            }
        }
    }

    @ViewBuilder
    private var phaseBanner: some View {
        if case let .reconnecting(reason)? = phase {
            Label("Reconnecting — showing last known state. \(reason)", systemImage: "wifi.exclamationmark")
                .font(.callout)
                .lineLimit(1)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(6)
                .background(.orange.opacity(0.15))
        }
    }
}
