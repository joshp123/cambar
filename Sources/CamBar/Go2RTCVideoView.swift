import AppKit
import CamBarCore
import WebKit

@MainActor
final class VideoHostView: NSView, WKNavigationDelegate, WKScriptMessageHandler {
    let surface: String
    var autoStart: Bool

    private var session: VideoSession?
    private var pendingClipPath: String?
    private var deferredStartScheduled = false
    private var hasRevealedFrame = false
    private var lastOpenTime: TimeInterval?
    private var lastSnapshotOpenTime: TimeInterval?
    private var parkingWindow: NSWindow?
    private let parkingView = NSView(frame: NSRect(x: 0, y: 0, width: 16, height: 9))
    private let overlayView = NSView()

    init(surface: String, autoStart: Bool) {
        self.surface = surface
        self.autoStart = autoStart
        super.init(frame: .zero)
        wantsLayer = true
        layer?.backgroundColor = NSColor.black.cgColor
        overlayView.wantsLayer = true
        overlayView.layer?.backgroundColor = NSColor.black.cgColor
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        nil
    }

    override var isFlipped: Bool {
        true
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        DirectStreamTelemetry.record(
            component: "direct-video",
            event: "view_host_state",
            stream: Go2RTCRelayController.mainStreamName,
            surface: surface,
            detail: hostStateDetail(reason: "view_did_move_to_window")
        )
        if window == nil {
            deferredStartScheduled = false
            parkSession(reason: "view_removed_from_window")
        } else if autoStart {
            startIfVisible()
        }
    }

    override func layout() {
        super.layout()
        session?.webView.frame = bounds
        overlayView.frame = bounds
        if autoStart, session == nil {
            startIfVisible()
        }
    }

    func startIfVisible() {
        guard let window else { return }
        guard window.isVisible else {
            deferStart(reason: "hidden_window")
            return
        }
        if session != nil {
            if let webView = session?.webView {
                install(webView: webView)
            }
            DirectStreamTelemetry.record(
                component: "direct-video",
                event: "visible_session_reused",
                stream: Go2RTCRelayController.mainStreamName,
                surface: surface,
                detail: currentGenerationDetail()
            )
            applyPendingClipPath()
            if hasRevealedFrame {
                overlayView.isHidden = true
                if lastSnapshotOpenTime != lastOpenTime {
                    lastSnapshotOpenTime = lastOpenTime
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { [weak self] in
                        self?.recordWebViewSnapshot(reason: "attach_revealed")
                    }
                }
            } else {
                showOverlay()
            }
            return
        }
        guard bounds.width > 1, bounds.height > 1 else {
            deferStart(reason: "empty_bounds")
            return
        }
        deferredStartScheduled = false
        startVisibleSession(reason: "visible_start")
    }

    func warm(size: CGSize) {
        if session != nil {
            DirectStreamTelemetry.record(
                component: "direct-video",
                event: "warm_session_already_running",
                stream: Go2RTCRelayController.mainStreamName,
                surface: surface,
                detail: currentGenerationDetail()
            )
            return
        }
        let warmSize = NSSize(width: max(size.width, 320), height: max(size.height, 180))
        if bounds.width <= 1 || bounds.height <= 1 {
            frame = NSRect(origin: frame.origin, size: warmSize)
        }
        startVisibleSession(reason: "warm_start")
    }

    func markOpen() {
        lastOpenTime = ProcessInfo.processInfo.systemUptime
        lastSnapshotOpenTime = nil
    }

    private func deferStart(reason: String) {
        guard !deferredStartScheduled else { return }
        deferredStartScheduled = true
        DirectStreamTelemetry.record(
            component: "direct-video",
            event: "visible_session_deferred",
            stream: Go2RTCRelayController.mainStreamName,
            surface: surface,
            detail: hostStateDetail(reason: reason)
        )
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { [weak self] in
            guard let self else { return }
            self.deferredStartScheduled = false
            if self.window?.isVisible == true || reason == "empty_bounds" {
                self.startIfVisible()
            }
        }
    }

