import SwiftUI

/// A cluster's initial on a color derived from its context name, so the same cluster always looks the same in the
/// sidebar and the status bar and clusters are told apart at a glance.
struct ClusterBadge: View {
    let name: String
    var size: CGFloat = 18

    static let palette: [Color] = [.brandCobalt, .brandTeal, .purple, .orange, .pink, .indigo, .mint, .brown]

    static func color(for name: String) -> Color {
        // Stable across launches (unlike `hashValue`).
        let sum = name.unicodeScalars.reduce(0) { ($0 &* 31 &+ Int($1.value)) & 0xFFFF }
        return palette[sum % palette.count]
    }

    /// First letter of the last meaningful part, e.g. "kind-cluvia-dev" → "C", "arn:…:cluster/prod" → "P".
    static func initial(for name: String) -> String {
        let parts = name.split(whereSeparator: { "/:@_".contains($0) }).last.map(String.init) ?? name
        let words = parts.split(separator: "-").filter { !["kind", "k3d", "minikube", "gke", "eks", "aks"].contains($0.lowercased()) }
        return String((words.first ?? Substring(parts)).prefix(1)).uppercased()
    }

    var body: some View {
        Text(Self.initial(for: name))
            .font(.system(size: size * 0.55, weight: .bold, design: .rounded))
            .foregroundStyle(.white)
            .frame(width: size, height: size)
            .background(Self.color(for: name), in: RoundedRectangle(cornerRadius: size * 0.28))
            .accessibilityHidden(true)
    }
}
