import SwiftUI

/// Toolbar menu selecting all namespaces or any subset.
struct NamespacePicker: View {
    @Bindable var session: ClusterSession

    var body: some View {
        Menu {
            Button {
                session.selectedNamespaces = []
            } label: {
                if session.selectedNamespaces.isEmpty { Label("All Namespaces", systemImage: "checkmark") } else { Text("All Namespaces") }
            }
            Divider()
            ForEach(session.namespaces, id: \.self) { namespace in
                Toggle(namespace, isOn: Binding(
                    get: { session.selectedNamespaces.contains(namespace) },
                    set: { selected in
                        if selected { session.selectedNamespaces.insert(namespace) } else { session.selectedNamespaces.remove(namespace) }
                    }
                ))
            }
        } label: {
            Label(title, systemImage: "square.stack.3d.up")
        }
        .help("Namespaces")
    }

    private var title: String {
        switch session.selectedNamespaces.count {
        case 0: "All Namespaces"
        case 1: session.selectedNamespaces.first!
        default: "\(session.selectedNamespaces.count) Namespaces"
        }
    }
}
