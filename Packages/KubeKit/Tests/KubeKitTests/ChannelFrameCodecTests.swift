import Foundation
import Testing
@testable import KubeKit

struct ChannelFrameCodecTests {
    @Test func framesCarryChannelPrefix() {
        let frame = ChannelFrameCodec.encode(channel: ChannelFrameCodec.stdin, Data("ls\n".utf8))
        #expect(frame.first == 0)
        let decoded = ChannelFrameCodec.decode(frame)
        #expect(decoded?.channel == 0 && decoded?.payload == Data("ls\n".utf8))
        #expect(ChannelFrameCodec.decode(Data()) == nil)
        #expect(ChannelFrameCodec.resizeFrame(columns: 120, rows: 40) == Data([4]) + Data(#"{"Width":120,"Height":40}"#.utf8))
        #expect(ChannelFrameCodec.closeStdinFrame == Data([255, 0]))
    }

    @Test func exitCodesFromStatusChannel() {
        #expect(ChannelFrameCodec.exitCode(fromStatus: Data(#"{"metadata":{},"status":"Success"}"#.utf8)).code == 0)
        let failure = #"{"status":"Failure","message":"command terminated with non-zero exit code: exit status 3","reason":"NonZeroExitCode","details":{"causes":[{"reason":"ExitCode","message":"3"}]}}"#
        let parsed = ChannelFrameCodec.exitCode(fromStatus: Data(failure.utf8))
        #expect(parsed.code == 3)
        #expect(parsed.message?.contains("exit status 3") == true)
        #expect(ChannelFrameCodec.exitCode(fromStatus: Data("oops".utf8)) == (nil, "oops"))
    }

    @Test func portPreambleIsLittleEndian() {
        // Recorded from a real API server for port 8080.
        #expect(ChannelFrameCodec.portPreamble(Data([144, 31])) == 8080)
        #expect(ChannelFrameCodec.portPreamble(Data([1, 2, 3])) == nil)
    }
}

struct ServiceTargetResolverTests {
    static func slice(_ json: String) -> Unstructured { try! Unstructured(data: Data(json.utf8)) }

    @Test func picksReadyPodForNamedPort() {
        let slices = [Self.slice("""
        {"ports":[{"name":"metrics","port":9090},{"name":"web","port":8080}],
         "endpoints":[{"conditions":{"ready":false},"targetRef":{"kind":"Pod","name":"old"}},
                      {"conditions":{"ready":true},"targetRef":{"kind":"Pod","name":"new"}}]}
        """)]
        #expect(ServiceTargetResolver.pick(portName: "web", slices: slices).map { "\($0.pod):\($0.port)" } == "new:8080")
        #expect(ServiceTargetResolver.pick(portName: "missing", slices: slices) == nil)
    }

    @Test func unnamedSinglePortAndUnknownReadiness() {
        let slices = [Self.slice("""
        {"ports":[{"port":5432}],"endpoints":[{"targetRef":{"kind":"Node","name":"n"}},{"conditions":{},"targetRef":{"kind":"Pod","name":"db-0"}}]}
        """)]
        let picked = ServiceTargetResolver.pick(portName: nil, slices: slices)
        #expect(picked?.pod == "db-0" && picked?.port == 5432)
    }
}
