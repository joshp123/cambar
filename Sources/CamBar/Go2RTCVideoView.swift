import AppKit
import CamBarCore
import WebKit

@MainActor
final class CameraPlaybackController: NSObject, WKNavigationDelegate, WKScriptMessageHandler {
    enum Surface: String, CaseIterable, Sendable {
        case menu
        case window
    }

    enum Phase: Equatable {
        case idle
        case warming
        case warm
        case opening(Surface)
        case playing(Surface)
        case retrying
    }

    var onPhaseChange: ((Phase) -> Void)?

    private(set) var phase: Phase = .idle {
        didSet {
            guard phase != oldValue else { return }
            onPhaseChange?(phase)
        }
    }

    private var relayReady = false
    private var session: VideoSession?
    private var activeSurface: Surface?
    private var containers: [Surface: WeakVideoContainer] = [:]
    private var openToken: String?
    private var openStartedAt: TimeInterval?
    private var restartCount = 0
    private var startupWatchdog: Task<Void, Never>?
    private var openWatchdog: Task<Void, Never>?
    private var restartTask: Task<Void, Never>?
    private let parkingView = CameraVideoContainerView(cornerRadius: 0)
    private lazy var parkingWindow = makeParkingWindow()
    private let diagnosticsEnabled = ProcessInfo.processInfo.environment["CAMBAR_DIAGNOSTICS"] == "1"

    func setRelayReady(_ ready: Bool, warmSize: CGSize) {
        relayReady = ready
        if ready {
            warm(size: warmSize)
        } else {
            tearDownSession(reason: "relay_unavailable")
            phase = .idle
        }
    }

    func register(_ container: CameraVideoContainerView, for surface: Surface) {
        containers[surface] = WeakVideoContainer(container)
        if activeSurface == surface, let webView = session?.webView {
            attach(webView, to: container)
        }
    }

    func unregister(_ container: CameraVideoContainerView, for surface: Surface) {
        guard containers[surface]?.view === container else { return }
        containers[surface] = nil
        if activeSurface == surface {
            parkSession()
        }
    }

    func warm(size: CGSize) {
        guard relayReady else { return }
        parkingView.frame = NSRect(origin: .zero, size: CGSize(width: max(size.width, 320), height: max(size.height, 180)))
        parkingWindow.setContentSize(parkingView.frame.size)
        guard session == nil else {
            if activeSurface == nil {
                parkSession()
            }
            return
        }
        startSession()
    }

    func show(_ surface: Surface) {
        activeSurface = surface
        let token = UUID().uuidString
        openToken = token
        openStartedAt = ProcessInfo.processInfo.systemUptime
        phase = .opening(surface)

        guard relayReady else { return }
        if session == nil {
            startSession()
        }
        guard let session else { return }
        if let container = containers[surface]?.view {
            attach(session.webView, to: container)
        }
        requestFreshOpenFrame(token: token)
        startOpenWatchdog(token: token)
    }

    func hide(_ surface: Surface) {
        guard activeSurface == surface else { return }
        activeSurface = nil
        openToken = nil
        openStartedAt = nil
        openWatchdog?.cancel()
        openWatchdog = nil
        parkSession()
        phase = session?.hasFrame == true ? .warm : .warming
    }

    func retryNow() {
        restartCount = 0
        recover(reason: "manual_retry")
    }

    func shutdown() {
        relayReady = false
        activeSurface = nil
        restartTask?.cancel()
        tearDownSession(reason: "shutdown")
        parkingWindow.orderOut(nil)
        phase = .idle
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
            surface: activeSurface?.rawValue,
            elapsedMilliseconds: elapsed,
            detail: body["detail"] as? String
        )

