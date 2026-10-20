import Foundation
import Yams

public enum KubeConfigLoaderError: Error, LocalizedError, Sendable {
    case unreadable(path: String, reason: String)
    case invalid(path: String, reason: String)

    public var errorDescription: String? {
        switch self {
        case let .unreadable(path, reason): "Cannot read kubeconfig \(path): \(reason)"
        case let .invalid(path, reason): "Invalid kubeconfig \(path): \(reason)"
        }
    }
}

/// Result of loading a set of kubeconfig files. Broken files are reported, never fatal for the others.
public struct KubeConfigLoadResult: Sendable {
    public var configs: [KubeConfig]
    public var errors: [KubeConfigLoaderError]
    /// File each entry of `configs` was read from, index for index.
    public var sources: [URL] = []

    /// The file defining each context, honoring the first-file-wins rule.
    public var contextSources: [String: URL] {
        var result: [String: URL] = [:]
        for (config, url) in zip(configs, sources) {
            for context in config.contexts where result[context.name] == nil { result[context.name] = url }
        }
        return result
    }
}

/// Reads kubeconfig files for connecting. Edits go through `KubeConfigDocument`, which keeps unmodeled fields.
public enum KubeConfigLoader {
    /// Files kubectl would read: the `KUBECONFIG` list if set, otherwise `~/.kube/config`.
    public static func defaultFileURLs(environment: [String: String], home: URL = FileManager.default.homeDirectoryForCurrentUser) -> [URL] {
        let list = (environment["KUBECONFIG"] ?? "").split(separator: ":").map(String.init).filter { !$0.isEmpty }
        if list.isEmpty { return [home.appendingPathComponent(".kube/config")] }
        return list.map { URL(fileURLWithPath: ($0 as NSString).expandingTildeInPath) }
    }

    /// Loads files in priority order. Duplicates and missing files are skipped silently, matching kubectl.
    public static func loadAll(_ urls: [URL]) -> KubeConfigLoadResult {
        var seen = Set<String>()
        var result = KubeConfigLoadResult(configs: [], errors: [])
        for url in urls {
            let path = url.standardizedFileURL.path
            guard seen.insert(path).inserted, FileManager.default.fileExists(atPath: path) else { continue }
            do {
                result.configs.append(try load(contentsOf: url))
                result.sources.append(url)
            } catch let error as KubeConfigLoaderError {
                result.errors.append(error)
            } catch {
                result.errors.append(.unreadable(path: path, reason: error.localizedDescription))
            }
        }
        return result
    }

    public static func load(contentsOf url: URL) throws -> KubeConfig {
        let data: Data
        do {
            data = try Data(contentsOf: url)
        } catch {
            throw KubeConfigLoaderError.unreadable(path: url.path, reason: error.localizedDescription)
        }
        return try decode(data, path: url.path, baseDirectory: url.deletingLastPathComponent())
    }

    static func decode(_ data: Data, path: String, baseDirectory: URL) throws -> KubeConfig {
        let text = String(decoding: data, as: UTF8.self)
        if text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return KubeConfig() }
        var config: KubeConfig
        do {
            config = try YAMLDecoder().decode(KubeConfig.self, from: text)
        } catch {
            throw KubeConfigLoaderError.invalid(path: path, reason: safeDescription(of: error))
        }
        resolvePaths(in: &config, relativeTo: baseDirectory)
        return config
    }

    /// Parser errors from the YAML library quote the offending source line, which may be a token or key.
    /// Only structural information is surfaced.
    static func safeDescription(of error: Error) -> String {
        guard let decodingError = error as? DecodingError else { return "malformed YAML" }
        let context: DecodingError.Context
        switch decodingError {
        case let .typeMismatch(_, ctx), let .valueNotFound(_, ctx), let .keyNotFound(_, ctx), let .dataCorrupted(ctx):
            context = ctx
        @unknown default:
            return "malformed kubeconfig"
        }
        let path = context.codingPath.map { $0.intValue.map { "[\($0)]" } ?? ".\($0.stringValue)" }.joined()
        return "unexpected structure at \(path.isEmpty ? "root" : path)"
    }

    /// File references are relative to the kubeconfig that declares them; exec commands only when they contain a `/`.
    static func resolvePaths(in config: inout KubeConfig, relativeTo base: URL) {
        func absolute(_ path: String?) -> String? {
            guard let path, !path.isEmpty, !path.hasPrefix("/") else { return path }
            return base.appendingPathComponent(path).standardizedFileURL.path
        }
        for i in config.clusters.indices {
            config.clusters[i].cluster.certificateAuthority = absolute(config.clusters[i].cluster.certificateAuthority)
        }
        for i in config.users.indices {
            config.users[i].user.clientCertificate = absolute(config.users[i].user.clientCertificate)
            config.users[i].user.clientKey = absolute(config.users[i].user.clientKey)
            config.users[i].user.tokenFile = absolute(config.users[i].user.tokenFile)
            if let command = config.users[i].user.exec?.command, command.contains("/") {
                config.users[i].user.exec?.command = absolute(command) ?? command
            }
        }
    }
}
