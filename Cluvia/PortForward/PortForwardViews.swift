import KubeKit
import SwiftUI

struct PortForwardListView: View {
    let manager: PortForwardManager

    var body: some View {
        if manager.entries.isEmpty {
            ContentUnavailableView("No Port Forwards", systemImage: "arrow.left.arrow.right",
                                   description: Text("Forward a pod or service port from its context menu or details."))
        } else {
            List(manager.entries) { entry in
                HStack {
                    Image(systemName: "arrow.left.arrow.right").foregroundStyle(.secondary)
                    Text(entry.title).fontWeight(.medium)
                    Text(entry.namespace).foregroundStyle(.secondary)
                    if let error = entry.lastError {
                        Label("Last connection failed", systemImage: "exclamationmark.triangle")
                            .foregroundStyle(.orange)
                            .help(error)
                    }
                    Spacer()
                    Button("127.0.0.1:\(String(entry.localPort))") { manager.open(entry) }
                        .buttonStyle(.link)
                        .help("Open in browser")
                    Button("Stop") { manager.stop(entry.id) }
                }
            }
        }
    }
}

/// Picks the remote port (from the object's declared ports) and an optional fixed local port.
struct ForwardPortSheet: View {
    let pending: PendingAction
    let contextName: String
    let ports: [Int]
    let start: (Int, UInt16?) async -> String?
    @Environment(\.dismiss) private var dismiss
    @State private var remotePort = 0
    /// Typed remote port when the target declares none; empty rather than a misleading "0".
    @State private var typedPort = ""
    @State private var localPort = ""
    @State private var error: String?
    @State private var busy = false

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Label("Forward Port", systemImage: "arrow.left.arrow.right").font(.title3.weight(.semibold))
            TargetSummary(kind: pending.kind, key: pending.key, contextName: contextName)
            if ports.isEmpty {
                TextField("Remote port", text: $typedPort, prompt: Text("e.g. 8080"))
                    .onChange(of: typedPort) { remotePort = Int($1.trimmingCharacters(in: .whitespaces)) ?? 0 }
            } else {
                Picker("Remote port", selection: $remotePort) {
                    ForEach(ports, id: \.self) { Text(String($0)).tag($0) }
                }
            }
            TextField("Local port (empty = any free port)", text: $localPort)
            if let error { Label(error, systemImage: "xmark.octagon").foregroundStyle(.red).textSelection(.enabled) }
            HStack {
                Spacer()
                Button("Cancel", role: .cancel) { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Start") {
                    busy = true
                    Task {
                        error = await start(remotePort, UInt16(localPort.trimmingCharacters(in: .whitespaces)))
                        busy = false
                        if error == nil { dismiss() }
                    }
                }
                .keyboardShortcut(.defaultAction)
                .disabled(busy || !(1...65535).contains(remotePort) || (!localPort.isEmpty && UInt16(localPort) == nil))
            }
        }
        .padding(20)
        .frame(width: 420)
        .onAppear { remotePort = ports.first ?? 0 }
    }
}
