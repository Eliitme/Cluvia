import HelmKit
import SwiftUI

/// Install/upgrade form and rollback/uninstall confirmations; every sheet names the cluster context.
struct HelmSheetView: View {
    let model: HelmReleasesModel
    let sheet: HelmSheet
    @Environment(\.dismiss) private var dismiss
    @State private var name = ""
    @State private var namespace = "default"
    @State private var chart = ""
    @State private var version = ""
    @State private var values = ""
    @State private var busy = false
    @State private var error: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(title).font(.title3.weight(.semibold))
            Text("Context: \(model.contextName)").font(.caption).foregroundStyle(.secondary)
            content
            if let error { Label(error, systemImage: "xmark.octagon").foregroundStyle(.red).textSelection(.enabled) }
            HStack {
                Spacer()
                Button("Cancel", role: .cancel) { dismiss() }.keyboardShortcut(.cancelAction)
                Button(actionTitle, role: isDestructive ? .destructive : nil) { Task { await run() } }
                    .keyboardShortcut(.return, modifiers: .command)
                    .disabled(busy || !isValid)
            }
            if busy { ProgressView().controlSize(.small) }
        }
        .padding(20)
        .frame(width: isForm ? 640 : 440)
        .onAppear(perform: prefill)
    }

    private var isForm: Bool {
        switch sheet {
        case .install, .upgrade: true
        default: false
        }
    }

    private var isDestructive: Bool { if case .uninstall = sheet { true } else { false } }

    private var isValid: Bool { !isForm || (!name.isEmpty && !chart.isEmpty && !namespace.isEmpty) }

    private var title: String {
        switch sheet {
        case .install: "Install Chart"
        case let .upgrade(release, _): "Upgrade \(release.name)"
        case let .rollback(release, revision): "Roll back \(release.name) to revision \(revision)?"
        case let .uninstall(release): "Uninstall \(release.name)?"
        }
    }

    private var actionTitle: String {
        switch sheet {
        case .install: "Install"
        case .upgrade: "Upgrade"
        case .rollback: "Roll Back"
        case .uninstall: "Uninstall"
        }
    }

    @ViewBuilder
    private var content: some View {
        switch sheet {
        case .install, .upgrade:
            Form {
                TextField("Release name", text: $name).disabled(!isInstall)
                TextField("Namespace", text: $namespace).disabled(!isInstall)
                TextField("Chart (repo/chart, oci://… or local path)", text: $chart)
                TextField("Version (empty = latest)", text: $version)
            }
            Text("Values").font(.headline)
            YamlEditorView(text: $values).frame(minHeight: 240)
        case let .rollback(release, _), let .uninstall(release):
            Text("Release \(release.name) in namespace \(release.namespace).")
            Text(isDestructive ? "All resources created by the release are deleted." : "A new revision is created from the old one.")
                .foregroundStyle(.secondary)
        }
    }

    private var isInstall: Bool { if case .install = sheet { true } else { false } }

    private func prefill() {
        if case let .upgrade(release, current) = sheet {
            name = release.name
            namespace = release.namespace
            // Helm does not record where a chart came from; the user may need to qualify it (repo/chart).
            chart = release.chartName
            // Keep the installed chart version: editing values must not silently upgrade the chart.
            version = release.chartVersion ?? ""
            values = current
        }
    }

    private func run() async {
        busy = true
        defer { busy = false }
        let (name, namespace, chart, version, values, install) = (name, namespace, chart, version, values, isInstall)
        error = switch sheet {
        case .install, .upgrade:
            await model.perform { try await $0.upgradeOrInstall(release: name, namespace: namespace, chart: chart,
                                                                version: version, values: values, install: install) }
        case let .rollback(release, revision):
            await model.perform { try await $0.rollback(release: release.name, namespace: release.namespace, revision: revision) }
        case let .uninstall(release):
            await model.perform { try await $0.uninstall(release: release.name, namespace: release.namespace) }
        }
        if error == nil { dismiss() }
    }

}
