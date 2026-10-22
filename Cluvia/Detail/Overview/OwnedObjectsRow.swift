import KubeKit
import SwiftUI

/// "Controls" row of the overview: links to the objects this one owns, the reverse of "Controlled By".
struct OwnedObjectsRow: View {
    static let shownLimit = 20

    let session: ClusterSession
    let object: Unstructured
    @State private var children: [Unstructured]?
    @State private var failed = false
    @State private var refreshes = 0

    /// Child kind (name, apiVersion) for controllers whose children are worth listing; group-checked so a CRD
    /// that happens to be called "Deployment" gets none.
    nonisolated static func childKind(ofKind kind: String?, apiVersion: String?) -> (kind: String, apiVersion: String)? {
        switch (apiVersion, kind) {
        case ("apps/v1", "Deployment"): ("ReplicaSet", "apps/v1")
        case ("apps/v1", "ReplicaSet"), ("apps/v1", "StatefulSet"), ("apps/v1", "DaemonSet"), ("batch/v1", "Job"): ("Pod", "v1")
        case ("batch/v1", "CronJob"): ("Job", "batch/v1")
        default: nil
        }
    }

    /// Changes when the set of children may have: a new spec (generation), replicas or pods replaced, jobs started.
    /// Not the resourceVersion, which moves many times a second during a rollout.
    nonisolated static func reloadKey(of object: Unstructured) -> String {
        let status = object.json["status"]
        let parts: [String?] = [
            object.uid, object.json[path: "metadata", "generation"]?.displayText,
            status?["replicas"]?.displayText, status?["readyReplicas"]?.displayText, status?["currentNumberScheduled"]?.displayText,
            status?["active"]?.displayText, status?["succeeded"]?.displayText, status?["failed"]?.displayText,
            status?["lastScheduleTime"]?.displayText,
        ]
        return parts.map { $0 ?? "" }.joined(separator: "#")
    }

    var body: some View {
        if !failed, let child = Self.childKind(ofKind: object.kind, apiVersion: object.apiVersion),
           let childKind = session.kind(named: child.kind, apiVersion: child.apiVersion) {
            DetailRow("Controls") {
                if let children {
                    if children.isEmpty { Text("No \(childKind.title)").foregroundStyle(.secondary) }
                    ForEach(children.prefix(Self.shownLimit), id: \.uid) { item in
                        Button("\(child.kind)/\(item.name)") { session.reveal(childKind, item.key) }
                            .buttonStyle(.link)
                    }
                    if children.count > Self.shownLimit {
                        Text("and \(children.count - Self.shownLimit) more").foregroundStyle(.secondary)
                    }
                } else {
                    ProgressView().controlSize(.small)
                }
                Button("Refresh") { refreshes += 1 }.buttonStyle(.link).font(.caption)
            }
            .task(id: "\(Self.reloadKey(of: object))#\(refreshes)") { await load(childKind) }
        }
    }

    private func load(_ childKind: ResourceKind) async {
        guard let client = session.client else { failed = true; return }
        do {
            let listed = try await OwnedObjects.list(client: client, child: childKind.gvr, parent: object)
            guard !Task.isCancelled else { return }
            children = listed
        } catch {
            // No permission to list the children, for example: leave the row out rather than claim there are none.
            guard !Task.isCancelled else { return }
            failed = true
        }
    }
}
