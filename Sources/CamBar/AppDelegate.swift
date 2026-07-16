import AppKit
import CamBarCore
import SwiftUI

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSPopoverDelegate {
    private let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
    private let popover = NSPopover()
    private let loginItemController = LoginItemController()
    private let relayController = Go2RTCRelayController()
    private var windowController: CameraWindowController?
    private var wakeObserver: NSObjectProtocol?
    private var menuProbeToken = 0
    private var debugPopoverRemaining = 0
    private var debugPopoverVisibleSeconds: TimeInterval = 2
    private var didRunDebugHooks = false
    private let nativeVideoSize = CGSize(width: 2688, height: 1520)
    private lazy var uiState = CamBarUIState(videoSize: bestPopoverVideoSize(anchorButton: statusItem.button))

    func applicationDidFinishLaunching(_ notification: Notification) {
        DirectStreamTelemetry.reset()
        DirectStreamTelemetry.record(component: "app", event: "launch")
        loginItemController.ensureRegistered()
        wakeObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didWakeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.refreshRelayAfterWake()
            }
        }
        if let button = statusItem.button {
            let image = NSImage(systemSymbolName: "video.fill", accessibilityDescription: "CamBar")
            image?.isTemplate = true
            button.image = image
            button.target = self
            button.action = #selector(togglePopover)
        }

        popover.delegate = self
        popover.behavior = .transient
        let initialPopoverSize = bestPopoverVideoSize(anchorButton: statusItem.button)
        uiState.videoSize = initialPopoverSize
        popover.contentSize = ContentView.contentSize(forVideoSize: initialPopoverSize)
        popover.contentViewController = NSHostingController(
            rootView: ContentView(
                state: uiState,
                onOpenWindow: { [weak self] in
                    self?.openWindow()
                }
            )
        )
        relayController.onStateChange = { [weak self] state in
            self?.relayStateDidChange(state)
        }
        relayController.start()
    }

    func applicationWillTerminate(_ notification: Notification) {
        if let wakeObserver {
            NSWorkspace.shared.notificationCenter.removeObserver(wakeObserver)
            self.wakeObserver = nil
        }
        relayController.stop()
    }

    private func refreshRelayAfterWake() {
        Go2RTCVideoView.stop(surface: "menu", reason: "relay_refresh")
        Go2RTCVideoView.stop(surface: "window", reason: "relay_refresh")
        uiState.relayAvailable = false
        uiState.videoSize = bestPopoverVideoSize(anchorButton: statusItem.button)
        relayController.restart()
    }

    private func relayStateDidChange(_ state: Go2RTCRelayController.State) {
        let ready = state == .ready
        if uiState.relayAvailable, !ready {
            Go2RTCVideoView.stop(surface: "menu", reason: "relay_unavailable")
            Go2RTCVideoView.stop(surface: "window", reason: "relay_unavailable")
        }
        uiState.relayAvailable = ready
        uiState.videoSize = bestPopoverVideoSize(anchorButton: statusItem.button)
        guard ready else { return }
        warmMenuVideo()
        runDebugHooksOnce()
    }

    private func runDebugHooksOnce() {
        guard !didRunDebugHooks else { return }
        didRunDebugHooks = true
        if ProcessInfo.processInfo.environment["CAMBAR_OPEN_WINDOW"] == "1" {
            DispatchQueue.main.asyncAfter(deadline: .now() + 3) { [weak self] in
                self?.openWindow()
            }
        }
        let debugPopoverDelay = TimeInterval(ProcessInfo.processInfo.environment["CAMBAR_DEBUG_POPOVER_START_DELAY_SECONDS"] ?? "1") ?? 1
        if ProcessInfo.processInfo.environment["CAMBAR_OPEN_POPOVER"] == "1" {
            DispatchQueue.main.asyncAfter(deadline: .now() + debugPopoverDelay) { [weak self] in
                self?.showPopoverFromStatusItem()
            }
        }
        if let cyclesValue = ProcessInfo.processInfo.environment["CAMBAR_DEBUG_POPOVER_CYCLES"],
           let cycles = Int(cyclesValue),
           cycles > 0 {
            popover.behavior = .applicationDefined
            debugPopoverRemaining = cycles
            debugPopoverVisibleSeconds = TimeInterval(ProcessInfo.processInfo.environment["CAMBAR_DEBUG_POPOVER_VISIBLE_SECONDS"] ?? "2") ?? 2
            DirectStreamTelemetry.record(
                component: "app",
                event: "debug_popover_behavior",
                surface: "menu",
                detail: "behavior=applicationDefined"
            )
            DispatchQueue.main.asyncAfter(deadline: .now() + debugPopoverDelay) { [weak self] in
                self?.runNextDebugPopoverCycle()
            }
        }
    }

    @objc private func togglePopover() {
        if popover.isShown {
            popover.performClose(nil)
            return
        }
        showPopoverFromStatusItem()
    }

    private func showPopoverFromStatusItem() {
        guard let button = statusItem.button else { return }
        DirectStreamTelemetry.record(
            component: "app",
            event: "menu_open_requested",
            surface: "menu",
            detail: "active=\(NSApp.isActive)"
        )
        Go2RTCVideoView.markOpen(surface: "menu")
        NSApp.activate(ignoringOtherApps: true)
        let delay: TimeInterval = NSApp.isActive ? 0 : 0.05
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self, weak button] in
            guard let self, let button else { return }
            self.showPopover(relativeTo: button)
        }
    }

    private func showPopover(relativeTo button: NSStatusBarButton) {
        guard !popover.isShown else { return }
        let size = bestPopoverVideoSize(anchorButton: button)
        popover.contentSize = ContentView.contentSize(forVideoSize: size)
        uiState.videoSize = size
        popover.show(relativeTo: button.bounds, of: button, preferredEdge: .maxY)
    }

    private func warmMenuVideo() {
        let size = uiState.videoSize
        DispatchQueue.main.async {
            self.popover.contentViewController?.view.layoutSubtreeIfNeeded()
            Go2RTCVideoView.warm(surface: "menu", size: size)
        }
    }

    private func runNextDebugPopoverCycle() {
        guard debugPopoverRemaining > 0 else { return }
        DirectStreamTelemetry.record(
            component: "app",
            event: "debug_popover_cycle",
            surface: "menu",
            detail: "remaining=\(debugPopoverRemaining)"
        )
        showPopoverFromStatusItem()
        if debugPopoverRemaining == 1 {
            return
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + debugPopoverVisibleSeconds) { [weak self] in
            guard let self else { return }
            if self.popover.isShown {
                self.popover.performClose(nil)
            }
        }
    }

    private func openWindow() {
        DirectStreamTelemetry.record(component: "app", event: "window_open_requested", surface: "window")
        if windowController == nil {
            windowController = CameraWindowController(
                onClose: { [weak self] in
                    Go2RTCVideoView.stop(surface: "window", reason: "window_closed")
                    self?.windowController = nil
                }
            )
        }
        windowController?.showWindow(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    private func bestPopoverVideoSize(anchorButton: NSStatusBarButton?) -> NSSize {
        let screen = anchorButton?.window?.screen ?? NSScreen.main
        let visible = screen?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1280, height: 720)
        let maxWidth = max(320, visible.width - 80 - ContentView.videoBorderWidth * 2)
        let maxHeight = max(180, visible.height - 120 - ContentView.videoBorderWidth * 2)
        let scale = min(1, maxWidth / nativeVideoSize.width, maxHeight / nativeVideoSize.height)
        return NSSize(
            width: floor(nativeVideoSize.width * scale),
            height: floor(nativeVideoSize.height * scale)
        )
    }

    func popoverDidShow(_ notification: Notification) {
        DirectStreamTelemetry.record(component: "app", event: "menu_did_show", surface: "menu")
        startMenuVideoWhenPopoverReady(retry: 0)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { [weak self] in
            self?.applyConcentricInnerClip()
        }
    }

    private func startMenuVideoWhenPopoverReady(retry: Int) {
        let ready = preparePopoverWindowForVideo(reason: "popover_did_show_retry_\(retry)")
        guard ready || retry >= 5 else {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { [weak self] in
                self?.startMenuVideoWhenPopoverReady(retry: retry + 1)
            }
            return
        }
        Go2RTCVideoView.start(surface: "menu")
        menuProbeToken += 1
        probeMenuVideo(reason: "popover_show", token: menuProbeToken)
    }

    private func preparePopoverWindowForVideo(reason: String) -> Bool {
        NSApp.activate(ignoringOtherApps: true)
        guard let window = popover.contentViewController?.view.window else {
            DirectStreamTelemetry.record(
                component: "app",
                event: "popover_window_missing",
                surface: "menu",
                detail: "reason=\(reason)"
            )
            return false
        }
        window.makeKeyAndOrderFront(nil)
        DirectStreamTelemetry.record(
            component: "app",
            event: "popover_window_ready",
            surface: "menu",
            detail: "reason=\(reason) visible=\(window.isVisible) key=\(window.isKeyWindow) main=\(window.isMainWindow) frame=\(Int(window.frame.width))x\(Int(window.frame.height))"
        )
        return window.isVisible && window.isKeyWindow
    }

    private func probeMenuVideo(reason: String, token: Int) {
        Go2RTCVideoView.probe(surface: "menu", reason: reason)
        for delay in [1.0, 3.0, 8.0] {
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
                guard let self, self.popover.isShown, self.menuProbeToken == token else { return }
                Go2RTCVideoView.probe(surface: "menu", reason: "\(reason)+\(String(format: "%.0fs", delay))")
            }
        }
    }

    private func applyConcentricInnerClip() {
        guard let window = popover.contentViewController?.view.window else { return }
        guard let frameView = window.contentView?.superview else { return }
        var maskLayer: CAShapeLayer?
        var layer: CALayer? = frameView.layer
        while let l = layer {
            if let m = l.mask as? CAShapeLayer {
                maskLayer = m
                break
            }
            layer = l.superlayer
        }
        guard let shape = maskLayer, let path = shape.path else { return }
        let bbox = path.boundingBoxOfPath
        let border = ContentView.videoBorderWidth
        let scaleX = (bbox.width - 2 * border) / bbox.width
        let scaleY = (bbox.height - 2 * border) / bbox.height
        // Direct affine: p' = (scale, scale) * p + offset
        // Maps path bbox -> WKWebView bbox (0..(W-2b), 0..(H-2b)).
        let tx = -scaleX * bbox.minX + bbox.midX * (1 - scaleX) - border
        let ty = -scaleY * bbox.minY + bbox.midY * (1 - scaleY) - border
        var t = CGAffineTransform(a: scaleX, b: 0, c: 0, d: scaleY, tx: tx, ty: ty)
        guard let inset = path.copy(using: &t) else { return }
        let svg = svgPathString(from: inset)
        Go2RTCVideoView.applyClipPath(surface: "menu", svgPath: svg)
    }

    private func svgPathString(from path: CGPath) -> String {
        var result = ""
        path.applyWithBlock { elementPtr in
            let element = elementPtr.pointee
            switch element.type {
            case .moveToPoint:
                let p = element.points[0]
                result += "M\(fmt(p.x)),\(fmt(p.y)) "
            case .addLineToPoint:
                let p = element.points[0]
                result += "L\(fmt(p.x)),\(fmt(p.y)) "
            case .addQuadCurveToPoint:
                let cp = element.points[0]
                let p = element.points[1]
                result += "Q\(fmt(cp.x)),\(fmt(cp.y)) \(fmt(p.x)),\(fmt(p.y)) "
            case .addCurveToPoint:
                let cp1 = element.points[0]
                let cp2 = element.points[1]
                let p = element.points[2]
                result += "C\(fmt(cp1.x)),\(fmt(cp1.y)) \(fmt(cp2.x)),\(fmt(cp2.y)) \(fmt(p.x)),\(fmt(p.y)) "
            case .closeSubpath:
                result += "Z "
            @unknown default:
                break
            }
        }
        return result
    }

    private func fmt(_ v: CGFloat) -> String {
        String(format: "%.3f", Double(v))
    }

    func popoverDidClose(_ notification: Notification) {
        DirectStreamTelemetry.record(component: "app", event: "menu_closed", surface: "menu")
        menuProbeToken += 1
        if debugPopoverRemaining > 1 {
            debugPopoverRemaining -= 1
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
                self?.runNextDebugPopoverCycle()
            }
        } else if debugPopoverRemaining == 1 {
            debugPopoverRemaining = 0
        }
    }
}
