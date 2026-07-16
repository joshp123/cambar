import AppKit
import CamBarCore
import WebKit

@MainActor
final class CameraPlaybackController: NSObject, WKNavigationDelegate, WKScriptMessageHandler {
    enum Surface: String, Sendable {
        case menu
        case window
    }

    let container: CameraVideoContainerView

    private let surface: Surface
    private var relayAvailable = false
    private var relayReady = false
    private var isVisible = false
    private var isSuspended = false
    private var session: VideoSession?
    private var openToken: String?
    private var openStartedAt: TimeInterval?
    private var restartCount = 0
    private var openWatchdog: Task<Void, Never>?
    private var stallWatchdog: Task<Void, Never>?
    private var restartTask: Task<Void, Never>?

    init(surface: Surface, cornerStyle: CameraVideoCornerStyle) {
        self.surface = surface
        self.container = CameraVideoContainerView(cornerStyle: cornerStyle)
        super.init()
    }

    func setRelayState(available: Bool, ready: Bool) {
        relayAvailable = available
        relayReady = ready
        guard available else {
            if isVisible, openToken == nil {
                beginPresentation()
            }
            tearDownSession(reason: "relay_unavailable")
            return
        }
        if ready, isVisible {
            resumeOpen()
        }
    }

    func show() {
        isSuspended = false
        isVisible = true
        beginPresentation()
        guard relayReady else { return }
        resumeOpen()
    }

    func hide() {
        isVisible = false
        openToken = nil
        openStartedAt = nil
        restartTask?.cancel()
        restartTask = nil
        tearDownSession(reason: "hidden")
        container.showCover(true, animated: false)
    }

    func suspend() {
        isSuspended = true
        hide()
    }

    func resumeAfterPopout() {
        guard isSuspended else { return }
        isSuspended = false
    }

    func retryNow() {
        restartCount = 0
        recover(reason: "manual_retry")
    }

    func shutdown() {
        relayAvailable = false
        relayReady = false
        isVisible = false
        isSuspended = true
        restartTask?.cancel()
        tearDownSession(reason: "shutdown")
    }

    private func resumeOpen() {
        if session == nil {
            startSession()
        }
        guard session != nil, let openToken else { return }
        container.showCover(true)
        setJavaScriptVisibility(true)
        requestFreshOpenFrame(token: openToken)
        startOpenWatchdog(token: openToken)
    }

    private func beginPresentation() {
        openToken = UUID().uuidString
        openStartedAt = ProcessInfo.processInfo.systemUptime
        container.showCover(true)
        DirectStreamTelemetry.record(
            component: "video",
            event: "presentation_started",
            surface: surface.rawValue
        )
    }

    func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
        guard message.name == "cambarVideoEvent",
              let body = message.body as? [String: Any],
              let event = body["event"] as? String,
              let generation = body["generation"] as? String,
              generation == session?.generation else {
            return
        }

        let elapsed = body["elapsed_ms"] as? Int
        DirectStreamTelemetry.record(
            component: "video",
            event: event,
            stream: Go2RTCRelayController.mainStreamName,
            surface: surface.rawValue,
            elapsedMilliseconds: elapsed,
            detail: body["detail"] as? String
        )

