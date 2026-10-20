import Foundation

/// Converts discovery documents into `APIResourceInfo`. Subresources (`pods/log`) are excluded.
enum DiscoveryDecoding {
    /// `APIGroupDiscoveryList`: versions are listed in preference order, so the first one is preferred.
    static func aggregated(_ list: JSONValue) -> [APIResourceInfo] {
        var resources: [APIResourceInfo] = []
        for group in list["items"]?.arrayValue ?? [] {
            let groupName = group[path: "metadata", "name"]?.stringValue ?? ""
            for (index, version) in (group["versions"]?.arrayValue ?? []).enumerated() {
                guard let versionName = version["version"]?.stringValue else { continue }
                for resource in version["resources"]?.arrayValue ?? [] {
                    guard let name = resource["resource"]?.stringValue,
                          let kind = resource[path: "responseKind", "kind"]?.stringValue else { continue }
                    resources.append(APIResourceInfo(
                        gvr: GroupVersionResource(group: groupName, version: versionName, resource: name),
                        kind: kind,
                        namespaced: resource["scope"]?.stringValue == "Namespaced",
                        verbs: strings(resource["verbs"]),
                        shortNames: Array(strings(resource["shortNames"])).sorted(),
                        preferred: index == 0
                    ))
                }
            }
        }
        return resources
    }

    /// `APIResourceList` for one group-version.
    static func legacy(_ list: JSONValue, group: String, version: String, preferred: Bool) -> [APIResourceInfo] {
        (list["resources"]?.arrayValue ?? []).compactMap { resource in
            guard let name = resource["name"]?.stringValue, !name.contains("/"),
                  let kind = resource["kind"]?.stringValue else { return nil }
            return APIResourceInfo(
                gvr: GroupVersionResource(group: group, version: version, resource: name),
                kind: kind,
                namespaced: resource["namespaced"] == .bool(true),
                verbs: strings(resource["verbs"]),
                shortNames: Array(strings(resource["shortNames"])).sorted(),
                preferred: preferred
            )
        }
    }

    private static func strings(_ value: JSONValue?) -> Set<String> {
        Set((value?.arrayValue ?? []).compactMap(\.stringValue))
    }
}
