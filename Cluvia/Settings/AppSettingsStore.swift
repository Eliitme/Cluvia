import Foundation
import Observation

/// User preferences persisted to `~/Library/Application Support/Cluvia/settings.json`.
struct AppSettings: Codable, Equatable {
    var favoriteContexts: Set<String> = []
    /// Selected namespaces per context; empty means all namespaces.
    var namespacesByContext: [String: [String]] = [:]
    /// Manually chosen Prometheus (`namespace/service:port`) per context, overriding auto-detection.
    var prometheusByContext: [String: String] = [:]

    init() {}

    init(from decoder: Decoder) throws {
        // Fields added in later versions default when absent, so older settings files keep loading.
        let c = try decoder.container(keyedBy: CodingKeys.self)
        favoriteContexts = try c.decodeIfPresent(Set<String>.self, forKey: .favoriteContexts) ?? []
        namespacesByContext = try c.decodeIfPresent([String: [String]].self, forKey: .namespacesByContext) ?? [:]
        prometheusByContext = try c.decodeIfPresent([String: String].self, forKey: .prometheusByContext) ?? [:]
    }
}

@MainActor @Observable
final class AppSettingsStore {
    private(set) var settings: AppSettings
    @ObservationIgnored private let fileURL: URL

    nonisolated static var defaultFileURL: URL {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return support.appendingPathComponent("Cluvia/settings.json")
    }

    init(fileURL: URL = AppSettingsStore.defaultFileURL) {
        self.fileURL = fileURL
        // A missing or unreadable file falls back to defaults rather than blocking launch.
        settings = (try? JSONDecoder().decode(AppSettings.self, from: Data(contentsOf: fileURL))) ?? AppSettings()
    }

    func isFavorite(_ context: String) -> Bool {
        settings.favoriteContexts.contains(context)
    }

    func toggleFavorite(_ context: String) {
        update { settings in
            if settings.favoriteContexts.remove(context) == nil { settings.favoriteContexts.insert(context) }
        }
    }

    func namespaces(for context: String) -> Set<String> {
        Set(settings.namespacesByContext[context] ?? [])
    }

    func setNamespaces(_ namespaces: Set<String>, for context: String) {
        update { $0.namespacesByContext[context] = namespaces.isEmpty ? nil : namespaces.sorted() }
    }

    func prometheus(for context: String) -> String? {
        settings.prometheusByContext[context]
    }

    func setPrometheus(_ endpoint: String?, for context: String) {
        update { $0.prometheusByContext[context] = endpoint.flatMap { $0.isEmpty ? nil : $0 } }
    }

    /// Carries a context's preferences over when it is renamed in the kubeconfig; nil `new` forgets them (deleted).
    func moveContext(_ old: String, to new: String?) {
        update { settings in
            let favorite = settings.favoriteContexts.remove(old) != nil
            let namespaces = settings.namespacesByContext.removeValue(forKey: old)
            let prometheus = settings.prometheusByContext.removeValue(forKey: old)
            guard let new else { return }
            if favorite { settings.favoriteContexts.insert(new) }
            settings.namespacesByContext[new] = namespaces
            settings.prometheusByContext[new] = prometheus
        }
    }

    private func update(_ change: (inout AppSettings) -> Void) {
        var next = settings
        change(&next)
        guard next != settings else { return }
        settings = next
        save()
    }

    private func save() {
        do {
            try FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            try encoder.encode(settings).write(to: fileURL, options: .atomic)
        } catch {
            // Preferences are non-critical; keep the in-memory value and try again on the next change.
            NSLog("Cluvia: could not save settings: \(error.localizedDescription)")
        }
    }
}
