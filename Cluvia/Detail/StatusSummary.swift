import KubeKit
import SwiftUI

/// One-line health of an object for the inspector header, e.g. "Running · 1/1 ready" or "CrashLoopBackOff".
struct StatusSummary: Equatable {
    let text: String
    let tone: StatusTone

    init?(_ object: Unstructured) {
        let json = object.json
        let int = { (path: [String]) in path.reduce(Optional(json)) { $0?[$1] }?.intValue.map(Int.init) }
        var text: String?
        switch object.kind {
        case "Pod":
            let statuses = json[path: "status", "containerStatuses"]?.arrayValue ?? []
            let initStatuses = json[path: "status", "initContainerStatuses"]?.arrayValue ?? []
            let reasonOf = { (status: JSONValue) in status["state"]?.objectValue?.values.first?["reason"]?.stringValue }
            // A waiting/terminated reason (CrashLoopBackOff, ImagePullBackOff, OOMKilled) says more than the phase;
            // a stuck init container reads like kubectl's "Init:CrashLoopBackOff". A completed init container is fine.
            let initReason = initStatuses.lazy.compactMap(reasonOf).first { $0 != "Completed" }.map { "Init:\($0)" }
            let reason = initReason ?? statuses.lazy.compactMap(reasonOf).first
            let phase = json[path: "status", "phase"]?.stringValue
            let ready = statuses.filter { $0["ready"] == .bool(true) }.count
            text = [reason ?? phase, statuses.isEmpty ? nil : "\(ready)/\(statuses.count) ready"].compactMap { $0 }.joined(separator: " · ")
        case "Deployment", "StatefulSet", "ReplicaSet":
            let desired = int(["spec", "replicas"]) ?? 0
            text = "\(int(["status", "readyReplicas"]) ?? 0)/\(desired) ready"
        case "DaemonSet":
            text = "\(int(["status", "numberReady"]) ?? 0)/\(int(["status", "desiredNumberScheduled"]) ?? 0) ready"
        case "Job":
            text = "\(int(["status", "succeeded"]) ?? 0)/\(int(["spec", "completions"]) ?? 1) succeeded"
        case "PersistentVolumeClaim", "PersistentVolume", "Namespace":
            text = json[path: "status", "phase"]?.stringValue
        default:
            // Nodes and most custom resources report a Ready condition.
            let ready = json[path: "status", "conditions"]?.arrayValue?.first { $0["type"]?.stringValue == "Ready" }
            text = ready.flatMap { $0["status"]?.stringValue }.map { $0 == "True" ? "Ready" : "NotReady" }
        }
        guard let text, !text.isEmpty else { return nil }
        self.text = text
        let segments = text.components(separatedBy: " · ")
        // Counts like "0/2 ready" are healthy only when complete.
        let countsComplete = segments.allSatisfy { segment in
            guard let count = segment.split(separator: " ").first, count.contains("/") else { return true }
            let parts = count.split(separator: "/")
            return parts.count == 2 && parts[0] == parts[1]
        }
        let leadTone = segments[0].first?.isNumber == true ? StatusTone.good : StatusTone.of(segments[0], column: "status")
        let jobFailed = object.kind == "Job" && (json[path: "status", "conditions"]?.arrayValue ?? [])
            .contains { $0["type"]?.stringValue == "Failed" && $0["status"]?.stringValue == "True" }
        // "Running · 0/1 ready" is not healthy: a good lead with incomplete counts reads as pending.
        tone = jobFailed ? .bad : (leadTone == .good && !countsComplete ? .pending : leadTone)
    }
}

struct StatusBadge: View {
    let summary: StatusSummary

    var body: some View {
        Text(summary.text)
            .font(.caption.weight(.medium))
            .foregroundStyle(Color(nsColor: summary.tone.color))
            .padding(.horizontal, 7)
            .padding(.vertical, 2)
            .background(Color(nsColor: summary.tone.color).opacity(0.14), in: Capsule())
            .lineLimit(1)
    }
}
