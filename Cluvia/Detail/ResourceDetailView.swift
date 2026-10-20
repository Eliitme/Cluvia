import KubeKit
import SwiftUI

/// Inspector for the selected object: Overview, YAML (read-only) and Events.
struct ResourceDetailView: View {
    enum Tab: String, CaseIterable, Identifiable {
        case overview = "Overview", yaml = "YAML", events = "Events"
        var id: String { rawValue }
    }

    let session: ClusterSession
    let kind: ResourceKind
    let row: ResourceTableRow
    @State private var model = ResourceDetailModel()
    @State private var tab = Tab.overview
    @State private var revealSecrets = false

    private struct LoadID: Hashable {
        let key: ObjectKey
        let resourceVersion: String?
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 6) {
                Text(row.object.name).font(.title3.weight(.semibold)).textSelection(.enabled).lineLimit(2)
                HStack(spacing: 8) {
                    Text(kind.kind + (row.object.namespace.map { " · \($0)" } ?? "")).foregroundStyle(.secondary)
                    if let summary = model.object.flatMap(StatusSummary.init) { StatusBadge(summary: summary) }
                }
                ResourceActionBar(actions: ResourceAction.available(for: kind)) { action in
                    session.request(action, kind: kind, key: row.id)
                }
                Picker("", selection: $tab) {
                    ForEach(Tab.allCases) { Text($0.rawValue).tag($0) }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
            }
            .padding(12)
            Divider()
            content.frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        // Pin the header to the top; short content such as an empty state would otherwise center the whole stack.
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .task(id: LoadID(key: row.id, resourceVersion: row.object.resourceVersion)) {
            guard let client = session.client else { return }
            await model.load(client: client, kind: kind, key: row.id)
        }
        .onChange(of: row.id) { revealSecrets = false }
    }

    @ViewBuilder
    private var content: some View {
        if let error = model.error, model.object == nil {
            ContentUnavailableView("Cannot Load", systemImage: "exclamationmark.triangle", description: Text(error))
        } else if let object = model.object {
            switch tab {
            case .overview:
                ScrollView {
                    OverviewView(session: session, object: object, revealSecrets: $revealSecrets)
                        .padding(12)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            case .yaml:
                YAMLTabView(object: object, revealSecrets: $revealSecrets)
            case .events:
                EventsTabView(events: model.events)
            }
        } else {
            ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }
}

struct YAMLTabView: View {
    let object: Unstructured
    @Binding var revealSecrets: Bool
    @State private var yaml = ""

    private struct RenderID: Hashable {
        let resourceVersion: String?
        let reveal: Bool
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if object.kind == "Secret" {
                Toggle("Reveal secret values", isOn: $revealSecrets).padding(8)
                Divider()
            }
            ReadOnlyTextView(text: yaml)
        }
        // Rendered once per object version rather than on every body pass; large objects are costly.
        .task(id: RenderID(resourceVersion: object.resourceVersion, reveal: revealSecrets)) {
            let json = revealSecrets ? object.json : SecretMasking.masked(object.json)
            yaml = await Task.detached { (try? YAMLRenderer.yaml(json)) ?? "Cannot render YAML" }.value
        }
    }
}

struct EventsTabView: View {
    let events: [Unstructured]

    var body: some View {
        if events.isEmpty {
            ContentUnavailableView("No Events", systemImage: "bell.slash")
        } else {
            List(events, id: \.uid) { event in
                VStack(alignment: .leading, spacing: 3) {
                    HStack {
                        Text(event.json["reason"]?.stringValue ?? "").fontWeight(.semibold)
                            .foregroundStyle(event.json["type"]?.stringValue == "Warning" ? .orange : .primary)
                        Spacer()
                        Text(AgeFormatter.string(since: ResourceDetailModel.lastSeen(event)))
                            .foregroundStyle(.secondary).monospacedDigit()
                        if let count = event.json["count"]?.intValue, count > 1 { Text("×\(count)").foregroundStyle(.secondary) }
                    }
                    Text(event.json["message"]?.stringValue ?? "").textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
                }
                .padding(.vertical, 2)
            }
        }
    }
}
