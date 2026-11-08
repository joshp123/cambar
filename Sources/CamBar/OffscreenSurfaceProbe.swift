import AppKit
import CamBarCore
import CoreImage
import SwiftUI

/// `CamBar --ui-probe` puts the real popover content and video surface in a
/// borderless window beyond every display, so it opens, closes and switches
/// streams like the app does while staying invisible and never taking focus.
/// It reports open times, saves a screenshot of each state, and exits. It does
/// not cover NSPopover itself or the status item. Run it through
/// Scripts/ui_probe.sh: outside the bundle macOS makes it a foreground app.
@MainActor
enum OffscreenSurfaceProbe {
    private static let openCount = 5

    private final class LiveViewTimes: @unchecked Sendable {
        private let lock = NSLock()
        private var times: [String: [Int]] = [:]

        func record(openID: String, milliseconds: Int) {
            lock.lock()
            times[openID, default: []].append(milliseconds)
            lock.unlock()
        }

        func all(for openID: String) -> [Int] {
            lock.lock()
            defer { lock.unlock() }
            return times[openID] ?? []
        }
    }

    static func run(on app: NSApplication) -> Never {
        guard Bundle.main.bundleURL.pathExtension == "app" else {
            print(#"{"result":"refused","reason":"run through Scripts/ui_probe.sh, not the bare binary"}"#)
            exit(2)
        }
        DirectStreamTelemetry.writesToStandardErrorInsteadOfLogFile = true
        app.setActivationPolicy(.prohibited)
        let liveViews = LiveViewTimes()
        DirectStreamTelemetry.observer = { event, openID, elapsed, _ in
            if event == "live_view", let openID, let elapsed {
                liveViews.record(openID: openID, milliseconds: elapsed)
            }
        }

        let stream = CameraStreamController(sourceURL: StreamSourceResolver.resolveRtspURL() ?? "")
        let playback = CameraPlaybackController(
            stream: stream,
            surface: .menu,
            cornerStyle: .containerConcentric
        )
        let videoSize = CGSize(width: 1344, height: 760)
        let state = CamBarUIState(videoSize: videoSize)
        stream.onFallbackStreamHeightChange = { state.fallbackStreamHeight = $0 }
        var unavailableShownWhileOpen = false
        stream.onStateChange = { streamState in
            state.cameraUnavailable = streamState.meansCameraUnavailable
            if state.cameraUnavailable, playback.isShowing { unavailableShownWhileOpen = true }
        }
        let contentSize = ContentView.contentSize(forVideoSize: videoSize)
        let window = NSWindow(
            contentRect: NSRect(
                x: -2 * max(contentSize.width, NSScreen.screens.map(\.frame.maxX).max() ?? 0),
                y: 0,
                width: contentSize.width,
                height: contentSize.height
            ),
            styleMask: .borderless,
            backing: .buffered,
            defer: false
        )
        window.ignoresMouseEvents = true
        window.isReleasedWhenClosed = false
        window.contentView = NSHostingView(
            rootView: ContentView(state: state, playback: playback, onOpenWindow: {}, onRetry: {})
        )
        window.orderFrontRegardless()
        stream.start()

        Task { @MainActor in
            var summary: [String: Any] = [
                "window_frame": NSStringFromRect(window.frame),
                "low_power_mode": stream.isLowPowerMode,
            ]
            if !stream.isLowPowerMode {
                while stream.state != .ready {
                    try? await Task.sleep(for: .milliseconds(50))
                }
            }
            try? await Task.sleep(for: .seconds(4))  // Let the stream settle hidden.

            var openMilliseconds: [Int] = []
            for index in 0..<openCount {
                let openID = "probe-\(index)"
                playback.show(openID: openID, startedAt: ProcessInfo.processInfo.systemUptime)
                let opened = await waitForLiveView(liveViews, openID: openID, count: 1)
                if opened { openMilliseconds.append(liveViews.all(for: openID)[0]) }
                try? await Task.sleep(for: .milliseconds(600))
                if index == 0 {
                    summary["open_view_png"] = capture(window, name: "open")
                    if let frame = stream.latestFrame {
                        summary["open_video_png"] = savePicture(frame, name: "open")
                    }
                }
                playback.hide()
                try? await Task.sleep(for: .seconds(Double.random(in: 0.5...2)))
            }
            summary["open_to_live_ms"] = openMilliseconds.sorted()
            summary["opens_failed"] = openCount - openMilliseconds.count
            summary["unavailable_shown_while_open"] = unavailableShownWhileOpen

            let switchID = "probe-switch"
            playback.show(openID: switchID, startedAt: ProcessInfo.processInfo.systemUptime)
            _ = await waitForLiveView(liveViews, openID: switchID, count: 1)
            let switchedAt = ProcessInfo.processInfo.systemUptime
            stream.forceFallbackStream()
            let recovered = await waitForLiveView(liveViews, openID: switchID, count: 2)
            summary["switch_to_fallback_recovered"] = recovered
            summary["switch_to_fallback_ms"] = Int((ProcessInfo.processInfo.systemUptime - switchedAt) * 1_000)
            try? await Task.sleep(for: .seconds(1))
            summary["fallback_badge_height"] = state.fallbackStreamHeight as Any? ?? NSNull()
            summary["fallback_view_png"] = capture(window, name: "fallback")
            if let frame = stream.latestFrame {
                summary["fallback_video_png"] = savePicture(frame, name: "fallback")
            }

            playback.shutdown()
            stream.shutdown()
            DirectStreamTelemetry.flush()
            let data = try! JSONSerialization.data(
                withJSONObject: summary,
                options: [.sortedKeys, .withoutEscapingSlashes]
            )
            print(String(decoding: data, as: UTF8.self))
            exit(0)
        }
        app.run()
        exit(0)
    }

    private static func waitForLiveView(
        _ liveViews: LiveViewTimes,
        openID: String,
        count: Int
    ) async -> Bool {
        let deadline = ProcessInfo.processInfo.systemUptime + 12
        while ProcessInfo.processInfo.systemUptime < deadline {
            if liveViews.all(for: openID).count >= count { return true }
            try? await Task.sleep(for: .milliseconds(5))
        }
        return false
    }

    /// Renders the view tree to a PNG. Needs no permission, unlike any screen
    /// capture, which can bring up System Settings. The video layer itself does
    /// not render this way; the probe saves the decoded picture separately.
    private static func capture(_ window: NSWindow, name: String) -> String {
        guard let view = window.contentView,
              let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return "failed" }
        view.cacheDisplay(in: view.bounds, to: bitmap)
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("cambar-ui-probe-\(name).png")
        guard let data = bitmap.representation(using: .png, properties: [:]),
              (try? data.write(to: url)) != nil else { return "failed" }
        return url.path
    }

    private static func savePicture(_ frame: CameraFrame, name: String) -> String {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("cambar-ui-probe-\(name)-video.png")
        try? CIContext().writePNGRepresentation(
            of: CIImage(cvPixelBuffer: frame.pixelBuffer),
            to: url,
            format: .RGBA8,
            colorSpace: CGColorSpace(name: CGColorSpace.sRGB)!
        )
        return url.path
    }
}
