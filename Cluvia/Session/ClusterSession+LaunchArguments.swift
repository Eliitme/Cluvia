import Foundation
import KubeKit

#if DEBUG
extension ClusterSession {
    /// Debug-only deep link used by automated UI checks: `-CluviaNamespace ns -CluviaKind pods -CluviaObject name -CluviaAction logs`.
    func applyLaunchArguments() {
        let defaults = UserDefaults.standard
        guard defaults.string(forKey: "CluviaOpenContext") == contextName else { return }
        if let namespaces = defaults.string(forKey: "CluviaNamespace") {
            selectedNamespaces = Set(namespaces.split(separator: ",").map(String.init))
        }
        if defaults.string(forKey: "CluviaKind") == "helm" {
            showingHelm = true
            helm.selection = defaults.string(forKey: "CluviaObject")
            return
        }
        if let resource = defaults.string(forKey: "CluviaKind"), let kind = kinds.first(where: { $0.gvr.resource == resource }) {
            selectedKind = kind
        }
        if let name = defaults.string(forKey: "CluviaObject") {
            let namespaced = selectedKind?.namespaced ?? true
            selectedObject = ObjectKey(namespace: namespaced ? selectedNamespaces.first : nil, name: name)
        }
        if let value = defaults.string(forKey: "CluviaAction") {
            if value == "palette" {
                showPalette = true
            } else if let action = ResourceAction(rawValue: value), let kind = selectedKind, let key = selectedObject {
                request(action, kind: kind, key: key)
            }
        }
    }
}
#endif
