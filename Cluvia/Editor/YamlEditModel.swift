import Foundation
import KubeKit
import Observation

/// State of one edit/create session: the text, and the result of the last diff, dry run or apply.
@MainActor @Observable
final class YamlEditModel: Identifiable {
    enum Outcome {
        case none
        case diff([LineDiff.Line?])
        /// Dry run succeeded; lines show how the stored object would change (server defaults included).
        case preview([LineDiff.Line?])
        case conflicts([KubeAPIError.Cause])
        case failed(String)
    }

    let id = UUID()
    let title: String
    let original: String
    let defaultNamespace: String?
    /// Editing invalidates the previous diff, dry-run preview or conflict list.
    var text: String { didSet { if text != oldValue { outcome = .none } } }
    /// Secret values stay hidden until the user explicitly reveals them for editing.
    var concealed: Bool
    private(set) var outcome = Outcome.none
    private(set) var busy = false
    @ObservationIgnored private let applier: ResourceApplier

    init(title: String, yaml: String, defaultNamespace: String?, applier: ResourceApplier, concealed: Bool = false) {
        self.title = title
        self.concealed = concealed
        original = yaml
        text = yaml
        self.defaultNamespace = defaultNamespace
        self.applier = applier
    }

    var isModified: Bool { text != original }

    func showDiff() {
        outcome = .diff(LineDiff.hunks(LineDiff.lines(from: original, to: text)))
    }

    func dryRun() async {
        await run(dryRun: true, force: false)
    }

    /// Returns true when the change was persisted.
    func apply(force: Bool) async -> Bool {
        await run(dryRun: false, force: force)
    }

    @discardableResult
    private func run(dryRun: Bool, force: Bool) async -> Bool {
        busy = true
        defer { busy = false }
        do {
            switch try await applier.apply(yaml: text, defaultNamespace: defaultNamespace, dryRun: dryRun, force: force) {
            case let .applied(object):
                if dryRun {
                    // Compare without server bookkeeping that always changes.
                    let result = try YAMLRenderer.yaml(ResourceApplier.prepared(object.json))
                    let before = (try? YAMLRenderer.yaml(ResourceApplier.prepared(ResourceApplier.manifest(fromYAML: original)))) ?? ""
                    outcome = .preview(LineDiff.hunks(LineDiff.lines(from: before, to: result)))
                }
                return !dryRun
            case let .conflicts(causes):
                outcome = .conflicts(causes)
            }
        } catch {
            outcome = .failed(error.localizedDescription)
        }
        return false
    }

    nonisolated static let kindsWithoutSpec: Set<String> = [
        "ServiceAccount", "Role", "ClusterRole", "RoleBinding", "ClusterRoleBinding", "Namespace", "Event",
        "Endpoints", "LimitRange", "PriorityClass", "StorageClass", "IngressClass", "RuntimeClass",
    ]

    /// Starting point for a new object of `kind`.
    nonisolated static func template(for kind: ResourceKind, namespace: String?) -> String {
        var lines = ["apiVersion: \(kind.gvr.groupVersion)", "kind: \(kind.kind)", "metadata:", "  name: "]
        if kind.namespaced { lines.append("  namespace: \(namespace ?? "default")") }
        if ["ConfigMap", "Secret"].contains(kind.kind) {
            lines.append("data: {}")
        } else if !kindsWithoutSpec.contains(kind.kind) {
            lines.append("spec: {}")
        }
        return lines.joined(separator: "\n") + "\n"
    }
}
