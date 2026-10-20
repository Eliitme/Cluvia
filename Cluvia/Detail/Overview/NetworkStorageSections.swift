import KubeKit
import SwiftUI

struct IngressSection: View {
    let json: JSONValue

    var body: some View {
        DetailSection("Rules") {
            DetailRow("Class", value: jsonText(json[path: "spec", "ingressClassName"]))
            ForEach(Array((json[path: "spec", "rules"]?.arrayValue ?? []).enumerated()), id: \.offset) { _, rule in
                DetailRow(jsonText(rule["host"]) ?? "*") {
                    ForEach(Array((rule[path: "http", "paths"]?.arrayValue ?? []).enumerated()), id: \.offset) { _, path in
                        let service = path[path: "backend", "service"]
                        let port = jsonText(service?[path: "port", "number"]) ?? jsonText(service?[path: "port", "name"]) ?? "?"
                        Text("\(jsonText(path["path"]) ?? "/") → \(jsonText(service?["name"]) ?? "?"):\(port)")
                            .font(.system(.callout, design: .monospaced)).textSelection(.enabled)
                    }
                }
            }
            DetailRow("TLS", value: (json[path: "spec", "tls"]?.arrayValue ?? []).flatMap { ($0["hosts"]?.arrayValue ?? []).compactMap(\.stringValue) }.joined(separator: ", "))
        }
    }
}

struct ClaimSection: View {
    let json: JSONValue

    var body: some View {
        DetailSection("Claim") {
            DetailRow("Status", value: jsonText(json[path: "status", "phase"]))
            DetailRow("Requested", value: jsonText(json[path: "spec", "resources", "requests", "storage"]))
            DetailRow("Capacity", value: jsonText(json[path: "status", "capacity", "storage"]))
            DetailRow("Storage Class", value: jsonText(json[path: "spec", "storageClassName"]))
            DetailRow("Access Modes", value: (json[path: "spec", "accessModes"]?.arrayValue ?? []).compactMap(\.stringValue).joined(separator: ", "))
            DetailRow("Volume", value: jsonText(json[path: "spec", "volumeName"]))
        }
    }
}

struct AutoscalerSection: View {
    let json: JSONValue

    var body: some View {
        DetailSection("Autoscaling") {
            DetailRow("Target", value: [jsonText(json[path: "spec", "scaleTargetRef", "kind"]), jsonText(json[path: "spec", "scaleTargetRef", "name"])]
                .compactMap { $0 }.joined(separator: "/"))
            DetailRow("Replicas", value: "\(jsonText(json[path: "status", "currentReplicas"]) ?? "?") current · min \(jsonText(json[path: "spec", "minReplicas"]) ?? "1") · max \(jsonText(json[path: "spec", "maxReplicas"]) ?? "?")")
            ForEach(Array((json[path: "status", "currentMetrics"]?.arrayValue ?? []).enumerated()), id: \.offset) { _, metric in
                let resource = metric["resource"]
                DetailRow(jsonText(resource?["name"]) ?? jsonText(metric["type"]) ?? "metric",
                          value: jsonText(resource?[path: "current", "averageUtilization"]).map { "\($0)%" } ?? jsonText(resource?[path: "current", "averageValue"]))
            }
        }
    }
}