        switch event {
        case "first_frame":
            if isVisible, let openToken {
                requestFreshOpenFrame(token: openToken)
            }
        case "frame_candidate":
            acceptOpenFrame(body)
        case "frame_resumed":
            stallWatchdog?.cancel()
            stallWatchdog = nil
        case "frame_stalled":
            if isVisible {
                handleVisibleStall(generation: generation)
            }
        case "video_error":
            recover(reason: event)
        default:
            break
        }
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        recordNavigationPhase("navigation_finished", webView: webView)
        guard webView === session?.webView, isVisible, let openToken else { return }
        setJavaScriptVisibility(true)
        requestFreshOpenFrame(token: openToken)
    }

    func webView(_ webView: WKWebView, didCommit navigation: WKNavigation!) {
        recordNavigationPhase("navigation_committed", webView: webView)
    }

    func webView(_ webView: WKWebView, didStartProvisionalNavigation navigation: WKNavigation!) {
        recordNavigationPhase("navigation_started", webView: webView)
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        guard webView === session?.webView else { return }
        recordNavigationPhase("navigation_failed", webView: webView)
        recover(reason: "navigation_failed")
    }

    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        guard webView === session?.webView else { return }
        recordNavigationPhase("provisional_navigation_failed", webView: webView)
        recover(reason: "provisional_navigation_failed")
    }

    private func acceptOpenFrame(_ body: [String: Any]) {
        guard isVisible,
              let token = body["token"] as? String,
              token == openToken else { return }
        openToken = nil
        restartCount = 0
        openWatchdog?.cancel()
        openWatchdog = nil
        container.showCover(false)
        let elapsed = openStartedAt.map {
            Int((ProcessInfo.processInfo.systemUptime - $0) * 1_000)
        }
        DirectStreamTelemetry.record(
            component: "video",
            event: "live_view",
            surface: surface.rawValue,
            elapsedMilliseconds: elapsed
        )
    }

    private func startSession() {
        guard relayAvailable, relayReady, isVisible, !isSuspended, session == nil else { return }
        restartTask?.cancel()
        restartTask = nil
        let generation = UUID().uuidString
        let configuration = WKWebViewConfiguration()
        configuration.allowsAirPlayForMediaPlayback = false
        configuration.mediaTypesRequiringUserActionForPlayback = []
        configuration.userContentController.add(self, name: "cambarVideoEvent")

        let webView = CameraWebView(frame: container.bounds, configuration: configuration)
        webView.setValue(false, forKey: "drawsBackground")
        webView.navigationDelegate = self
        webView.autoresizingMask = [.width, .height]
        container.attach(webView)
        session = VideoSession(
            generation: generation,
            webView: webView,
            startedAt: ProcessInfo.processInfo.systemUptime
        )
        DirectStreamTelemetry.record(component: "video", event: "session_started", surface: surface.rawValue)
        webView.loadHTMLString(Self.html(generation: generation), baseURL: URL(string: "http://127.0.0.1:1984/"))
    }

    private func requestFreshOpenFrame(token: String) {
        guard let webView = session?.webView else { return }
        let encoded = Self.javaScriptString(token)
        webView.evaluateJavaScript("window.__cambarMarkOpen && window.__cambarMarkOpen(\(encoded));")
    }

    private func setJavaScriptVisibility(_ visible: Bool) {
        session?.webView.evaluateJavaScript(
            "window.__cambarSetVisible && window.__cambarSetVisible(\(visible ? "true" : "false"));"
        )
    }

    private func startOpenWatchdog(token: String) {
        guard openWatchdog == nil else { return }
        openWatchdog = Task { [weak self] in
            try? await Task.sleep(for: .seconds(3))
            guard let self else { return }
            guard !Task.isCancelled, self.openToken == token, self.isVisible else { return }
            self.recover(reason: "visible_frame_timeout")
        }
    }

    private func handleVisibleStall(generation: String) {
        guard stallWatchdog == nil else { return }
        session?.webView.evaluateJavaScript("window.__cambarResume && window.__cambarResume();")
        stallWatchdog = Task { [weak self] in
            try? await Task.sleep(for: .seconds(3))
            guard !Task.isCancelled, let self,
                  self.isVisible,
                  self.session?.generation == generation else { return }
            self.stallWatchdog = nil
            self.recover(reason: "visible_frame_stalled")
        }
    }

    private func recover(reason: String) {
        guard relayAvailable, relayReady, isVisible, !isSuspended else { return }
        DirectStreamTelemetry.record(
            component: "video",
            event: "recover",
            surface: surface.rawValue,
            detail: "reason=\(reason)"
        )
        if isVisible {
            beginPresentation()
        }
        tearDownSession(reason: reason)
        restartCount += 1
        let delays: [TimeInterval] = [0.1, 0.5, 2, 5]
        let delay = delays[min(restartCount - 1, delays.count - 1)]
        restartTask?.cancel()
        restartTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(delay))
            guard !Task.isCancelled,
                  let self,
                  self.relayAvailable,
                  self.relayReady,
                  self.isVisible,
                  !self.isSuspended else { return }
            self.startSession()
            self.resumeOpen()
        }
    }

    private func recordNavigationPhase(_ event: String, webView: WKWebView) {
        guard webView === session?.webView else { return }
        let elapsed = session.map {
            Int((ProcessInfo.processInfo.systemUptime - $0.startedAt) * 1_000)
        }
        DirectStreamTelemetry.record(
            component: "video",
            event: event,
            surface: surface.rawValue,
            elapsedMilliseconds: elapsed
        )
    }

    private func tearDownSession(reason: String) {
        openWatchdog?.cancel()
        openWatchdog = nil
        stallWatchdog?.cancel()
        stallWatchdog = nil
        guard let session else { return }
        DirectStreamTelemetry.record(
            component: "video",
            event: "session_stopped",
            surface: surface.rawValue,
            detail: "reason=\(reason)"
        )
        session.webView.evaluateJavaScript(Self.stopJavaScript())
        session.webView.stopLoading()
        session.webView.navigationDelegate = nil
        session.webView.configuration.userContentController.removeScriptMessageHandler(forName: "cambarVideoEvent")
        session.webView.removeFromSuperview()
        self.session = nil
    }

    private static func javaScriptString(_ value: String) -> String {
        guard let data = try? JSONSerialization.data(withJSONObject: [value]),
              let encoded = String(data: data, encoding: .utf8) else { return "''" }
        return String(encoded.dropFirst().dropLast())
    }

    private final class VideoSession {
        let generation: String
        let webView: WKWebView
        let startedAt: TimeInterval

        init(generation: String, webView: WKWebView, startedAt: TimeInterval) {
            self.generation = generation
            self.webView = webView
            self.startedAt = startedAt
        }
    }
}

