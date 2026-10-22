import AppKit

/// Cleanup that must reach the cluster before the app exits (e.g. deleting node-shell helper pods).
/// Quitting waits briefly for registered tasks instead of leaving privileged pods behind.
@MainActor
final class ShutdownCleanup {
    static let shared = ShutdownCleanup()
    static let timeout: Duration = .seconds(3)

    private var tasks: [UUID: @Sendable () async -> Void] = [:]

    func register(_ id: UUID, _ cleanup: @escaping @Sendable () async -> Void) {
        tasks[id] = cleanup
    }

    func unregister(_ id: UUID) {
        tasks[id] = nil
    }

    func runAll() async {
        let pending = Array(tasks.values)
        tasks.removeAll()
        guard !pending.isEmpty else { return }
        await withTaskGroup(of: Bool.self) { group in
            for cleanup in pending {
                group.addTask {
                    await cleanup()
                    return false
                }
            }
            group.addTask {
                try? await Task.sleep(for: Self.timeout)
                return true
            }
            // Whichever comes first: every cleanup finished, or the timeout.
            var finished = 0
            for await timedOut in group {
                if timedOut { break }
                finished += 1
                if finished == pending.count { break }
            }
            group.cancelAll()
        }
    }
}

final class CluviaAppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        LoginTerminalLauncher.sweepLeftovers()
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        Task { @MainActor in
            await ShutdownCleanup.shared.runAll()
            sender.reply(toApplicationShouldTerminate: true)
        }
        return .terminateLater
    }
}
