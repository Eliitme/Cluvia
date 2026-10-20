import Foundation
import Testing
@testable import KubeKit

struct QuantityTests {
    @Test(arguments: [
        ("250m", 0.25), ("1.5", 1.5), ("100n", 1e-7), ("128Mi", 134_217_728), ("1Gi", 1_073_741_824),
        ("2G", 2e9), ("316Ki", 323_584), ("1e3", 1000), ("0", 0),
    ])
    func parses(text: String, value: Double) {
        #expect(abs((Quantity.parse(text) ?? -1) - value) < 1e-12 * max(1, value))
    }

    @Test func rejectsGarbage() {
        #expect(Quantity.parse("abc") == nil)
        #expect(Quantity.parse("Mi") == nil)
    }

    @Test func formatsLikeKubectl() {
        #expect(Quantity.formatCPU(0.435) == "435m")
        #expect(Quantity.formatCPU(2.5) == "2.50")
        #expect(Quantity.formatMemory(323_584) == "316Ki")
        #expect(Quantity.formatMemory(1440 * 1_048_576) == "1.4Gi")
        #expect(Quantity.formatMemory(3 * 1_073_741_824) == "3.0Gi")
    }
}
