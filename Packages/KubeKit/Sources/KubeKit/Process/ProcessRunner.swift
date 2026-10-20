import Foundation

/// Captured output of a finished child process.
public struct ProcessResult: Sendable {
    public let status: Int32
    public let stdout: Data
    public let stderr: Data

    public var stdoutText: String { String(decoding: stdout, as: UTF8.self) }
    public var stderrText: String { String(decoding: stderr, as: UTF8.self) }
}

public enum ProcessRunnerError: Error, LocalizedError, Sendable {
    case launchFailed(executable: String, reason: String)
    case timedOut(executable: String, seconds: Double)
    case cancelled(executable: String)

    public var errorDescription: String? {
        switch self {
        case let .launchFailed(executable, reason): "Failed to launch \(executable): \(reason)"
        case let .timedOut(executable, seconds): "\(executable) did not finish within \(Int(seconds))s"
        case let .cancelled(executable): "\(executable) was cancelled"
        }
    }
}

/// Async wrapper around `Process` with stdin feeding, timeout and full stdout/stderr capture.
public enum ProcessRunner {
    public static func run(
        _ executable: URL,
        arguments: [String] = [],
        environment: [String: String]? = nil,
        stdin: Data? = nil,
        timeout: Duration = .seconds(30)
    ) async throws -> ProcessResult {
        let execution = ProcessExecution(executable: executable, arguments: arguments, environment: environment)
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                execution.start(stdin: stdin, timeout: timeout, continuation: continuation)
            }
        } onCancel: {
            execution.abort(with: .cancelled(executable: executable.lastPathComponent))
        }
    }
}

/// One child process run. All mutable state is guarded by `lock`; the continuation is resumed exactly once.
///
/// Output is read with non-blocking readability handlers rather than blocking reads: a grandchild (e.g. a
/// background job started by shell rc files) can inherit the pipes and keep them open after the child exits,
/// so completion is "child exited and EOF on both pipes", or "child exited + short grace period".
private final class ProcessExecution: @unchecked Sendable {
    private static let drainGrace: TimeInterval = 0.5

    private let process = Process()
    private let name: String
    private let lock = NSLock()
    private var continuation: CheckedContinuation<ProcessResult, Error>?
    private var cancelled: ProcessRunnerError?
    private var launched = false
    private var terminated = false
    private var openStreams = 2
    private var stdoutData = Data()
    private var stderrData = Data()
    private let outPipe = Pipe()
    private let errPipe = Pipe()

    init(executable: URL, arguments: [String], environment: [String: String]?) {
        name = executable.lastPathComponent
        process.executableURL = executable
        process.arguments = arguments
        if let environment { process.environment = environment }
    }

    func start(stdin: Data?, timeout: Duration, continuation: CheckedContinuation<ProcessResult, Error>) {
        // Cancellation can arrive before start; honor it instead of launching.
        let earlyCancel: ProcessRunnerError? = lock.withLock {
            if cancelled == nil { self.continuation = continuation }
            return cancelled
        }
        if let earlyCancel { return continuation.resume(throwing: earlyCancel) }

        let inPipe = stdin.map { _ in Pipe() }
        process.standardOutput = outPipe
        process.standardError = errPipe
        process.standardInput = inPipe ?? FileHandle.nullDevice
        collect(outPipe, isStdout: true)
        collect(errPipe, isStdout: false)
        process.terminationHandler = { [self] _ in
            lock.withLock { terminated = true }
            completeIfDrained()
            DispatchQueue.global().asyncAfter(deadline: .now() + Self.drainGrace) { [self] in complete() }
        }

        do {
            try process.run()
        } catch {
            finish(.failure(ProcessRunnerError.launchFailed(executable: name, reason: error.localizedDescription)))
            return
        }
        let cancelledDuringLaunch = lock.withLock {
            launched = true
            return cancelled != nil
        }
        if cancelledDuringLaunch { process.terminate() }

        if let inPipe, let stdin {
            let writer = inPipe.fileHandleForWriting
            // The child may exit without reading stdin; a write to a closed pipe must not SIGPIPE the app.
            _ = fcntl(writer.fileDescriptor, F_SETNOSIGPIPE, 1)
            DispatchQueue.global().async {
                try? writer.write(contentsOf: stdin)
                try? writer.close()
            }
        }

        let seconds = Double(timeout.components.seconds) + Double(timeout.components.attoseconds) / 1e18
        DispatchQueue.global().asyncAfter(deadline: .now() + seconds) { [self] in
            abort(with: .timedOut(executable: name, seconds: seconds))
        }
    }

    func abort(with error: ProcessRunnerError) {
        let shouldTerminate: Bool = lock.withLock {
            guard cancelled == nil, continuation != nil || !launched else { return false }
            cancelled = error
            return launched && !terminated
        }
        if shouldTerminate { process.terminate() }
        finish(.failure(error))
    }

    private func collect(_ pipe: Pipe, isStdout: Bool) {
        pipe.fileHandleForReading.readabilityHandler = { [self] handle in
            let chunk = handle.availableData
            if chunk.isEmpty {
                handle.readabilityHandler = nil
                lock.withLock { openStreams -= 1 }
                completeIfDrained()
                return
            }
            lock.withLock {
                if isStdout { stdoutData.append(chunk) } else { stderrData.append(chunk) }
            }
        }
    }

    private func completeIfDrained() {
        if lock.withLock({ terminated && openStreams == 0 }) { complete() }
    }

    private func complete() {
        let (result, cancelled) = lock.withLock {
            (ProcessResult(status: process.terminationStatus, stdout: stdoutData, stderr: stderrData), self.cancelled)
        }
        // A process ended by a timeout or cancellation reports that, not its SIGTERM exit: the termination handler
        // can run before `abort` gets to finish.
        finish(cancelled.map { .failure($0) } ?? .success(result))
    }

    private func finish(_ result: Result<ProcessResult, Error>) {
        let continuation = lock.withLock {
            defer { self.continuation = nil }
            return self.continuation
        }
        guard let continuation else { return }
        outPipe.fileHandleForReading.readabilityHandler = nil
        errPipe.fileHandleForReading.readabilityHandler = nil
        continuation.resume(with: result)
    }
}
