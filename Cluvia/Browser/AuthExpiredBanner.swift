import SwiftUI

/// Above the resource table when the sign-in expired after connecting; the tables keep their last known rows.
struct AuthExpiredBanner: View {
    let session: ClusterSession
    @Environment(ClusterCatalogModel.self) private var catalog
    @State private var showsDetails = false

    var body: some View {
        if let failure = session.authFailure {
            HStack {
                Label("Sign-in failed for \(session.contextName); showing last known state.", systemImage: "person.badge.key")
                    .lineLimit(1)
                Spacer()
                Button("Sign In…") { showsDetails = true }
                Button("Retry") { Task { await session.retryAfterSignIn(using: catalog) } }
            }
            .font(.callout)
            .padding(6)
            .background(.orange.opacity(0.15))
            // The banner (and this sheet) goes away by itself once the next plugin run succeeds.
            .sheet(isPresented: $showsDetails) {
                VStack(alignment: .trailing, spacing: 0) {
                    ExecAuthFailureView(failure: failure, contextName: session.contextName) {
                        await session.retryAfterSignIn(using: catalog)
                    }
                    Button("Close") { showsDetails = false }.keyboardShortcut(.cancelAction).padding([.horizontal, .bottom], 20)
                }
            }
        }
    }
}