    func stopVisibleSession(reason: String) {
        guard let session else { return }
        DirectStreamTelemetry.record(
            component: "direct-video",
            event: "visible_session_stopping",
            stream: Go2RTCRelayController.mainStreamName,
            surface: surface,
            detail: "generation=\(session.generation) reason=\(reason)"
        )
        let webView = session.webView
        webView.evaluateJavaScript(Self.stopJavaScript())
        webView.stopLoading()
        webView.configuration.userContentController.removeScriptMessageHandler(forName: "cambarVideoEvent")
        webView.removeFromSuperview()
        parkingWindow?.orderOut(nil)
        self.session = nil
        deferredStartScheduled = false
        hasRevealedFrame = false
        showOverlay()
    }

    func recordDOMState(reason: String) {
        guard let session else { return }
        let escapedReason = Self.jsString(reason)
        let js = """
        (function() {
          const root = document.querySelector('simple-video');
          const video = document.querySelector('video');
          const pc = window.__cambarPeerConnections && window.__cambarPeerConnections[window.__cambarPeerConnections.length - 1];
          const rect = (node) => {
            if (!node) return null;
            const r = node.getBoundingClientRect();
            return {x: Math.round(r.x), y: Math.round(r.y), width: Math.round(r.width), height: Math.round(r.height)};
          };
          const quality = video && video.getVideoPlaybackQuality ? video.getVideoPlaybackQuality() : null;
          const detail = JSON.stringify({
            reason: \(escapedReason),
            generation: '\(session.generation)',
            viewport: {width: window.innerWidth, height: window.innerHeight},
            documentVisibility: document.visibilityState,
            root: rect(root),
            video: rect(video),
            rootConnected: root ? root.isConnected : null,
            rootMode: root ? root.mode : null,
            readyState: video ? video.readyState : null,
            networkState: video ? video.networkState : null,
            paused: video ? video.paused : null,
            currentTime: video ? video.currentTime : null,
            videoWidth: video ? video.videoWidth : null,
            videoHeight: video ? video.videoHeight : null,
            decodedFrames: video ? video.webkitDecodedFrameCount : null,
            droppedFrames: video ? video.webkitDroppedFrameCount : null,
            totalVideoFrames: quality ? quality.totalVideoFrames : null,
            droppedVideoFrames: quality ? quality.droppedVideoFrames : null,
            pcConnectionState: pc ? pc.connectionState : null,
            pcIceConnectionState: pc ? pc.iceConnectionState : null,
            pcSignalingState: pc ? pc.signalingState : null
          });
          window.__cambarPost && window.__cambarPost({ name: 'visual_state', detail });
        })();
        """
        session.webView.evaluateJavaScript(js)
        DirectStreamTelemetry.record(
            component: "direct-video",
            event: "view_probe_requested",
            stream: Go2RTCRelayController.mainStreamName,
            surface: surface,
            detail: "generation=\(session.generation) reason=\(reason)"
        )
    }

    func applyClipPath(_ svgPath: String) {
        pendingClipPath = svgPath
        applyPendingClipPath()
    }

