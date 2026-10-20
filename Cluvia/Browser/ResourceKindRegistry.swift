import Foundation
import KubeKit

enum ResourceCategory: String, CaseIterable, Identifiable {
    case cluster = "Cluster"
    case workloads = "Workloads"
    case config = "Config"
    case network = "Network"
    case storage = "Storage"
    case accessControl = "Access Control"
    case other = "Other"
    case customResources = "Custom Resources"

    var id: String { rawValue }

    var symbol: String {
        switch self {
        case .cluster: "server.rack"
        case .workloads: "shippingbox"
        case .config: "slider.horizontal.3"
        case .network: "network"
        case .storage: "externaldrive"
        case .accessControl: "lock.shield"
        case .other: "ellipsis.circle"
        case .customResources: "puzzlepiece.extension"
        }
    }
}

/// A browsable resource type as it is actually served by the connected cluster.
struct ResourceKind: Hashable, Identifiable {
    let gvr: GroupVersionResource
    let kind: String
    let title: String
    let namespaced: Bool
    let category: ResourceCategory

    var id: GroupVersionResource { gvr }
}

/// Maps discovery results onto sidebar categories. Curated built-in kinds appear in a fixed order when served;
/// remaining upstream Kubernetes resources go to Other, and everything else (CRDs, aggregated APIs) to
/// Custom Resources, including CRDs in `*.k8s.io` groups such as the Gateway API.
enum ResourceKindRegistry {
    struct BuiltIn {
        let category: ResourceCategory
        let group: String
        let resource: String
        let title: String
    }

    static let builtIns: [BuiltIn] = [
        .init(category: .cluster, group: "", resource: "nodes", title: "Nodes"),
        .init(category: .cluster, group: "", resource: "namespaces", title: "Namespaces"),
        .init(category: .cluster, group: "", resource: "events", title: "Events"),
        .init(category: .workloads, group: "", resource: "pods", title: "Pods"),
        .init(category: .workloads, group: "apps", resource: "deployments", title: "Deployments"),
        .init(category: .workloads, group: "apps", resource: "statefulsets", title: "StatefulSets"),
        .init(category: .workloads, group: "apps", resource: "daemonsets", title: "DaemonSets"),
        .init(category: .workloads, group: "apps", resource: "replicasets", title: "ReplicaSets"),
        .init(category: .workloads, group: "batch", resource: "jobs", title: "Jobs"),
        .init(category: .workloads, group: "batch", resource: "cronjobs", title: "CronJobs"),
        .init(category: .config, group: "", resource: "configmaps", title: "ConfigMaps"),
        .init(category: .config, group: "", resource: "secrets", title: "Secrets"),
        .init(category: .config, group: "", resource: "resourcequotas", title: "Resource Quotas"),
        .init(category: .config, group: "", resource: "limitranges", title: "Limit Ranges"),
        .init(category: .config, group: "autoscaling", resource: "horizontalpodautoscalers", title: "HPA"),
        .init(category: .config, group: "policy", resource: "poddisruptionbudgets", title: "Pod Disruption Budgets"),
        .init(category: .config, group: "scheduling.k8s.io", resource: "priorityclasses", title: "Priority Classes"),
        .init(category: .network, group: "", resource: "services", title: "Services"),
        .init(category: .network, group: "discovery.k8s.io", resource: "endpointslices", title: "Endpoint Slices"),
        .init(category: .network, group: "networking.k8s.io", resource: "ingresses", title: "Ingresses"),
        .init(category: .network, group: "networking.k8s.io", resource: "ingressclasses", title: "Ingress Classes"),
        .init(category: .network, group: "networking.k8s.io", resource: "networkpolicies", title: "Network Policies"),
        .init(category: .storage, group: "", resource: "persistentvolumeclaims", title: "Persistent Volume Claims"),
        .init(category: .storage, group: "", resource: "persistentvolumes", title: "Persistent Volumes"),
        .init(category: .storage, group: "storage.k8s.io", resource: "storageclasses", title: "Storage Classes"),
        .init(category: .accessControl, group: "", resource: "serviceaccounts", title: "Service Accounts"),
        .init(category: .accessControl, group: "rbac.authorization.k8s.io", resource: "roles", title: "Roles"),
        .init(category: .accessControl, group: "rbac.authorization.k8s.io", resource: "rolebindings", title: "Role Bindings"),
        .init(category: .accessControl, group: "rbac.authorization.k8s.io", resource: "clusterroles", title: "Cluster Roles"),
        .init(category: .accessControl, group: "rbac.authorization.k8s.io", resource: "clusterrolebindings", title: "Cluster Role Bindings"),
    ]

    /// API groups served by kube-apiserver itself.
    static let upstreamGroups: Set<String> = [
        "", "apps", "batch", "autoscaling", "policy",
        "admissionregistration.k8s.io", "apiextensions.k8s.io", "apiregistration.k8s.io", "authentication.k8s.io",
        "authorization.k8s.io", "certificates.k8s.io", "coordination.k8s.io", "discovery.k8s.io", "events.k8s.io",
        "flowcontrol.apiserver.k8s.io", "internal.apiserver.k8s.io", "networking.k8s.io", "node.k8s.io",
        "rbac.authorization.k8s.io", "resource.k8s.io", "scheduling.k8s.io", "storage.k8s.io", "storagemigration.k8s.io",
    ]

    /// `events.k8s.io` serves the same objects as core Events, which are already listed.
    static let duplicateGroups: Set<String> = ["events.k8s.io"]

    static func kinds(from catalog: APIResourceCatalog) -> [ResourceKind] {
        let preferred = catalog.preferred.filter { $0.isListable && $0.isWatchable }
        let builtIn = builtIns.compactMap { entry -> ResourceKind? in
            guard let info = preferred.first(where: { $0.gvr.group == entry.group && $0.gvr.resource == entry.resource }) else {
                return nil
            }
            return ResourceKind(gvr: info.gvr, kind: info.kind, title: entry.title, namespaced: info.namespaced, category: entry.category)
        }
        let listed = Set(builtIn.map(\.gvr))
        let rest = preferred
            .filter { !listed.contains($0.gvr) && !duplicateGroups.contains($0.gvr.group) }
            .sorted { ($0.gvr.group, $0.kind) < ($1.gvr.group, $1.kind) }
            .map { info in
                ResourceKind(
                    gvr: info.gvr, kind: info.kind, title: info.kind, namespaced: info.namespaced,
                    category: upstreamGroups.contains(info.gvr.group) ? .other : .customResources
                )
            }
        return builtIn + rest
    }
}
