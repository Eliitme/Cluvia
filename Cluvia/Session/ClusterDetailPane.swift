import KubeKit
import SwiftUI

/// Detail area for the selected cluster: its connection state, then the resource browser once connected.
struct ClusterDetailPane: View {
    let session: ClusterSession
    @Environment(ClusterCatalogModel.self) private var catalog

    var body: some View {
        Group {
            switch session.state {
            case .disconnected, .connecting:
                ProgressView("Connecting to \(session.contextName)…").frame(maxWidth: .infinity, maxHeight: .infinity)
            case let .failed(reason):
                ContentUnavailableView {
                    Label("Cannot Connect", systemImage: "exclamationmark.triangle")
                } description: {
                    Text(reason).textSelection(.enabled)
                } actions: {
                    Button("Retry") { Task { await catalog.connect(session) } }
                }
            case .connected:
                ClusterBrowserView(session: session)
            }
        }
        // Applied at the detail column's root so the toolbar gets its own section above the inspector.
        .inspector(isPresented: inspectorShown) {
            Group {
                if let row = session.inspectedRow, let kind = session.selectedKind, row.id == session.selectedObject {
                    ResourceDetailView(session: session, kind: kind, row: row)
                        .id(row.id) // fresh model per object: never show the previous object's data or hide its error
                } else {
                    ContentUnavailableView("No Selection", systemImage: "sidebar.right")
                }
            }
            .inspectorColumnWidth(min: 320, ideal: 420, max: 700)
        }
        .navigationTitle(session.contextName)
        .focusedSceneValue(\.clusterSession, session)
    }
}

extension ClusterDetailPane {
    /// Only resource tables have an inspector (not Helm, and not before connecting).
    private var inspectorShown: Binding<Bool> {
        Binding {
            session.showInspector && session.state == .connected && !session.showingHelm
        } set: { session.showInspector = $0 }
    }
}

struct ClusterSessionKey: FocusedValueKey {
    typealias Value = ClusterSession
}

extension FocusedValues {
    var clusterSession: ClusterSession? {
        get { self[ClusterSessionKey.self] }
        set { self[ClusterSessionKey.self] = newValue }
    }
}
