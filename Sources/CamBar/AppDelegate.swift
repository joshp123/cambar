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
    private var relayAvailable = false
    private let nativeVideoSize = CGSize(width: 2688, height: 1520)

    func applicationDidFinishLaunching(_ notification: Notification) {
        DirectStreamTelemetry.reset()
        DirectStreamTelemetry.record(component: "app", event: "launch")
        loginItemController.ensureRegistered()
        let relayStarted = relayController.startIfAvailable()
        relayAvailable = relayStarted
        wakeObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didWakeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.relayAvailable = self.relayController.startIfAvailable()
            }
        }
        if relayStarted {
            relayController.waitForMainReady { _ in
                DispatchQueue.main.async {
                    DirectStreamTelemetry.record(component: "app", event: "relay_warm_wait_finished")
                    Go2RTCVideoView.prewarmAll()
                    if ProcessInfo.processInfo.environment["CAMBAR_OPEN_WINDOW"] == "1" {
                        DispatchQueue.main.asyncAfter(deadline: .now() + 3) { [weak self] in
                            self?.openWindow()
                        }
                    }
                }
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
        popover.contentSize = ContentView.contentSize(forVideoSize: initialPopoverSize)
        popover.contentViewController = NSHostingController(
            rootView: ContentView(
                relayAvailable: relayStarted,
                videoSize: initialPopoverSize,
                onOpenWindow: { [weak self] in
                    self?.openWindow()
                }
            )
        )

    }

    func applicationWillTerminate(_ notification: Notification) {
        if let wakeObserver {
            NSWorkspace.shared.notificationCenter.removeObserver(wakeObserver)
            self.wakeObserver = nil
        }
        relayController.stop()
    }

    @objc private func togglePopover() {
        if popover.isShown {
            popover.performClose(nil)
            return
        }
        guard let button = statusItem.button else { return }
        DirectStreamTelemetry.record(component: "app", event: "menu_open_requested", surface: "menu")
        let size = bestPopoverVideoSize(anchorButton: button)
        popover.contentSize = ContentView.contentSize(forVideoSize: size)
        if let hosting = popover.contentViewController as? NSHostingController<ContentView> {
            hosting.rootView = ContentView(
                relayAvailable: relayAvailable,
                videoSize: size,
                onOpenWindow: { [weak self] in
                    self?.openWindow()
                }
            )
        }
        popover.show(relativeTo: button.bounds, of: button, preferredEdge: .maxY)
    }

    private func openWindow() {
        DirectStreamTelemetry.record(component: "app", event: "window_open_requested", surface: "window")
        if windowController == nil {
            windowController = CameraWindowController(
                onClose: { [weak self] in
                    Go2RTCVideoView.keepWarm(surface: "window")
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
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { [weak self] in
            self?.applyConcentricInnerClip()
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
    }
}
