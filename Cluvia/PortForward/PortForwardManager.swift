import AppKit
import KubeKit
import Observation

/// Active port-forwards of one cluster window. All stop when the window disconnects.
@MainActor @Observable
final class PortForwardManager {
    struct Entry: Identifiable {
        let id: UUID
        let namespace: String
        let target: PortForwarder.Target
        let remotePort: Int
        let localPort: UInt16
        let forwarder: PortForwarder
        /// Most recent failure of a forwarded connection (pod gone, nothing listening on the port).
        var lastError: String?

        var title: String {
            switch target {
            case let .pod(name): "pod/\(name):\(remotePort)"
            case let .service(name): "svc/\(name):\(remotePort)"
            }
        }

        var url: URL { URL(string: "http://127.0.0.1:\(localPort)")! }
    }

    private(set) var entries: [Entry] = []
    /// Bumped by `stopAll`; a forward still starting when the window disconnects is stopped instead of added.
    private var generation = 0

    /// Starts a forward; returns an error message on failure (port in use, not connected).
    func start(client: DynamicClient, namespace: String, target: PortForwarder.Target, remotePort: Int, localPort: UInt16?) async -> String? {
        let id = UUID()
        let forwarder = PortForwarder(client: client, namespace: namespace, target: target, remotePort: remotePort) { [weak self] message in
            Task { @MainActor in self?.record(message, for: id) }
        }
        let startedIn = generation
        do {
            let port = try await forwarder.start(localPort: localPort)
            guard startedIn == generation else {
                await forwarder.stop()
                return "Disconnected"
            }
            entries.append(Entry(id: id, namespace: namespace, target: target, remotePort: remotePort, localPort: port, forwarder: forwarder))
            return nil
        } catch {
            return "Cannot listen on 127.0.0.1\(localPort.map { ":\($0)" } ?? ""): \(error.localizedDescription)"
        }
    }

    func stop(_ id: Entry.ID) {
        guard let index = entries.firstIndex(where: { $0.id == id }) else { return }
        let forwarder = entries.remove(at: index).forwarder
        Task { await forwarder.stop() }
    }

    func stopAll() {
        generation += 1
        entries.forEach { entry in Task { await entry.forwarder.stop() } }
        entries.removeAll()
    }

    private func record(_ message: String, for id: UUID) {
        guard let index = entries.firstIndex(where: { $0.id == id }) else { return }
        entries[index].lastError = message
    }

    func open(_ entry: Entry) {
        NSWorkspace.shared.open(entry.url)
    }
}
