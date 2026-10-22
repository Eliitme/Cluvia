import Foundation
import KubeKit

/// Deleting an object, optionally forced. When the uid is known every request is pinned to it, so an object
/// recreated under the same name (a StatefulSet pod, a GitOps-managed resource) is never deleted or stripped instead.
extension ClusterSession {
    struct DeleteChoice {
        var propagation = DynamicClient.PropagationPolicy.background
        /// Grace period 0: the API object goes away at once, the kubelet may still be stopping the containers.
        var skipGracePeriod = false
        var removeFinalizers = false
    }

    /// What a 409/422 meant, decided from a fresh read of the object.
    enum ConflictOutcome: Equatable {
        case gone, replaced, finalizersAlreadyRemoved, unresolved
    }

    /// Returns an error message for the sheet to show, or nil on success. `uid` is nil only when the object could not
    /// be read; the delete then goes by name and forcing is not offered.
    func delete(_ pending: PendingAction, uid: String?, choice: DeleteChoice) async -> String? {
        guard let client else { return "Not connected" }
        let gvr = pending.kind.gvr, key = pending.key
        var deleteSent = false
        do {
            do {
                try await client.delete(gvr, name: key.name, namespace: key.namespace, propagationPolicy: choice.propagation,
                                        gracePeriodSeconds: choice.skipGracePeriod ? 0 : nil, preconditionUID: uid)
            } catch let error as KubeAPIError where error.statusCode == 404 {
                return deleted(key)
            }
            deleteSent = true
            if choice.removeFinalizers, let uid {
                do {
                    _ = try await client.patch(gvr, name: key.name, namespace: key.namespace, type: .json,
                                               body: try DynamicClient.finalizerRemovalPatch(uid: uid))
                } catch let error as KubeAPIError where [404, 409, 422].contains(error.statusCode) {
                    throw error
                } catch {
                    // The object is terminating already; say so rather than look like nothing happened.
                    if selectedObject == key { selectedObject = nil }
                    return "Deleted, but its finalizers could not be removed: \(error.localizedDescription)"
                }
            }
            return deleted(key)
        } catch let error as KubeAPIError where error.statusCode == 404 {
            // The delete completed on its own between the two requests.
            return deleted(key)
        } catch let conflict as KubeAPIError where [409, 422].contains(conflict.statusCode) {
            let current: Unstructured?
            do {
                current = try await client.get(gvr, name: key.name, namespace: key.namespace)
            } catch let error as KubeAPIError where error.statusCode == 404 {
                current = nil
            } catch {
                return conflict.localizedDescription
            }
            switch Self.conflictOutcome(current: current, uid: uid, removeFinalizers: choice.removeFinalizers, deleteSent: deleteSent) {
            case .gone, .finalizersAlreadyRemoved: return deleted(key)
            case .replaced: return "Object was replaced by a new one with the same name; stopped."
            case .unresolved: return conflict.localizedDescription
            }
        } catch {
            return error.localizedDescription
        }
    }

    nonisolated static func conflictOutcome(current: Unstructured?, uid: String?, removeFinalizers: Bool, deleteSent: Bool) -> ConflictOutcome {
        guard let current else { return .gone }
        if let uid, current.uid != uid { return .replaced }
        // A controller cleared the finalizers before our patch arrived; only counts once our delete went through.
        if deleteSent, removeFinalizers, finalizers(of: current).isEmpty { return .finalizersAlreadyRemoved }
        return .unresolved
    }

    nonisolated static func finalizers(of object: Unstructured) -> [String] {
        (object.json[path: "metadata", "finalizers"]?.arrayValue ?? []).compactMap(\.stringValue)
    }

    private func deleted(_ key: ObjectKey) -> String? {
        if selectedObject == key { selectedObject = nil }
        return nil
    }
}
