import Foundation
import Testing
@testable import KubeKit

/// Opt-in (`CLUVIA_IT_FOOTPRINT=1`): cost of idle shells and port-forwards in this process.
@Suite(.enabled(if: IntegrationCluster.isEnabled && IntegrationCluster.environment["CLUVIA_IT_FOOTPRINT"] == "1"))
struct StreamingFootprintIntegrationTests {
    @Test func fiveShellsAndFiveForwardsStayLight() async throws {
        let client = try WatchCacheIntegrationTests.client()
        try await ExecAndPortForwardIntegrationTests.ensureHTTPPod(client)
        let baseline = WatchCacheScaleIntegrationTests.footprintMB()
        var shells: [ExecSession] = []
        var forwards: [PortForwarder] = []
        for _ in 0..<5 {
            let shell = ExecSession(transport: client.transport, namespace: "cluvia-it", pod: "cluvia-it-http",
                                    container: nil, command: ExecSession.defaultShell)
            try await shell.start()
            await shell.send(Data("echo ready\n".utf8))
            shells.append(shell)
            let forward = PortForwarder(client: client, namespace: "cluvia-it", target: .service("cluvia-it-http"), remotePort: 80)
            let port = try await forward.start()
            _ = try await ExecAndPortForwardIntegrationTests.fetch(port: port)
            forwards.append(forward)
        }
        try await Task.sleep(for: .seconds(2))
        let delta = WatchCacheScaleIntegrationTests.footprintMB() - baseline
        print("footprint: 5 shells + 5 forwards = +\(Int(delta))MB")
        #expect(delta < 30)
        for shell in shells { await shell.close() }
        for forward in forwards { await forward.stop() }
    }
}
