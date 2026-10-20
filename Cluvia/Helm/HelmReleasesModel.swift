import Foundation
import HelmKit
import Observation

/// Helm releases of one cluster. Helm is optional: without the binary the section shows an install hint.
@MainActor @Observable
final class HelmReleasesModel {
    enum Availability: Equatable { case unknown, available, missing }

    struct Detail {
        /// The release these details belong to; the selection may already have moved on.
        let releaseID: HelmRelease.ID
        var values = ""
        var manifest = ""
        var notes = ""
        var history: [HelmRevision] = []
    }

    let contextName: String
    private(set) var availability = Availability.unknown
    private(set) var releases: [HelmRelease] = []
    private(set) var loading = false
    private(set) var error: String?
    var selection: HelmRelease.ID?
    private(set) var detail: Detail?
    @ObservationIgnored private(set) var runner: HelmRunner?

    init(contextName: String) {
        self.contextName = contextName
    }

    var selectedRelease: HelmRelease? { releases.first { $0.id == selection } }

    /// Details only when they match the current selection, never another release's.
    var currentDetail: Detail? { detail?.releaseID == selection ? detail : nil }

    func refresh() async {
        if runner == nil {
            runner = await HelmRunner.locate(context: contextName)
            availability = runner == nil ? .missing : .available
        }
        guard let runner else { return }
        loading = true
        defer { loading = false }
        do {
            releases = try await runner.releases().sorted { ($0.namespace, $0.name) < ($1.namespace, $1.name) }
            error = nil
        } catch {
            self.error = error.localizedDescription
        }
    }

    func loadDetail() async {
        guard let runner, let release = selectedRelease else { return detail = nil }
        if detail?.releaseID != release.id { detail = nil }
        do {
            async let values = runner.values(release: release.name, namespace: release.namespace)
            async let manifest = runner.manifest(release: release.name, namespace: release.namespace)
            async let history = runner.history(release: release.name, namespace: release.namespace)
            // Notes are optional; charts without NOTES.txt make helm fail.
            let notes = (try? await runner.notes(release: release.name, namespace: release.namespace)) ?? ""
            let loaded = Detail(releaseID: release.id, values: try await values, manifest: try await manifest, notes: notes, history: try await history)
            guard !Task.isCancelled else { return }
            detail = loaded
        } catch {
            if !Task.isCancelled { self.error = error.localizedDescription }
        }
    }

    /// Runs a release operation, then reloads; returns an error message for the calling sheet.
    func perform(_ operation: @escaping @Sendable (HelmRunner) async throws -> Void) async -> String? {
        guard let runner else { return "Helm is not installed" }
        do {
            try await operation(runner)
        } catch {
            return error.localizedDescription
        }
        await refresh()
        await loadDetail()
        return nil
    }
}
