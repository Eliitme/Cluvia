import Foundation

public struct DrainOptions: Sendable {
    public var ignoreDaemonSets = true
    /// Evict pods using emptyDir volumes; their data is lost.
    public var deleteEmptyDirData = false
    /// Evict pods without a controller; they are not recreated anywhere.
    public var force = false
    public var gracePeriodSeconds: Int?
    public var timeout: Duration = .seconds(300)
    /// Only drain pods matching this label selector (like `kubectl drain --pod-selector`).
    public var podSelector: String?

    public init() {}
}

public enum DrainEvent: Sendable, Equatable {
    case cordoned
    case skipped(ObjectKey, reason: String)
    /// Not evicted, and won't be without changing options (unmanaged pod, local storage).
    case refused(ObjectKey, reason: String)
    /// Eviction rejected for now, typically by a PodDisruptionBudget; retried until the timeout.
    case blocked(ObjectKey, reason: String)
    case evicted(ObjectKey)
    /// `remaining`: evicted pods still running when the timeout passed. `refused`: pods not evicted at all.
    case finished(remaining: [ObjectKey], refused: [ObjectKey])
}

/// `kubectl drain` semantics over the Eviction API: cordon, then evict pods, respecting PodDisruptionBudgets.
public struct NodeDrainer: Sendable {
    static let retryInterval: Duration = .seconds(5)
    public let client: DynamicClient

    public init(client: DynamicClient) {
        self.client = client
    }

    public func drain(node: String, options: DrainOptions) -> AsyncThrowingStream<DrainEvent, Error> {
        let client = client
        return AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    try await ResourceActionsCore.setUnschedulable(client, node: node, true)
                    continuation.yield(.cordoned)
                    let pods = try await client.list(.pods, options: ListOptions(
                        labelSelector: options.podSelector, fieldSelector: "spec.nodeName=\(node)"
                    )).items
                    var pending: [Unstructured] = []
                    var refused: [ObjectKey] = []
                    for pod in pods {
                        switch Self.classify(pod, options: options) {
                        case let .skip(reason): continuation.yield(.skipped(pod.key, reason: reason))
                        case let .refuse(reason):
                            refused.append(pod.key)
                            continuation.yield(.refused(pod.key, reason: reason))
                        case .evict: pending.append(pod)
                        }
                    }
                    let remaining = try await evict(pending, node: node, options: options) { continuation.yield($0) }
                    continuation.yield(.finished(remaining: remaining, refused: refused))
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    enum Decision: Equatable {
        case evict
        case skip(String)
        case refuse(String)
    }

    static func classify(_ pod: Unstructured, options: DrainOptions) -> Decision {
        if pod.annotations["kubernetes.io/config.mirror"] != nil { return .skip("static pod managed by the kubelet") }
        let controller = pod.ownerReferences.first { $0.controller }
        if controller?.kind == "DaemonSet" {
            return options.ignoreDaemonSets ? .skip("managed by a DaemonSet") : .refuse("managed by a DaemonSet")
        }
        let phase = pod.json[path: "status", "phase"]?.stringValue
        let finished = phase == "Succeeded" || phase == "Failed"
        if controller == nil, !finished, !options.force { return .refuse("not managed by a controller (use force)") }
        let usesEmptyDir = (pod.json[path: "spec", "volumes"]?.arrayValue ?? []).contains { $0["emptyDir"] != nil }
        if usesEmptyDir, !finished, !options.deleteEmptyDirData { return .refuse("uses emptyDir storage (allow deleting local data)") }
        return .evict
    }

    /// Evicts until every pod is gone or the timeout passes; returns pods still present.
    private func evict(_ pods: [Unstructured], node: String, options: DrainOptions, report: (DrainEvent) -> Void) async throws -> [ObjectKey] {
        let uids = Dictionary(pods.map { ($0.key, $0.uid) }, uniquingKeysWith: { first, _ in first })
        let clock = ContinuousClock()
        let deadline = clock.now + options.timeout
        var waiting = pods.map(\.key)
        var reportedBlocked = Set<ObjectKey>()
        var evicted = Set<ObjectKey>()
        while !waiting.isEmpty, clock.now < deadline {
            for key in waiting where !evicted.contains(key) {
                do {
                    try await requestEviction(key, gracePeriod: options.gracePeriodSeconds)
                    evicted.insert(key)
                    report(.evicted(key))
                } catch let error as KubeAPIError where error.statusCode == 429 {
                    if reportedBlocked.insert(key).inserted { report(.blocked(key, reason: error.message)) }
                } catch let error as KubeAPIError where error.statusCode == 404 {
                    evicted.insert(key)
                }
            }
            // An evicted pod counts as drained once it is actually gone. StatefulSets recreate pods under the
            // same name, so a pod with another UID or on another node is a replacement, not the evicted pod.
            var stillPresent: [ObjectKey] = []
            for key in waiting {
                do {
                    let current = try await client.get(.pods, name: key.name, namespace: key.namespace)
                    let replaced = current.uid != uids[key] ?? nil || current.json[path: "spec", "nodeName"]?.stringValue != node
                    if !replaced { stillPresent.append(key) }
                } catch let error as KubeAPIError where error.statusCode == 404 {
                    continue
                } catch is CancellationError {
                    throw CancellationError()
                } catch {
                    stillPresent.append(key) // transient error: not proven gone
                }
            }
            waiting = stillPresent
            if !waiting.isEmpty { try await Task.sleep(for: Self.retryInterval) }
        }
        return waiting
    }

    private func requestEviction(_ key: ObjectKey, gracePeriod: Int?) async throws {
        var eviction: [String: JSONValue] = [
            "apiVersion": .string("policy/v1"), "kind": .string("Eviction"),
            "metadata": .object(["name": .string(key.name), "namespace": .string(key.namespace ?? "")]),
        ]
        if let gracePeriod { eviction["deleteOptions"] = .object(["gracePeriodSeconds": .int(Int64(gracePeriod))]) }
        _ = try await client.transport.data(KubeRequest(
            method: "POST", path: GroupVersionResource.pods.path(namespace: key.namespace, name: key.name, subresource: "eviction"),
            body: try Unstructured(.object(eviction)).data(), contentType: "application/json"
        ))
    }
}

enum ResourceActionsCore {
    static let nodes = GroupVersionResource(group: "", version: "v1", resource: "nodes")

    static func setUnschedulable(_ client: DynamicClient, node: String, _ unschedulable: Bool) async throws {
        let body = unschedulable ? #"{"spec":{"unschedulable":true}}"# : #"{"spec":{"unschedulable":null}}"#
        _ = try await client.patch(nodes, name: node, type: .merge, body: Data(body.utf8))
    }
}