    func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
        guard message.name == "cambarVideoEvent",
              let body = message.body as? [String: Any],
              let event = body["name"] as? String else {
            return
        }
        let generation = body["generation"] as? String
        guard generation == session?.generation else {
            DirectStreamTelemetry.record(
                component: "direct-video",
                event: "stale_video_event_ignored",
                stream: Go2RTCRelayController.mainStreamName,
                surface: surface,
                detail: "event=\(event)"
            )
            return
        }
        DirectStreamTelemetry.record(
            component: "direct-video",
            event: event,
            stream: Go2RTCRelayController.mainStreamName,
            surface: surface,
            elapsedMilliseconds: body["elapsed_ms"] as? Int,
            detail: body["detail"] as? String
        )
        if event == "fresh_enough" {
            revealVideo()
        }
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        DirectStreamTelemetry.record(
            component: "direct-video",
            event: "navigation_finished",
            stream: Go2RTCRelayController.mainStreamName,
            surface: surface,
            detail: currentGenerationDetail()
        )
        applyPendingClipPath()
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        DirectStreamTelemetry.record(
            component: "direct-video",
            event: "navigation_failed",
            stream: Go2RTCRelayController.mainStreamName,
            surface: surface,
            detail: "\(currentGenerationDetail()) error=\(error.localizedDescription)"
        )
    }

    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        DirectStreamTelemetry.record(
            component: "direct-video",
            event: "provisional_navigation_failed",
            stream: Go2RTCRelayController.mainStreamName,
            surface: surface,
            detail: "\(currentGenerationDetail()) error=\(error.localizedDescription)"
        )
    }

    private func startVisibleSession(reason: String) {
        let generation = UUID().uuidString
        let configuration = WKWebViewConfiguration()
        configuration.allowsAirPlayForMediaPlayback = false
        configuration.mediaTypesRequiringUserActionForPlayback = []
        configuration.userContentController.add(self, name: "cambarVideoEvent")

        let webView = WKWebView(frame: bounds, configuration: configuration)
        webView.setValue(false, forKey: "drawsBackground")
        webView.navigationDelegate = self
        webView.autoresizingMask = [.width, .height]
        webView.translatesAutoresizingMaskIntoConstraints = true
        webView.frame = bounds

        session = VideoSession(generation: generation, webView: webView)
        hasRevealedFrame = false
        if window == nil {
            park(webView: webView, reason: reason)
        } else {
            install(webView: webView)
            showOverlay()
        }
        DirectStreamTelemetry.record(
            component: "direct-video",
            event: "visible_session_started",
            stream: Go2RTCRelayController.mainStreamName,
            surface: surface,
            detail: "\(hostStateDetail(reason: reason)) generation=\(generation)"
        )
        webView.loadHTMLString(Self.html(generation: generation), baseURL: URL(string: "http://127.0.0.1:1984/"))
    }

    private func parkSession(reason: String) {
        guard let webView = session?.webView else { return }
        park(webView: webView, reason: reason)
    }

    private func park(webView: WKWebView, reason: String) {
        let parkingWindow = parkingWindow ?? makeParkingWindow()
        self.parkingWindow = parkingWindow
        webView.removeFromSuperview()
        webView.frame = parkingView.bounds
        parkingView.addSubview(webView)
        parkingWindow.orderFront(nil)
        DirectStreamTelemetry.record(
            component: "direct-video",
            event: "visible_session_parked",
            stream: Go2RTCRelayController.mainStreamName,
            surface: surface,
            detail: "\(currentGenerationDetail()) reason=\(reason) frame=\(Int(parkingWindow.frame.width))x\(Int(parkingWindow.frame.height))"
        )
    }

    private func makeParkingWindow() -> NSWindow {
        parkingView.wantsLayer = true
        parkingView.layer?.backgroundColor = NSColor.black.cgColor
        let window = NSWindow(
            contentRect: NSRect(x: -20_000, y: -20_000, width: 16, height: 9),
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        window.backgroundColor = .black
        window.isOpaque = true
        window.alphaValue = 0.01
        window.ignoresMouseEvents = true
        window.hasShadow = false
        window.level = .normal
        window.collectionBehavior = [.stationary, .ignoresCycle]
        window.contentView = parkingView
        return window
    }

    private func install(webView: WKWebView) {
        webView.removeFromSuperview()
        addSubview(webView, positioned: .below, relativeTo: overlayView.superview == nil ? nil : overlayView)
        if overlayView.superview == nil {
            addSubview(overlayView)
        } else {
            overlayView.removeFromSuperview()
            addSubview(overlayView)
        }
        needsLayout = true
    }

    private func showOverlay() {
        if overlayView.superview == nil {
            addSubview(overlayView)
        }
        overlayView.isHidden = false
        overlayView.frame = bounds
    }

    private func revealVideo() {
        hasRevealedFrame = true
        overlayView.isHidden = true
        DirectStreamTelemetry.record(
            component: "direct-video",
            event: "visible_session_revealed",
            stream: Go2RTCRelayController.mainStreamName,
            surface: surface,
            detail: currentGenerationDetail()
        )
        guard window != nil else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { [weak self] in
            self?.recordWebViewSnapshot(reason: "after_reveal")
        }
    }

    private func recordWebViewSnapshot(reason: String) {
        guard let session else { return }
        let generation = session.generation
        let configuration = WKSnapshotConfiguration()
        configuration.rect = bounds
        session.webView.takeSnapshot(with: configuration) { image, error in
            Task { @MainActor [weak self] in
                guard let self else { return }
                guard self.session?.generation == generation else {
                    DirectStreamTelemetry.record(
                        component: "direct-video",
                        event: "stale_webview_snapshot_ignored",
                        stream: Go2RTCRelayController.mainStreamName,
                        surface: self.surface,
                        detail: "generation=\(generation) reason=\(reason)"
                    )
                    return
                }
                if let error {
                    DirectStreamTelemetry.record(
                        component: "direct-video",
                        event: "webview_snapshot_failed",
                        stream: Go2RTCRelayController.mainStreamName,
                        surface: self.surface,
                        detail: "generation=\(generation) reason=\(reason) error=\(error.localizedDescription)"
                    )
                    return
                }
                guard let image,
                      let tiff = image.tiffRepresentation,
                      let bitmap = NSBitmapImageRep(data: tiff) else {
                    DirectStreamTelemetry.record(
                        component: "direct-video",
                        event: "webview_snapshot_failed",
                        stream: Go2RTCRelayController.mainStreamName,
                        surface: self.surface,
                        detail: "generation=\(generation) reason=\(reason) error=no_image"
                    )
                    return
                }
                let sample = Self.pixelRatios(in: bitmap)
                let openElapsed: String
                if let lastOpenTime = self.lastOpenTime {
                    let elapsed = Int((ProcessInfo.processInfo.systemUptime - lastOpenTime) * 1000)
                    openElapsed = " open_elapsed_ms=\(elapsed)"
                } else {
                    openElapsed = ""
                }
                DirectStreamTelemetry.record(
                    component: "direct-video",
                    event: "webview_snapshot_sample",
                    stream: Go2RTCRelayController.mainStreamName,
                    surface: self.surface,
                    detail: "generation=\(generation) reason=\(reason)\(openElapsed) white=\(String(format: "%.4f", sample.white)) dark=\(String(format: "%.4f", sample.dark)) color=\(String(format: "%.4f", sample.color)) pixels=\(sample.total)"
                )
            }
        }
    }

    private func applyPendingClipPath() {
        guard let svgPath = pendingClipPath,
              let session else { return }
        let escaped = svgPath.replacingOccurrences(of: "'", with: "\\'")
        let js = """
        (function() {
          const path = '\(escaped)';
          let style = document.getElementById('cambar-clip-style');
          if (!style) {
            style = document.createElement('style');
            style.id = 'cambar-clip-style';
            document.head.appendChild(style);
          }
          style.textContent = `simple-video, video { clip-path: path('${path}'); border-radius: 0 !important; }`;
        })();
        """
        session.webView.evaluateJavaScript(js)
    }

    private func currentGenerationDetail() -> String {
        if let session {
            return "generation=\(session.generation)"
        }
        return "generation=none"
    }

    private func hostStateDetail(reason: String) -> String {
        let windowState: String
        if let window {
            windowState = "window=true visible=\(window.isVisible) key=\(window.isKeyWindow) frame=\(Int(window.frame.width))x\(Int(window.frame.height))"
        } else {
            windowState = "window=false"
        }
        return "reason=\(reason) \(windowState) bounds=\(Int(bounds.width))x\(Int(bounds.height)) autoStart=\(autoStart)"
    }

    private static func jsString(_ value: String) -> String {
        guard let data = try? JSONSerialization.data(withJSONObject: [value]),
              let encoded = String(data: data, encoding: .utf8),
              encoded.count >= 2 else {
            return "''"
        }
        return String(encoded.dropFirst().dropLast())
    }

    private struct VideoSession {
        let generation: String
        let webView: WKWebView
    }
}
