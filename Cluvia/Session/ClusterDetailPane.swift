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
            case .failed where session.authFailure != nil:
                if let failure = session.authFailure {
                    ExecAuthFailureView(failure: failure, contextName: session.contextName) {
                        await session.retryAfterSignIn(using: catalog)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
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
        .navigationTitle(session.contextName)
        .focusedSceneValue(\.clusterSession, session)
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