private final class CameraWebView: WKWebView {
    override func menu(for event: NSEvent) -> NSMenu? {
        nil
    }
}

@MainActor
final class CameraVideoContainerView: NSView {
    private let cover = NSView()
    private let progressIndicator = NSProgressIndicator()
    private let loadingLabel = NSTextField(labelWithString: "Connecting…")
    private var cornerStyle: CameraVideoCornerStyle

    init(cornerStyle: CameraVideoCornerStyle) {
        self.cornerStyle = cornerStyle
        super.init(frame: .zero)
        wantsLayer = true
        layer?.backgroundColor = NSColor.black.cgColor
        layer?.cornerCurve = .continuous
        layer?.masksToBounds = true
        cover.wantsLayer = true
        cover.layer?.backgroundColor = NSColor.black.cgColor
        progressIndicator.style = .spinning
        progressIndicator.controlSize = .small
        loadingLabel.font = .systemFont(ofSize: 13, weight: .medium)
        loadingLabel.textColor = NSColor.white.withAlphaComponent(0.78)
        loadingLabel.alignment = .center
        cover.addSubview(progressIndicator)
        cover.addSubview(loadingLabel)
        addSubview(cover)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }

    override var isFlipped: Bool { true }

    override var cornerConfiguration: NSViewCornerConfiguration? {
        switch cornerStyle {
        case .square:
            .uniformCorners(radius: .fixed(0))
        case .containerConcentric:
            .uniformCorners(radius: .containerConcentric)
        }
    }

    override func viewDidChangeEffectiveCornerRadii() {
        super.viewDidChangeEffectiveCornerRadii()
        applyCornerRadius()
    }

    override func layout() {
        super.layout()
        applyCornerRadius()
        subviews.first { $0 is WKWebView }?.frame = bounds
        cover.frame = bounds
        progressIndicator.sizeToFit()
        progressIndicator.frame.origin = NSPoint(
            x: floor((cover.bounds.width - progressIndicator.frame.width) / 2),
            y: floor((cover.bounds.height - progressIndicator.frame.height) / 2) - 14
        )
        loadingLabel.sizeToFit()
        loadingLabel.frame.origin = NSPoint(
            x: floor((cover.bounds.width - loadingLabel.frame.width) / 2),
            y: progressIndicator.frame.maxY + 9
        )
    }

    func setCornerStyle(_ style: CameraVideoCornerStyle) {
        guard style != cornerStyle else { return }
        cornerStyle = style
        invalidateCornerConfiguration()
    }

    func attach(_ webView: WKWebView) {
        guard webView.superview !== self else { return }
        addSubview(webView, positioned: .below, relativeTo: cover)
        webView.frame = bounds
        needsLayout = true
    }

    func showCover(_ show: Bool, animated: Bool = true) {
        cover.isHidden = !show
        if show, animated {
            progressIndicator.startAnimation(nil)
        } else {
            progressIndicator.stopAnimation(nil)
        }
    }

    private func applyCornerRadius() {
        layer?.cornerRadius = effectiveCornerRadii?.topLeft ?? 0
    }
}
