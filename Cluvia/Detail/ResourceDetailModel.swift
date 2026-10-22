import Foundation
import KubeKit
import Observation

/// Full object and related events for the inspector. Reloaded whenever the row's resourceVersion changes,
/// so the detail stays live without a second watch.
@MainActor @Observable
final class ResourceDetailModel {
    private(set) var object: Unstructured?
    private(set) var events: [Unstructured] = []
    private(set) var error: String?

    func load(client: DynamicClient, kind: ResourceKind, key: ObjectKey) async {
        do {
            let object = try await client.get(kind.gvr, name: key.name, namespace: key.namespace)
            guard !Task.isCancelled else { return }
            self.object = object
            error = nil
            await loadEvents(client: client, object: object)
        } catch is CancellationError {
            return
        } catch {
            self.error = error.localizedDescription
        }
    }

    private func loadEvents(client: DynamicClient, object: Unstructured) async {
        guard let uid = object.uid, object.kind != "Event" else { return events = [] }
        let list = try? await client.list(
            .events, namespace: object.namespace, options: ListOptions(fieldSelector: "involvedObject.uid=\(uid)")
        )
        guard !Task.isCancelled else { return }
        events = (list?.items ?? []).sorted { Self.lastSeen($0) > Self.lastSeen($1) }
    }

    static func lastSeen(_ event: Unstructured) -> Date {
        let json = event.json
        let candidates = [json["lastTimestamp"], json["eventTime"], json[path: "metadata", "creationTimestamp"]]
        return candidates.lazy.compactMap { $0?.stringValue.flatMap(KubeTimestamp.parse) }.first ?? .distantPast
    }
}

/// Hides Secret values until the user explicitly reveals them.
enum SecretMasking {
    static let placeholder = "••••••••"

    /// Annotation written by client-side apply; for a Secret it embeds the full data in plain JSON.
    static let lastAppliedAnnotation = "kubectl.kubernetes.io/last-applied-configuration"

    static func masked(_ json: JSONValue) -> JSONValue {
        guard json["kind"]?.stringValue == "Secret", case var .object(fields) = json else { return json }
        for key in ["data", "stringData"] {
            if case let .object(values)? = fields[key] {
                fields[key] = .object(values.mapValues { _ in .string(placeholder) })
            }
        }
        if case var .object(metadata)? = fields["metadata"], case var .object(annotations)? = metadata["annotations"],
           annotations[lastAppliedAnnotation] != nil {
            annotations[lastAppliedAnnotation] = .string(placeholder)
            metadata["annotations"] = .object(annotations)
            fields["metadata"] = .object(metadata)
        }
        return .object(fields)
    }

    /// Text of a `data` entry, or nil when it is not valid base64 or not UTF-8 (binary).
    static func decodedUTF8(_ value: JSONValue) -> String? {
        guard let encoded = value.stringValue, let data = Data(base64Encoded: encoded) else { return nil }
        return String(data: data, encoding: .utf8)
    }

    /// Decoded value of a `data` entry (base64) for display after reveal.
    static func decoded(_ value: JSONValue) -> String {
        if let text = decodedUTF8(value) { return text }
        guard let encoded = value.stringValue, let data = Data(base64Encoded: encoded) else { return value.displayText }
        return "<\(data.count) bytes binary>"
    }
}
