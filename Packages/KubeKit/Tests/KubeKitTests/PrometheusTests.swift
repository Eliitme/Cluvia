import Foundation
import Testing
@testable import KubeKit

struct PrometheusTests {
    @Test func endpointOverrideParsing() {
        #expect(PrometheusEndpoint("monitoring/prom-server:80")?.description == "monitoring/prom-server:80")
        #expect(PrometheusEndpoint("monitoring/prometheus")?.port == "9090")
        #expect(PrometheusEndpoint("nonsense") == nil)
        #expect(PrometheusEndpoint("/svc:1") == nil)
    }

    @Test func candidateServices() {
        #expect(PrometheusClient.isCandidate("prom-prometheus-server"))
        #expect(PrometheusClient.isCandidate("kube-prometheus-stack-prometheus"))
        #expect(!PrometheusClient.isCandidate("kube-prometheus-stack-operator"))
        #expect(!PrometheusClient.isCandidate("prometheus-node-exporter"))
        #expect(!PrometheusClient.isCandidate("grafana"))
    }

    @Test func rangeResultParsing() throws {
        let json = try JSONValue.parse(Data(#"{"status":"success","data":{"resultType":"matrix","result":[{"metric":{},"values":[[1760000000,"0.25"],[1760000060.5,"NaN"],[1760000120,"0.5"]]}]}}"#.utf8))
        let points = PrometheusClient.points(json)
        #expect(points.map(\.value) == [0.25, 0.5])
        #expect(points.first?.date == Date(timeIntervalSince1970: 1_760_000_000))
    }

    @Test func workloadPodRegexes() throws {
        let deployment = try Regex("^" + MetricQueries.podRegex(kind: "Deployment", name: "web") + "$")
        #expect("web-6b65bb7554-szlrf".wholeMatch(of: deployment) != nil)
        #expect("web-api-6b65bb7554-szlrf".wholeMatch(of: deployment) == nil)
        let statefulSet = try Regex("^" + MetricQueries.podRegex(kind: "StatefulSet", name: "db") + "$")
        #expect("db-0".wholeMatch(of: statefulSet) != nil && "db-x".wholeMatch(of: statefulSet) == nil)
        #expect(MetricQueries.nodeCPU("n1").components(separatedBy: " or ").count == 3)
        #expect(MetricQueries.podCPU(namespace: "ns", podRegex: MetricQueries.podRegex(kind: "Deployment", name: "api.v2"))
            .contains(#"pod=~`api\.v2-[a-z0-9]+-[a-z0-9]+`"#))
    }
}