        switch event {
        case "first_frame":
            session?.hasFrame = true
            restartCount = 0
            startupWatchdog?.cancel()
            startupWatchdog = nil
            if activeSurface == nil {
                phase = .warm
            }
        case "open_frame":
            guard let token = body["token"] as? String, token == openToken,
                  let surface = activeSurface else { return }
            openToken = nil
            openWatchdog?.cancel()
            openWatchdog = nil
            containers[surface]?.view?.showCover(false)
            phase = .playing(surface)
            let openElapsed = openStartedAt.map {
                Int((ProcessInfo.processInfo.systemUptime - $0) * 1_000)
            }
            DirectStreamTelemetry.record(
                component: "video",
                event: "live_view",
                surface: surface.rawValue,
                elapsedMilliseconds: openElapsed
            )
            if diagnosticsEnabled {
                recordSnapshot(surface: surface, openElapsed: openElapsed)
            }
        case "video_error", "frame_stalled":
            recover(reason: event)
        default:
            break
        }
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        guard webView === session?.webView else { return }
        if let openToken {
            requestFreshOpenFrame(token: openToken)
        }
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        guard webView === session?.webView else { return }
        recover(reason: "navigation_failed")
    }

    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        guard webView === session?.webView else { return }
        recover(reason: "provisional_navigation_failed")
    }

    private func startSession() {
        guard relayReady, session == nil else { return }
        restartTask?.cancel()
        restartTask = nil
        let generation = UUID().uuidString
        let configuration = WKWebViewConfiguration()
        configuration.allowsAirPlayForMediaPlayback = false
        configuration.mediaTypesRequiringUserActionForPlayback = []
        configuration.userContentController.add(self, name: "cambarVideoEvent")

        let webView = CameraWebView(frame: parkingView.bounds, configuration: configuration)
        webView.setValue(false, forKey: "drawsBackground")
        webView.navigationDelegate = self
        webView.autoresizingMask = [.width, .height]
        session = VideoSession(generation: generation, webView: webView)
        phase = activeSurface.map(Phase.opening) ?? .warming

        if let activeSurface, let container = containers[activeSurface]?.view {
            attach(webView, to: container)
        } else {
            attach(webView, to: parkingView)
            parkingWindow.orderFront(nil)
        }

        webView.loadHTMLString(Self.html(generation: generation), baseURL: URL(string: "http://127.0.0.1:1984/"))
        startStartupWatchdog(generation: generation)
    }

    private func attach(_ webView: WKWebView, to container: CameraVideoContainerView) {
        container.attach(webView)
        if container !== parkingView {
            container.showCover(true)
        }
    }

    private func parkSession() {
        guard let webView = session?.webView else { return }
        attach(webView, to: parkingView)
        parkingWindow.orderFront(nil)
    }

    private func requestFreshOpenFrame(token: String) {
        guard let webView = session?.webView else { return }
        let encoded = Self.javaScriptString(token)
        webView.evaluateJavaScript("window.__cambarMarkOpen && window.__cambarMarkOpen(\(encoded));")
    }

    private func startStartupWatchdog(generation: String) {
        startupWatchdog?.cancel()
        startupWatchdog = Task { [weak self] in
            try? await Task.sleep(for: .seconds(4))
            guard !Task.isCancelled, let self,
                  self.session?.generation == generation,
                  self.session?.hasFrame != true else { return }
            self.recover(reason: "startup_timeout")
        }
    }

    private func startOpenWatchdog(token: String) {
        openWatchdog?.cancel()
        openWatchdog = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(500))
            guard !Task.isCancelled, let self, self.openToken == token else { return }
            DirectStreamTelemetry.record(
                component: "video",
                event: "open_slow",
                surface: self.activeSurface?.rawValue,
                elapsedMilliseconds: 500
            )
            self.requestFreshOpenFrame(token: token)
            try? await Task.sleep(for: .milliseconds(500))
            guard !Task.isCancelled, self.openToken == token else { return }
            self.recover(reason: "open_frame_timeout")
        }
    }

    private func recover(reason: String) {
        guard relayReady else { return }
        DirectStreamTelemetry.record(component: "video", event: "recover", detail: "reason=\(reason)")
        tearDownSession(reason: reason)
        restartCount += 1
        phase = .retrying
        let delays: [TimeInterval] = [0.1, 0.5, 2, 5]
        let delay = delays[min(restartCount - 1, delays.count - 1)]
        restartTask?.cancel()
        restartTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(delay))
            guard !Task.isCancelled, let self, self.relayReady else { return }
            self.startSession()
            if let token = self.openToken {
                self.startOpenWatchdog(token: token)
            }
        }
    }

    private func tearDownSession(reason: String) {
        startupWatchdog?.cancel()
        startupWatchdog = nil
        openWatchdog?.cancel()
        openWatchdog = nil
        guard let session else { return }
        DirectStreamTelemetry.record(component: "video", event: "session_stopped", detail: "reason=\(reason)")
        session.webView.evaluateJavaScript(Self.stopJavaScript())
        session.webView.stopLoading()
        session.webView.navigationDelegate = nil
        session.webView.configuration.userContentController.removeScriptMessageHandler(forName: "cambarVideoEvent")
        session.webView.removeFromSuperview()
        self.session = nil
    }

    private func makeParkingWindow() -> NSWindow {
        let window = NSWindow(
            contentRect: NSRect(x: -20_000, y: -20_000, width: 320, height: 180),
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        window.backgroundColor = .black
        window.isOpaque = true
        window.alphaValue = 0.01
        window.ignoresMouseEvents = true
        window.hasShadow = false
        window.collectionBehavior = [.stationary, .ignoresCycle]
        window.contentView = parkingView
        return window
    }

    private func recordSnapshot(surface: Surface, openElapsed: Int?) {
        guard let webView = session?.webView else { return }
        let configuration = WKSnapshotConfiguration()
        configuration.rect = webView.bounds
        webView.takeSnapshot(with: configuration) { image, _ in
            Task { @MainActor in
                guard let image,
                      let tiff = image.tiffRepresentation,
                      let bitmap = NSBitmapImageRep(data: tiff) else { return }
                let ratios = Self.pixelRatios(bitmap)
                DirectStreamTelemetry.record(
                    component: "video",
                    event: "webview_snapshot_sample",
                    surface: surface.rawValue,
                    elapsedMilliseconds: openElapsed,
                    detail: "white=\(ratios.white) dark=\(ratios.dark) color=\(ratios.color) pixels=\(ratios.total)"
                )
            }
        }
    }

    private static func pixelRatios(_ bitmap: NSBitmapImageRep) -> (white: Double, dark: Double, color: Double, total: Int) {
        let step = max(1, min(bitmap.pixelsWide, bitmap.pixelsHigh) / 300)
        var total = 0
        var white = 0
        var dark = 0
        for y in stride(from: 0, to: bitmap.pixelsHigh, by: step) {
            for x in stride(from: 0, to: bitmap.pixelsWide, by: step) {
                guard let color = bitmap.colorAt(x: x, y: y)?.usingColorSpace(.sRGB), color.alphaComponent > 0.1 else { continue }
                total += 1
                if color.redComponent > 0.92, color.greenComponent > 0.92, color.blueComponent > 0.92 {
                    white += 1
                } else if color.redComponent < 0.05, color.greenComponent < 0.05, color.blueComponent < 0.05 {
                    dark += 1
                }
            }
        }
        guard total > 0 else { return (1, 0, 0, 0) }
        return (
            Double(white) / Double(total),
            Double(dark) / Double(total),
            Double(total - white - dark) / Double(total),
            total
        )
    }

    private static func javaScriptString(_ value: String) -> String {
        guard let data = try? JSONSerialization.data(withJSONObject: [value]),
              let encoded = String(data: data, encoding: .utf8) else { return "''" }
        return String(encoded.dropFirst().dropLast())
    }

    private final class VideoSession {
        let generation: String
        let webView: WKWebView
        var hasFrame = false

        init(generation: String, webView: WKWebView) {
            self.generation = generation
            self.webView = webView
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

    init(cornerRadius: CGFloat) {
        super.init(frame: .zero)
        wantsLayer = true
        layer?.backgroundColor = NSColor.black.cgColor
        layer?.cornerRadius = cornerRadius
        layer?.masksToBounds = true
        cover.wantsLayer = true
        cover.layer?.backgroundColor = NSColor.black.cgColor
        addSubview(cover)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }

    override var isFlipped: Bool { true }

    override func layout() {
        super.layout()
        subviews.first { $0 is WKWebView }?.frame = bounds
        cover.frame = bounds
    }

    func setCornerRadius(_ radius: CGFloat) {
        layer?.cornerRadius = radius
    }

    func attach(_ webView: WKWebView) {
        webView.removeFromSuperview()
        addSubview(webView, positioned: .below, relativeTo: cover)
        webView.frame = bounds
        needsLayout = true
    }

    func showCover(_ show: Bool) {
        cover.isHidden = !show
    }
}

private final class WeakVideoContainer {
    weak var view: CameraVideoContainerView?

    init(_ view: CameraVideoContainerView) {
        self.view = view
    }
}
