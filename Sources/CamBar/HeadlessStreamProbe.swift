import CamBarCore
import CoreImage
import Foundation

/// `CamBar --probe [seconds]` runs the app's real RTSP and hardware-decode
/// pipeline with no UI, streams telemetry to stderr and prints one JSON
/// summary to stdout. It saves the last decoded frame as a PNG so an agent
/// can look at the picture, including the camera's on-screen clock. Exit
/// status 0 means live video was still arriving at the end of the run. It
/// does not touch the running app or its log.
@MainActor
enum HeadlessStreamProbe {
    static func run(seconds: TimeInterval) -> Never {
        DirectStreamTelemetry.writesToStandardErrorInsteadOfLogFile = true
        guard let sourceURL = StreamSourceResolver.resolveRtspURL() else {
            printSummary(["result": "no_camera_configured"])
            exit(1)
        }

        let startedAt = ProcessInfo.processInfo.systemUptime
        let stream = CameraStreamController(sourceURL: sourceURL)
        var firstFrameAt: TimeInterval?
        var lastFrameAt: TimeInterval?
        var frameCount = 0
        var retryCount = 0
        var videoSize: CGSize?
        var lastFrame: CameraFrame?

        _ = stream.addObserver(
            onFrame: { frame in
                guard let frame else { return }
                let now = ProcessInfo.processInfo.systemUptime
                firstFrameAt = firstFrameAt ?? now
                lastFrameAt = now
                frameCount += 1
                videoSize = frame.size
                lastFrame = frame
            },
            onState: { state in
                if case .waitingToRetry = state { retryCount += 1 }
            }
        )
        stream.start()

        Task { @MainActor in
            try? await Task.sleep(for: .seconds(seconds))
            let now = ProcessInfo.processInfo.systemUptime
            let isLive = stream.state == .ready && (lastFrameAt.map { now - $0 < 1 } ?? false)
            var summary: [String: Any] = [
                "result": isLive ? "live" : (frameCount > 0 ? "stalled" : "no_video"),
                "camera": StreamSourceResolver.redactRtspCredentials(in: sourceURL),
                "probe_seconds": seconds,
                "frames": frameCount,
                "retries": retryCount,
            ]
            if let firstFrameAt {
                summary["first_frame_ms"] = Int((firstFrameAt - startedAt) * 1_000)
                let liveSeconds = now - firstFrameAt
                if liveSeconds > 0 {
                    summary["fps"] = Int((Double(frameCount) / liveSeconds).rounded())
                }
            }
            if let videoSize {
                summary["width"] = Int(videoSize.width)
                summary["height"] = Int(videoSize.height)
            }
            if let lastFrame {
                let frameURL = FileManager.default.temporaryDirectory
                    .appendingPathComponent("cambar-probe-last-frame.png")
                let image = CIImage(cvPixelBuffer: lastFrame.pixelBuffer)
                try? CIContext().writePNGRepresentation(
                    of: image,
                    to: frameURL,
                    format: .RGBA8,
                    colorSpace: CGColorSpace(name: CGColorSpace.sRGB)!
                )
                summary["last_frame_png"] = frameURL.path
                let localTime = ISO8601DateFormatter()
                localTime.timeZone = .current
                localTime.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
                summary["last_frame_decoded_at"] = localTime.string(
                    from: Date().addingTimeInterval(lastFrame.decodedAt - now)
                )
            }
            printSummary(summary)
            stream.shutdown()
            DirectStreamTelemetry.flush()
            exit(isLive ? 0 : 1)
        }
        dispatchMain()
    }

    private static func printSummary(_ summary: [String: Any]) {
        let data = try! JSONSerialization.data(
            withJSONObject: summary,
            options: [.sortedKeys, .withoutEscapingSlashes]
        )
        print(String(decoding: data, as: UTF8.self))
    }
}
