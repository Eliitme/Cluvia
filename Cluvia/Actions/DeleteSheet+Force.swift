import KubeKit
import SwiftUI

/// When forcing is offered and what each finalizer protects.
enum ForceDelete {
    static func isPod(_ kind: ResourceKind) -> Bool { kind.gvr.group.isEmpty && kind.kind == "Pod" }

    static func isCRD(_ kind: ResourceKind) -> Bool {
        kind.gvr.group == "apiextensions.k8s.io" && kind.kind == "CustomResourceDefinition"
    }

    /// Pods (grace period) and objects already terminating (stuck on finalizers). Healthy objects never show it.
    static func isOffered(kind: ResourceKind, object: Unstructured) -> Bool {
        isPod(kind) || object.json[path: "metadata", "deletionTimestamp"] != nil
    }

    /// What removing this finalizer skips; `severe` marks possible data loss.
    static func consequence(of finalizer: String) -> (text: String, severe: Bool) {
        switch finalizer {
        case "kubernetes.io/pv-protection", "kubernetes.io/pvc-protection":
            ("The volume may still be in use; data loss is possible.", true)
        case "foregroundDeletion", "orphan":
            ("Garbage collection of dependents is skipped; they may be left behind.", false)
        default:
            ("Added by a controller; its cleanup (volumes, load balancers, external resources) is skipped.", false)
        }
    }

    static func isControlledByStatefulSet(_ object: Unstructured) -> Bool {
        object.ownerReferences.contains { $0.controller && $0.kind == "StatefulSet" }
    }
}

struct ForceDeleteSection: View {
    let kind: ResourceKind
    let object: Unstructured
    @Binding var choice: ClusterSession.DeleteChoice
    @Binding var typedName: String

    var body: some View {
        Divider()
        Text("Force").font(.headline)
        if ForceDelete.isPod(kind) {
            Toggle("Skip grace period", isOn: $choice.skipGracePeriod)
            Text("Skips graceful shutdown. The kubelet may still be running the containers.")
                .font(.callout).foregroundStyle(.secondary)
            if choice.skipGracePeriod, ForceDelete.isControlledByStatefulSet(object) {
                Label("The StatefulSet recreates a pod with the same name while the old one may still be running.",
                      systemImage: "exclamationmark.triangle")
                    .font(.callout).foregroundStyle(.orange)
            }
        }
        finalizerControls
        if choice.skipGracePeriod || choice.removeFinalizers {
            TextField("Type \(object.name) to confirm", text: $typedName)
                .textFieldStyle(.roundedBorder)
        }
    }

    @ViewBuilder private var finalizerControls: some View {
        let finalizers = ClusterSession.finalizers(of: object)
        if !finalizers.isEmpty {
            if ForceDelete.isCRD(kind) {
                Label("Removing a CRD's finalizer orphans its stored objects, so it is not offered.", systemImage: "nosign")
                    .font(.callout).foregroundStyle(.secondary)
            } else {
                Toggle("Remove finalizers", isOn: $choice.removeFinalizers)
                ForEach(finalizers, id: \.self) { finalizer in
                    let consequence = ForceDelete.consequence(of: finalizer)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(finalizer).font(.callout.monospaced())
                        Text(consequence.text).font(.callout).foregroundStyle(consequence.severe ? .red : .secondary)
                    }
                    .textSelection(.enabled)
                }
            }
        }
    }
}
