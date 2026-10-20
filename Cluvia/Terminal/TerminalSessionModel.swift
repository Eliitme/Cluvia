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
    @ObservationIgnored private let session: ExecSession
    @ObservationIgnored private var bridge: TerminalBridge?
    @ObservationIgnored private var task: Task<Void, Never>?
    @ObservationIgnored private var pendingResize: Task<Void, Never>?
    /// Keystrokes go through one ordered queue; separate Tasks per keystroke could reach the session out of order.
    @ObservationIgnored private let input: AsyncStream<Data>.Continuation
    @ObservationIgnored private let inputStream: AsyncStream<Data>
    /// Called when the shell exits cleanly, so the tab can close itself.
    @ObservationIgnored var onCleanExit: (() -> Void)?

    /// The container `kubectl exec` would pick: the default-container annotation, else the first container.
    static func defaultContainer(of pod: Unstructured) -> String? {
        pod.annotations["kubectl.kubernetes.io/default-container"]
            ?? pod.json[path: "spec", "containers"]?.arrayValue?.first?["name"]?.stringValue
    }

    init(transport: KubeTransport, pod: Unstructured, container: String?) {
        let container = container ?? Self.defaultContainer(of: pod)
        title = "\(pod.name)\(container.map { "/\($0)" } ?? "")"
        session = ExecSession(transport: transport, namespace: pod.namespace ?? "default", pod: pod.name,
                              container: container, command: ExecSession.defaultShell)
        (inputStream, input) = AsyncStream.makeStream()
        terminalView = AppearanceTrackingTerminalView(frame: NSRect(x: 0, y: 0, width: 640, height: 320))
        terminalView.font = .monospacedSystemFont(ofSize: NSFont.systemFontSize, weight: .regular)
        let bridge = TerminalBridge(model: self)
        self.bridge = bridge
        terminalView.terminalDelegate = bridge
        start()
    }

    private func start() {
        let session = session
        let inputStream = inputStream
        task = Task { [weak self] in
            do {
                try await session.start()
            } catch {
                self?.finish(ExecSession.Exit(code: nil, message: error.localizedDescription))
                return
            }
            self?.status = .running
            if let terminal = self?.terminalView.getTerminal() {
                await session.resize(columns: terminal.cols, rows: terminal.rows)
            }
            // Typed-ahead input waits in the stream until the connection is up.
            let pump = Task { for await data in inputStream { await session.send(data) } }
            defer { pump.cancel() }
            let exit = await session.output { [weak self] data in
                // Awaiting the main actor per chunk throttles the socket to what the terminal can draw.
                await self?.terminalView.feed(byteArray: ArraySlice([UInt8](data)))
            }
            self?.finish(exit)
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

    /// Layout reports several sizes in a row; only the settled one is sent (each resize makes shells redraw).
    func resize(columns: Int, rows: Int) {
        let session = session
        pendingResize?.cancel()
        pendingResize = Task {
            try? await Task.sleep(for: .milliseconds(150))
            guard !Task.isCancelled else { return }
            await session.resize(columns: columns, rows: rows)
        }
    }

    func stop() {
        input.finish()
        let session = session
        Task { await session.close() }
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
