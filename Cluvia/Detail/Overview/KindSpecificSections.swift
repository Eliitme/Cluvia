import KubeKit
import SwiftUI

/// Extra overview sections for the kinds people inspect most. Fields are read straight from the object JSON.
struct KindSpecificSections: View {
    let object: Unstructured
    @Binding var revealSecrets: Bool
    /// Logs or shell for one container of a pod.
    var onContainerAction: (ResourceAction, String) -> Void = { _, _ in }

    var body: some View {
        switch object.kind {
        case "Pod": PodSection(json: object.json, onContainerAction: onContainerAction)
        case "Deployment", "StatefulSet", "DaemonSet", "ReplicaSet": WorkloadSection(json: object.json)
        case "Node": NodeSection(json: object.json)
        case "Service": ServiceSection(json: object.json)
        case "Secret", "ConfigMap": DataSection(json: object.json, secret: object.kind == "Secret", reveal: $revealSecrets)
        case "Ingress": IngressSection(json: object.json)
        case "PersistentVolumeClaim": ClaimSection(json: object.json)
        case "HorizontalPodAutoscaler": AutoscalerSection(json: object.json)
        default: EmptyView()
        }
    }
}

/// Display text of a JSON field, nil when absent or empty.
func jsonText(_ value: JSONValue?) -> String? {
    value.map(\.displayText).flatMap { $0.isEmpty ? nil : $0 }
}

struct PodSection: View {
    let json: JSONValue
    let onContainerAction: (ResourceAction, String) -> Void

    var body: some View {
        DetailSection("Pod") {
            DetailRow("Phase", value: jsonText(json[path: "status", "phase"]))
            DetailRow("Node", value: jsonText(json[path: "spec", "nodeName"]))
            DetailRow("Pod IP", value: jsonText(json[path: "status", "podIP"]))
            DetailRow("QoS Class", value: jsonText(json[path: "status", "qosClass"]))
            DetailRow("Service Account", value: jsonText(json[path: "spec", "serviceAccountName"]))
        }
        let statuses = json[path: "status", "containerStatuses"]?.arrayValue ?? []
        DetailSection("Containers") {
            ForEach(Array((json[path: "spec", "containers"]?.arrayValue ?? []).enumerated()), id: \.offset) { _, container in
                let name = container["name"]?.stringValue ?? "?"
                let status = statuses.first { $0["name"]?.stringValue == name }
                DetailRow(name) {
                    Text(container["image"]?.stringValue ?? "").font(.system(.callout, design: .monospaced)).textSelection(.enabled)
                    Text(Self.summary(status)).font(.caption).foregroundStyle(.secondary)
                    HStack {
                        Button("Logs") { onContainerAction(.logs, name) }
                        Button("Shell") { onContainerAction(.shell, name) }
                    }
                    .buttonStyle(.link)
                    .font(.caption)
                }
            }
        }
    }

    static func summary(_ status: JSONValue?) -> String {
        guard let status else { return "waiting for status" }
        let state = status["state"]?.objectValue?.keys.first ?? "unknown"
        let reason = status["state"]?.objectValue?.values.first?["reason"]?.stringValue
        let ready = status["ready"] == .bool(true) ? "ready" : "not ready"
        let restarts = status["restartCount"]?.intValue ?? 0
        return [state + (reason.map { " (\($0))" } ?? ""), ready, "\(restarts) restarts"].joined(separator: " · ")
    }
}

struct WorkloadSection: View {
    let json: JSONValue

    var body: some View {
        DetailSection("Replicas") {
            DetailRow("Desired", value: jsonText(json[path: "spec", "replicas"] ?? json[path: "status", "desiredNumberScheduled"]))
            DetailRow("Ready", value: jsonText(json[path: "status", "readyReplicas"] ?? json[path: "status", "numberReady"]) ?? "0")
            DetailRow("Updated", value: jsonText(json[path: "status", "updatedReplicas"] ?? json[path: "status", "updatedNumberScheduled"]))
            DetailRow("Available", value: jsonText(json[path: "status", "availableReplicas"] ?? json[path: "status", "numberAvailable"]))
            DetailRow("Strategy", value: jsonText(json[path: "spec", "strategy", "type"] ?? json[path: "spec", "updateStrategy", "type"]))
            DetailRow("Selector", value: json[path: "spec", "selector", "matchLabels"]?.objectValue.map {
                $0.map { "\($0.key)=\($0.value.displayText)" }.sorted().joined(separator: ", ")
            })
        }
    }
}

struct NodeSection: View {
    let json: JSONValue

    var body: some View {
        DetailSection("Node") {
            DetailRow("Kubelet", value: jsonText(json[path: "status", "nodeInfo", "kubeletVersion"]))
            DetailRow("OS Image", value: jsonText(json[path: "status", "nodeInfo", "osImage"]))
            DetailRow("Runtime", value: jsonText(json[path: "status", "nodeInfo", "containerRuntimeVersion"]))
            DetailRow("Addresses", value: (json[path: "status", "addresses"]?.arrayValue ?? []).compactMap {
                guard let type = $0["type"]?.stringValue, let address = $0["address"]?.stringValue else { return nil }
                return "\(type): \(address)"
            }.joined(separator: "\n"))
            ForEach(["cpu", "memory", "pods"], id: \.self) { resource in
                DetailRow(resource.capitalized, value: "\(jsonText(json[path: "status", "allocatable", resource]) ?? "?") allocatable of \(jsonText(json[path: "status", "capacity", resource]) ?? "?")")
            }
            DetailRow("Taints", value: (json[path: "spec", "taints"]?.arrayValue ?? []).map {
                "\(jsonText($0["key"]) ?? "")=\(jsonText($0["value"]) ?? ""):\(jsonText($0["effect"]) ?? "")"
            }.joined(separator: "\n"))
        }
    }
}

struct ServiceSection: View {
    let json: JSONValue

    var body: some View {
        DetailSection("Service") {
            DetailRow("Type", value: jsonText(json[path: "spec", "type"]))
            DetailRow("Cluster IP", value: jsonText(json[path: "spec", "clusterIP"]))
            DetailRow("Ports", value: (json[path: "spec", "ports"]?.arrayValue ?? []).map {
                let target = jsonText($0["targetPort"]).map { " → \($0)" } ?? ""
                return "\(jsonText($0["name"]).map { "\($0): " } ?? "")\(jsonText($0["port"]) ?? "")/\(jsonText($0["protocol"]) ?? "TCP")\(target)"
            }.joined(separator: "\n"))
            DetailRow("Selector", value: json[path: "spec", "selector"]?.objectValue.map {
                $0.map { "\($0.key)=\($0.value.displayText)" }.sorted().joined(separator: ", ")
            })
        }
    }
}
