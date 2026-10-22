import KubeKit

extension LogViewModel {
    struct ContainerChoice: Hashable {
        let name: String
        let role: String?
    }

    /// Containers of a pod, including init and ephemeral ones.
    static func containers(of pod: Unstructured) -> [ContainerChoice] {
        let spec = pod.json["spec"]
        func names(_ key: String, role: String?) -> [ContainerChoice] {
            (spec?[key]?.arrayValue ?? []).compactMap { $0["name"]?.stringValue }.map { ContainerChoice(name: $0, role: role) }
        }
        return names("containers", role: nil) + names("initContainers", role: "init") + names("ephemeralContainers", role: "ephemeral")
    }
}
