import Foundation

/// Environment of the user's interactive login shell.
///
/// GUI apps launched from Finder inherit a minimal launchd environment (no Homebrew PATH, no `KUBECONFIG`,
/// no cloud CLI profile variables). Exec credential plugins and `helm` need the shell environment, so it is
/// captured once by running `$SHELL -ilc` and cached for the app lifetime.
public actor LoginShellEnvironment {
    public static let shared = LoginShellEnvironment()

    /// Directories appended to PATH when absent, covering the common install locations even when capture fails.
    public static let fallbackDirectories = [
        "/opt/homebrew/bin", "/usr/local/bin", "~/.local/bin", "/usr/bin", "/bin", "/usr/sbin", "/sbin",
    ]

    private let baseEnvironment: [String: String]
    private let timeout: Duration
    private var cached: [String: String]?
    private var loading: Task<[String: String], Never>?

    public init(baseEnvironment: [String: String] = ProcessInfo.processInfo.environment, timeout: Duration = .seconds(5)) {
        self.baseEnvironment = baseEnvironment
        self.timeout = timeout
    }

    /// Full environment to pass to child processes.
    public func environment() async -> [String: String] {
        if let cached { return cached }
        if let loading { return await loading.value }
        let base = baseEnvironment
        let timeout = timeout
        let task = Task { await Self.capture(base: base, timeout: timeout) }
        loading = task
        let env = await task.value
        cached = env
        loading = nil
        return env
    }

    public func searchPath() async -> [String] {
        await environment()["PATH", default: ""].split(separator: ":").map(String.init)
    }

    /// Resolves a command the way a shell would: paths containing `/` are used as-is, bare names are searched in PATH.
    public func resolveExecutable(_ command: String) async -> URL? {
        let fm = FileManager.default
        if command.contains("/") {
            let path = (command as NSString).expandingTildeInPath
            return fm.isExecutableFile(atPath: path) ? URL(fileURLWithPath: path) : nil
        }
        for dir in await searchPath() {
            let candidate = (dir as NSString).appendingPathComponent(command)
            if fm.isExecutableFile(atPath: candidate) { return URL(fileURLWithPath: candidate) }
        }
        return nil
    }

    static func capture(base: [String: String], timeout: Duration) async -> [String: String] {
        let shell = base["SHELL"].flatMap { $0.isEmpty ? nil : $0 } ?? "/bin/zsh"
        // A marker separates shell startup noise (rc files printing banners) from the env dump.
        let marker = "__CLUVIA_ENV_\(UUID().uuidString)__"
        var captured: [String: String] = [:]
        if let result = try? await ProcessRunner.run(
            URL(fileURLWithPath: shell),
            arguments: ["-ilc", "printf '%s' \(marker); /usr/bin/env -0"],
            environment: base,
            timeout: timeout
        ) {
            captured = parseEnvironmentDump(result.stdout, marker: marker)
        }
        var merged = base.merging(captured) { _, shellValue in shellValue }
        merged["PATH"] = appendingFallbackDirectories(to: merged["PATH"] ?? "")
        return merged
    }

    /// Parses `env -0` output that follows `marker`. Returns an empty map if the marker is missing.
    static func parseEnvironmentDump(_ data: Data, marker: String) -> [String: String] {
        guard let markerRange = data.range(of: Data(marker.utf8)) else { return [:] }
        var env: [String: String] = [:]
        for entry in data[markerRange.upperBound...].split(separator: 0) {
            let text = String(decoding: entry, as: UTF8.self)
            guard let eq = text.firstIndex(of: "="), eq != text.startIndex else { continue }
            env[String(text[..<eq])] = String(text[text.index(after: eq)...])
        }
        return env
    }

    static func appendingFallbackDirectories(to path: String) -> String {
        var entries = path.split(separator: ":").map(String.init)
        for dir in fallbackDirectories {
            let expanded = (dir as NSString).expandingTildeInPath
            if !entries.contains(expanded) { entries.append(expanded) }
        }
        return entries.joined(separator: ":")
    }
}
