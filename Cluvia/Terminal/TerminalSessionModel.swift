import AppKit
import KubeKit
import Observation
import SwiftTerm

/// A shell in a container. Owns its terminal view so scrollback survives switching dock tabs.
@MainActor @Observable
final class TerminalSessionModel: Identifiable {
    enum Status: Equatable {
        case connecting
        case running
        case exited(code: Int?, message: String?)
    }

    let id = UUID()
    let title: String
    private(set) var status = Status.connecting
    @ObservationIgnored let terminalView: TerminalView
    /// Created once the terminal has its size (see `start`).
    @ObservationIgnored private var session: ExecSession?
    @ObservationIgnored private let makeSession: @Sendable (_ columns: Int, _ rows: Int) -> ExecSession
    @ObservationIgnored private var bridge: TerminalBridge?
    @ObservationIgnored private var task: Task<Void, Never>?
    @ObservationIgnored private var pendingResize: Task<Void, Never>?
    /// Size last sent to the shell. Each resize makes the shell redraw its prompt, so unchanged sizes are not resent.
    @ObservationIgnored private var sentSize: (columns: Int, rows: Int)?
    /// A height change held back while the shell sits at its prompt (see `resize`).
    @ObservationIgnored private var heldSize: (columns: Int, rows: Int)?
    /// Keystrokes go through one ordered queue; separate Tasks per keystroke could reach the session out of order.
    @ObservationIgnored private let input: AsyncStream<Data>.Continuation
    @ObservationIgnored private let inputStream: AsyncStream<Data>
    /// Called when the shell exits cleanly, so the tab can close itself.
    @ObservationIgnored var onCleanExit: (() -> Void)?
    /// Cleanup when the tab closes, e.g. deleting a node-shell helper pod.
    @ObservationIgnored private let onClose: (@Sendable () async -> Void)?

    init(transport: KubeTransport, pod: Unstructured, container: String?, title: String? = nil,
         command: [String] = ExecSession.defaultShell, onClose: (@Sendable () async -> Void)? = nil) {
        let container = container ?? pod.defaultContainerName
        self.title = title ?? "\(pod.name)\(container.map { "/\($0)" } ?? "")"
        self.onClose = onClose
        if let onClose { ShutdownCleanup.shared.register(id, onClose) }
        let namespace = pod.namespace ?? "default", podName = pod.name
        makeSession = { columns, rows in
            ExecSession(transport: transport, namespace: namespace, pod: podName, container: container,
                        command: command == ExecSession.defaultShell ? ExecSession.defaultShell(columns: columns, rows: rows) : command)
        }
        (inputStream, input) = AsyncStream.makeStream()
        terminalView = AppearanceTrackingTerminalView(frame: NSRect(x: 0, y: 0, width: 640, height: 320))
        terminalView.font = .monospacedSystemFont(ofSize: NSFont.systemFontSize, weight: .regular)
        let bridge = TerminalBridge(model: self)
        self.bridge = bridge
        terminalView.terminalDelegate = bridge
        start()
    }

    private func start() {
        let inputStream = inputStream
        task = Task { [weak self] in
            // The shell starts at the terminal's real size: wait (briefly) until the view is laid out in a window;
            // SwiftTerm reports its placeholder frame before that.
            for _ in 0..<20 where self?.terminalView.window == nil { try? await Task.sleep(for: .milliseconds(50)) }
            try? await Task.sleep(for: .milliseconds(30))
            guard let self else { return }
            let terminal = self.terminalView.getTerminal()
            let (columns, rows) = (terminal.cols, terminal.rows)
            let session = self.makeSession(columns, rows)
            self.session = session
            self.sentSize = (columns, rows)
            do {
                try await session.start()
            } catch {
                self.finish(ExecSession.Exit(code: nil, message: error.localizedDescription))
                return
            }
            self.status = .running
            // Shells without stty get their size here; for the rest it matches and changes nothing.
            await session.resize(columns: columns, rows: rows)
            // Typed-ahead input waits in the stream until the connection is up.
            let pump = Task { for await data in inputStream { await session.send(data) } }
            defer { pump.cancel() }
            let exit = await session.output { [weak self] data in
                // Awaiting the main actor per chunk throttles the socket to what the terminal can draw.
                await self?.terminalView.feed(byteArray: ArraySlice([UInt8](data)))
                await self?.releaseHeldSizeForFullScreenProgram()
            }
            self.finish(exit)
        }
    }

