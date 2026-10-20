import Foundation
import KubeKit
import Observation

/// Which Prometheus a cluster window uses: the user's override, else the auto-detected service.
@MainActor @Observable
final class PrometheusModel {
    enum State: Equatable {
        case unknown
        case detecting
        case available(PrometheusEndpoint, manual: Bool)
        case unavailable
    }

    private(set) var state = State.unknown
    @ObservationIgnored private let contextName: String
    @ObservationIgnored private let settings: AppSettingsStore

    init(contextName: String, settings: AppSettingsStore) {
        self.contextName = contextName
        self.settings = settings
    }

    var endpoint: PrometheusEndpoint? {
        if case let .available(endpoint, _) = state { endpoint } else { nil }
    }

    func resolve(client: DynamicClient) async {
        guard state == .unknown else { return }
        if let manual = settings.prometheus(for: contextName).flatMap(PrometheusEndpoint.init) {
            state = .available(manual, manual: true)
            return
        }
        state = .detecting
        state = await PrometheusClient.detect(client: client).map { .available($0, manual: false) } ?? .unavailable
    }

    /// Saves (or clears, with an empty string) the override and re-resolves.
    func setOverride(_ text: String, client: DynamicClient) async {
        settings.setPrometheus(text, for: contextName)
        state = .unknown
        await resolve(client: client)
    }
}
