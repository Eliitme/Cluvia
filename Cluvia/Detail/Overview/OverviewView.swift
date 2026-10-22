import KubeKit
import SwiftUI

/// Kind-specific state, conditions and usage first, then labels, annotations and metadata.
struct OverviewView: View {
    let session: ClusterSession
    let object: Unstructured
    @Binding var revealSecrets: Bool

    var body: some View {
        // What the object is doing comes first; identifiers and bookkeeping last.
        VStack(alignment: .leading, spacing: 16) {
            KindSpecificSections(object: object, revealSecrets: $revealSecrets) { action, container in
                session.open(action, pod: object, container: container)
            }
            ConditionsSection(conditions: object.json[path: "status", "conditions"]?.arrayValue ?? [])
            if MetricsChartsSection.supportedKinds.contains(object.kind ?? "") {
                MetricsChartsSection(session: session, object: object)
            }
            if !object.labels.isEmpty { KeyValueSection(title: "Labels", values: object.labels) }
            let annotations = revealSecrets ? object.annotations : Unstructured(SecretMasking.masked(object.json)).annotations
            if !annotations.isEmpty { KeyValueSection(title: "Annotations", values: annotations, collapsed: true) }
            DetailSection("Metadata") {
                if !object.ownerReferences.isEmpty {
                    DetailRow("Controlled By") {
                        ForEach(object.ownerReferences, id: \.uid) { owner in
                            OwnerLink(session: session, owner: owner, namespace: object.namespace)
                        }
                    }
                }
                OwnedObjectsRow(session: session, object: object)
                DetailRow("Created", value: object.creationTimestamp.map {
                    "\(AgeFormatter.string(since: $0)) ago · \($0.formatted(date: .abbreviated, time: .standard))"
                })
                DetailRow("UID", value: object.uid)
                DetailRow("Resource Version", value: object.resourceVersion)
            }
        }
    }
}

struct OwnerLink: View {
    let session: ClusterSession
    let owner: OwnerReference
    let namespace: String?

    var body: some View {
        if let kind = session.kind(named: owner.kind, apiVersion: owner.apiVersion) {
            Button("\(owner.kind)/\(owner.name)") {
                session.reveal(kind, ObjectKey(namespace: kind.namespaced ? namespace : nil, name: owner.name))
            }
            .buttonStyle(.link)
        } else {
            Text("\(owner.kind)/\(owner.name)")
        }
    }
}

struct DetailSection<Content: View>: View {
    let title: String
    @ViewBuilder let content: Content

    init(_ title: String, @ViewBuilder content: () -> Content) {
        self.title = title
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title).font(.headline)
            Grid(alignment: .leadingFirstTextBaseline, horizontalSpacing: 12, verticalSpacing: 5) { content }
        }
    }
}

struct DetailRow<Value: View>: View {
    let label: String
    @ViewBuilder let value: Value

    init(_ label: String, @ViewBuilder value: () -> Value) {
        self.label = label
        self.value = value()
    }

    var body: some View {
        GridRow {
            Text(label).foregroundStyle(.secondary).gridColumnAlignment(.trailing)
            VStack(alignment: .leading, spacing: 2) { value }
        }
    }
}

extension DetailRow where Value == AnyView {
    init(_ label: String, value: String?) {
        self.init(label) { AnyView(Text(value ?? "—").textSelection(.enabled)) }
    }
}

struct KeyValueSection: View {
    let title: String
    let values: [String: String]
    @State private var expanded: Bool

    init(title: String, values: [String: String], collapsed: Bool = false) {
        self.title = title
        self.values = values
        _expanded = State(initialValue: !collapsed)
    }

    var body: some View {
        DisclosureGroup(isExpanded: $expanded) {
            VStack(alignment: .leading, spacing: 3) {
                ForEach(values.keys.sorted(), id: \.self) { key in
                    Text("\(key)=\(values[key] ?? "")")
                        .font(.system(.callout, design: .monospaced))
                        .textSelection(.enabled)
                        .lineLimit(3)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.top, 4)
        } label: {
            Text("\(title) (\(values.count))").font(.headline)
        }
    }
}

struct ConditionsSection: View {
    let conditions: [JSONValue]

    var body: some View {
        if !conditions.isEmpty {
            DetailSection("Conditions") {
                ForEach(Array(conditions.enumerated()), id: \.offset) { _, condition in
                    let status = condition["status"]?.stringValue ?? ""
                    DetailRow(condition["type"]?.stringValue ?? "?") {
                        Label(status, systemImage: status == "True" ? "checkmark.circle.fill" : "xmark.circle")
                            .foregroundStyle(status == "True" ? .green : .secondary)
                        if let message = condition["message"]?.stringValue {
                            Text(message).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                        }
                    }
                }
            }
        }
    }
}