    private func finish(_ exit: ExecSession.Exit) {
        if case .exited = status { return }
        status = .exited(code: exit.code, message: exit.message)
        let detail = exit.code.map { "process exited with code \($0)" } ?? (exit.message ?? "connection closed")
        terminalView.feed(text: "\r\n[\(detail)]\r\n")
        if exit.code == 0 { onCleanExit?() }
    }

    func send(_ bytes: ArraySlice<UInt8>) {
        input.yield(Data(bytes))
    }

    /// Layout reports a stream of sizes while a panel is dragged; only the size it settles on is sent, since each
    /// resize makes shells such as busybox print their prompt again.
    ///
    /// A shell at its prompt does not use the height, yet redraws its prompt on every resize. So while the normal
    /// screen is shown, a change of height alone is held back; full-screen programs (vi, top, less) switch to the
    /// alternate screen, and the held size is sent then, which they handle by redrawing. Width changes always go out:
    /// line editing and command output wrap at the width.
    func resize(columns: Int, rows: Int) {
        pendingResize?.cancel()
        pendingResize = Task {
            try? await Task.sleep(for: .milliseconds(500))
            guard !Task.isCancelled, status == .running else { return }
            if let sent = sentSize, sent == (columns, rows) {
                heldSize = nil
                return
            }
            if let sent = sentSize, sent.columns == columns, !terminalView.getTerminal().isCurrentBufferAlternate {
                heldSize = (columns, rows)
                return
            }
            await send(columns: columns, rows: rows)
        }
    }

    private func releaseHeldSizeForFullScreenProgram() async {
        guard let held = heldSize, terminalView.getTerminal().isCurrentBufferAlternate else { return }
        await send(columns: held.columns, rows: held.rows)
    }

    private func send(columns: Int, rows: Int) async {
        guard let session else { return }
        heldSize = nil
        sentSize = (columns, rows)
        await session.resize(columns: columns, rows: rows)
    }

    func stop() {
        input.finish()
        let session = session, onClose = onClose, id = id
        Task {
            await session?.close()
            await onClose?()
            // Unregistered only once done, so quitting right after closing the tab still waits for it.
            ShutdownCleanup.shared.unregister(id)
        }
    }
}

/// Re-derives terminal colors when the system switches between light and dark mode.
final class AppearanceTrackingTerminalView: TerminalView {
    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        configureNativeColors()
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        configureNativeColors()
    }
}

/// SwiftTerm delegate forwarding keystrokes and size changes to the exec session.
@MainActor
final class TerminalBridge: NSObject, @preconcurrency TerminalViewDelegate {
    weak var model: TerminalSessionModel?

    init(model: TerminalSessionModel) {
        self.model = model
    }

    func send(source: TerminalView, data: ArraySlice<UInt8>) { model?.send(data) }
    func sizeChanged(source: TerminalView, newCols: Int, newRows: Int) { model?.resize(columns: newCols, rows: newRows) }
    func setTerminalTitle(source: TerminalView, title: String) {}
    func hostCurrentDirectoryUpdate(source: TerminalView, directory: String?) {}
    func scrolled(source: TerminalView, position: Double) {}
    func rangeChanged(source: TerminalView, startY: Int, endY: Int) {}

    func requestOpenLink(source: TerminalView, link: String, params: [String: String]) {
        if let url = URL(string: link), ["http", "https"].contains(url.scheme) { NSWorkspace.shared.open(url) }
    }
}
