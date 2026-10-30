import CamBarCore
import CoreImage
import Foundation

/// `CamBar --probe [seconds]` runs the app's real RTSP and hardware-decode
/// pipeline with no UI and no effect on the running app or its log. It stays
/// hidden for `seconds` as if the menu were closed, measures five reveals
/// (the headless equivalent of clicking the icon), then watches for five
/// seconds and saves the last picture as a PNG. Telemetry goes to stderr and
/// one JSON summary to stdout. Exit status 0 means live video at the end.
@MainActor
enum HeadlessStreamProbe {
    private static let revealCount = 5
    private static let viewingSeconds: TimeInterval = 5
    private static let viewer = "probe"

    static func run(seconds: TimeInterval) -> Never {
        DirectStreamTelemetry.writesToStandardErrorInsteadOfLogFile = true
        guard let sourceURL = StreamSourceResolver.resolveRtspURL() else {
            printSummary(["result": "no_camera_configured"])
            exit(1)
        }

        let startedAt = uptime
        let stream = CameraStreamController(sourceURL: sourceURL)
        var firstFrameAt: TimeInterval?
        var lastFrameAt: TimeInterval?
        var frameCount = 0
        var retryCount = 0
        var lastFrame: CameraFrame?

        _ = stream.addObserver(
            onFrame: { frame in
                guard let frame else { return }
                lastFrameAt = uptime
                firstFrameAt = firstFrameAt ?? uptime
                frameCount += 1
                lastFrame = frame
            },
            onState: { state in
                if case .waitingToRetry = state { retryCount += 1 }
            }
        )
        stream.start()

        Task { @MainActor in
            var summary: [String: Any] = [
                "camera": StreamSourceResolver.redactRtspCredentials(in: sourceURL),
                "hidden_seconds": seconds,
            ]
            while firstFrameAt == nil, uptime - startedAt < max(seconds, 15) {
                try? await Task.sleep(for: .milliseconds(50))
            }
            guard let firstFrameAt else {
                summary["result"] = "no_video"
                summary["retries"] = retryCount
                finish(summary, stream: stream, exitCode: 1)
            }
            summary["first_frame_ms"] = Int((firstFrameAt - startedAt) * 1_000)

            let hiddenStart = ProcessResourceUsage.sample()
            try? await Task.sleep(for: .seconds(seconds))
            let hiddenEnd = ProcessResourceUsage.sample()
            summary["hidden_cpu_percent"] = rounded(hiddenEnd.cpuPercent(since: hiddenStart))
            summary["memory_mb"] = hiddenEnd.memoryMegabytes

            var revealMilliseconds: [Int] = []
            var revealPicture: String?
            var revealFrameAges: [Int] = []
            for index in 0..<revealCount {
                let baseline = stream.latestSequence
                let revealedAt = uptime
                stream.setViewer(viewer, active: true)
                while stream.latestSequence <= baseline, uptime - revealedAt < 3 {
                    try? await Task.sleep(for: .milliseconds(1))
                }
                revealMilliseconds.append(Int((uptime - revealedAt) * 1_000))
                // Keep the picture a user would see first, to check it is whole.
                if let frame = stream.latestFrame {
                    revealPicture = savePicture(frame, name: "reveal-\(index)")
                    revealFrameAges.append(Int((uptime - frame.decodedAt) * 1_000))
                }
                stream.setViewer(viewer, active: false)
                // Land somewhere different in the keyframe interval each time.
                try? await Task.sleep(for: .seconds(Double.random(in: 0.4...2.1)))
            }
            summary["reveal_ms"] = revealMilliseconds.sorted()
            summary["reveal_png"] = revealPicture

            let viewingFrom = frameCount
            let viewingStart = ProcessResourceUsage.sample()
            stream.setViewer(viewer, active: true)
            try? await Task.sleep(for: .seconds(viewingSeconds))
            let isLive = stream.state == .ready && (lastFrameAt.map { uptime - $0 < 1 } ?? false)
            summary["viewing_cpu_percent"] = rounded(
                ProcessResourceUsage.sample().cpuPercent(since: viewingStart)
            )
            summary["viewing_fps"] = Int((Double(frameCount - viewingFrom) / viewingSeconds).rounded())
            summary["retries"] = retryCount
            summary["result"] = isLive ? "live" : "stalled"
            if let lastFrame {
                summary["width"] = Int(lastFrame.size.width)
                summary["height"] = Int(lastFrame.size.height)
                summary["last_frame_png"] = savePicture(lastFrame, name: "last-frame")
                summary["last_frame_decoded_at"] = localTimestamp(ofUptime: lastFrame.decodedAt)
            }
            finish(summary, stream: stream, exitCode: isLive ? 0 : 1)
        }
        dispatchMain()
    }

    private static var uptime: TimeInterval { ProcessInfo.processInfo.systemUptime }

    private static func rounded(_ value: Double) -> NSDecimalNumber {
        NSDecimalNumber(string: String(format: "%.1f", value))
    }

    private static func savePicture(_ frame: CameraFrame, name: String) -> String {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("cambar-probe-\(name).png")
        try? CIContext().writePNGRepresentation(
            of: CIImage(cvPixelBuffer: frame.pixelBuffer),
            to: url,
            format: .RGBA8,
            colorSpace: CGColorSpace(name: CGColorSpace.sRGB)!
        )
        return url.path
    }

    private static func localTimestamp(ofUptime moment: TimeInterval) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.timeZone = .current
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.string(from: Date().addingTimeInterval(moment - uptime))
    }

    private static func finish(
        _ summary: [String: Any],
        stream: CameraStreamController,
        exitCode: Int32
    ) -> Never {
        printSummary(summary)
        stream.shutdown()
        DirectStreamTelemetry.flush()
        exit(exitCode)
    }

    private static func printSummary(_ summary: [String: Any]) {
        let data = try! JSONSerialization.data(
            withJSONObject: summary,
            options: [.sortedKeys, .withoutEscapingSlashes]
        )
        print(String(decoding: data, as: UTF8.self))
    }
}
