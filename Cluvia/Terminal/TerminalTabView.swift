import SwiftTerm
import SwiftUI

/// Hosts the session's long-lived terminal view (re-parented when the tab is shown again).
struct TerminalTabView: NSViewRepresentable {
    let model: TerminalSessionModel

    func makeNSView(context: Context) -> TerminalView {
        let view = model.terminalView
        view.removeFromSuperview()
        DispatchQueue.main.async { view.window?.makeFirstResponder(view) }
        return view
    }

    func updateNSView(_ view: TerminalView, context: Context) {}
}
