import Foundation

/// Kubernetes channel WebSocket framing (`v4.channel.k8s.io` / `v5.channel.k8s.io`): every binary message
/// starts with one byte naming the stream it belongs to.
///
/// Exec: 0 stdin, 1 stdout, 2 stderr, 3 error/status (a `Status` object), 4 resize (`{"Width":w,"Height":h}`),
/// and on v5 only, 255 = close the stream named by the next byte (used to signal stdin EOF).
/// Port-forward: for the n-th requested port, channel 2n carries data and 2n+1 errors; the first message the
/// server sends on each of them is just the port number as 2 little-endian bytes.
public enum ChannelFrameCodec {
    public static let stdin: UInt8 = 0
    public static let stdout: UInt8 = 1
    public static let stderr: UInt8 = 2
    public static let status: UInt8 = 3
    public static let resize: UInt8 = 4
    public static let close: UInt8 = 255

    public static func encode(channel: UInt8, _ payload: Data) -> Data {
        var frame = Data([channel])
        frame.append(payload)
        return frame
    }

    public static func decode(_ frame: Data) -> (channel: UInt8, payload: Data)? {
        guard let channel = frame.first else { return nil }
        return (channel, frame.dropFirst())
    }

    public static func resizeFrame(columns: Int, rows: Int) -> Data {
        encode(channel: resize, Data(#"{"Width":\#(columns),"Height":\#(rows)}"#.utf8))
    }

    /// v5 only: tells the server stdin is finished (the remote process sees EOF).
    public static let closeStdinFrame = Data([close, stdin])

    /// Exit code from the status channel: 0 on `Success`, the `ExitCode` cause on `NonZeroExitCode`.
    public static func exitCode(fromStatus payload: Data) -> (code: Int?, message: String?) {
        guard let status = try? JSONValue.parse(payload) else { return (nil, String(decoding: payload, as: UTF8.self)) }
        if status["status"]?.stringValue == "Success" { return (0, nil) }
        let causes = status[path: "details", "causes"]?.arrayValue ?? []
        let code = causes.first { $0["reason"]?.stringValue == "ExitCode" }?["message"]?.stringValue.flatMap { Int($0) }
        return (code, status["message"]?.stringValue)
    }

    /// Port-forward preamble: the 2-byte little-endian port the server echoes on each channel.
    public static func portPreamble(_ payload: Data) -> UInt16? {
        guard payload.count == 2 else { return nil }
        return UInt16(payload[payload.startIndex]) | UInt16(payload[payload.startIndex + 1]) << 8
    }
}
