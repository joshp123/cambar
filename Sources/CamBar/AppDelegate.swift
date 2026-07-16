import AppKit
import CamBarCore
import SwiftUI

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSPopoverDelegate {
    private let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
    private let popover = NSPopover()
    private let loginItemController = LoginItemController()
    private let relayController = Go2RTCRelayController()
    private let playbackController = CameraPlaybackController()
    private var windowController: CameraWindowController?
    private var wakeObserver: NSObjectProtocol?
    private var debugPopoverRemaining = 0
    private var debugPopoverVisibleSeconds: TimeInterval = 2
    private var didRunDebugHooks = false
    private let nativeVideoSize = CGSize(width: 2688, height: 1520)
    private lazy var uiState = CamBarUIState(videoSize: bestPopoverVideoSize(anchorButton: statusItem.button))

    func applicationDidFinishLaunching(_ notification: Notification) {
        DirectStreamTelemetry.reset()
        DirectStreamTelemetry.record(component: "app", event: "launch")
        loginItemController.ensureRegistered()
        configureStatusItem()
        configurePopover()

        relayController.onStateChange = { [weak self] state in
            self?.relayStateDidChange(state)
        }
        relayController.start()
        scheduleDebugPopoverHooks()

        wakeObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didWakeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.relayController.restart()
            }
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        if let wakeObserver {
            NSWorkspace.shared.notificationCenter.removeObserver(wakeObserver)
        }
        playbackController.shutdown()
        relayController.stop()
        DirectStreamTelemetry.flush()
    }

    func applicationDidResignActive(_ notification: Notification) {
        if popover.isShown {
            popover.performClose(nil)
        }
    }

    private func configureStatusItem() {
        guard let button = statusItem.button else { return }
        let image = NSImage(systemSymbolName: "video.fill", accessibilityDescription: "CamBar")
        image?.isTemplate = true
        button.image = image
        button.target = self
        button.action = #selector(togglePopover)
    }

    private func configurePopover() {
        popover.delegate = self
        popover.behavior = .transient
        popover.animates = false
        let initialSize = bestPopoverVideoSize(anchorButton: statusItem.button)
        uiState.videoSize = initialSize
        popover.contentSize = ContentView.contentSize(forVideoSize: initialSize)
        popover.contentViewController = NSHostingController(
            rootView: ContentView(
                state: uiState,
                playback: playbackController,
                onOpenWindow: { [weak self] in self?.openWindow() },
                onRetry: { [weak self] in self?.retry() }
            )
        )
    }

    private func relayStateDidChange(_ state: Go2RTCRelayController.State) {
        switch state {
        case .ready:
            uiState.status = .ready
        case .waitingToRetry, .stopped:
            uiState.status = .unavailable
        case .starting, .warming:
            uiState.status = .connecting
        }
        let relayAvailable = switch state {
        case .warming, .ready: true
        case .starting, .waitingToRetry, .stopped: false
        }
        playbackController.setRelayState(available: relayAvailable, ready: state == .ready)
        guard state == .ready else { return }
        runReadyDebugHooksOnce()
    }

    private func retry() {
        playbackController.retryNow()
        if relayController.state != .ready {
            relayController.restart()
        }
    }

    @objc private func togglePopover() {
        if popover.isShown {
            popover.performClose(nil)
        } else {
            showPopoverFromStatusItem()
        }
    }

    private func showPopoverFromStatusItem() {
        guard let button = statusItem.button else { return }
        if windowController?.window?.isVisible == true {
            windowController?.close()
        }
        let size = bestPopoverVideoSize(anchorButton: button)
        uiState.videoSize = size
        popover.contentSize = ContentView.contentSize(forVideoSize: size)
        DirectStreamTelemetry.record(component: "app", event: "menu_open_requested", surface: "menu")
        NSApp.activate(ignoringOtherApps: true)
        popover.show(relativeTo: button.bounds, of: button, preferredEdge: .maxY)
    }

    private func openWindow() {
        DirectStreamTelemetry.record(component: "app", event: "window_open_requested", surface: "window")
        if windowController == nil {
            windowController = CameraWindowController(
                playback: playbackController,
                nativeVideoSize: nativeVideoSize,
                onClose: { [weak self] in
                    self?.windowController = nil
                }
            )
        }
        NSApp.activate(ignoringOtherApps: true)
        windowController?.present()
        if popover.isShown {
            popover.performClose(nil)
        }
    }

    private func bestPopoverVideoSize(anchorButton: NSStatusBarButton?) -> NSSize {
        let screen = anchorButton?.window?.screen ?? NSScreen.main
        let visible = screen?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1280, height: 720)
        let maxWidth = max(320, visible.width - 80 - ContentView.contentInset * 2)
        let maxHeight = max(180, visible.height - 120 - ContentView.contentInset * 2)
        let scale = min(1, maxWidth / nativeVideoSize.width, maxHeight / nativeVideoSize.height)
        return NSSize(
            width: floor(nativeVideoSize.width * scale),
            height: floor(nativeVideoSize.height * scale)
        )
    }

    func popoverWillShow(_ notification: Notification) {
        playbackController.show(.menu)
    }

    func popoverDidShow(_ notification: Notification) {
        DirectStreamTelemetry.record(component: "app", event: "menu_did_show", surface: "menu")
    }

    func popoverDidClose(_ notification: Notification) {
        DirectStreamTelemetry.record(component: "app", event: "menu_closed", surface: "menu")
        playbackController.hide(.menu)
        if debugPopoverRemaining > 1 {
            debugPopoverRemaining -= 1
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
                self?.runNextDebugPopoverCycle()
            }
        } else if debugPopoverRemaining == 1 {
            debugPopoverRemaining = 0
        }
    }

    private func runReadyDebugHooksOnce() {
        guard !didRunDebugHooks else { return }
        didRunDebugHooks = true
        if ProcessInfo.processInfo.environment["CAMBAR_OPEN_WINDOW"] == "1" {
            DispatchQueue.main.asyncAfter(deadline: .now() + 1) { [weak self] in self?.openWindow() }
        }
    }

    private func scheduleDebugPopoverHooks() {
        let delay = TimeInterval(ProcessInfo.processInfo.environment["CAMBAR_DEBUG_POPOVER_START_DELAY_SECONDS"] ?? "1") ?? 1
        if let value = ProcessInfo.processInfo.environment["CAMBAR_DEBUG_POPOVER_CYCLES"],
           let cycles = Int(value), cycles > 0 {
            popover.behavior = .applicationDefined
            debugPopoverRemaining = cycles
            debugPopoverVisibleSeconds = TimeInterval(ProcessInfo.processInfo.environment["CAMBAR_DEBUG_POPOVER_VISIBLE_SECONDS"] ?? "2") ?? 2
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in self?.runNextDebugPopoverCycle() }
        } else if ProcessInfo.processInfo.environment["CAMBAR_OPEN_POPOVER"] == "1" {
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in self?.showPopoverFromStatusItem() }
        }
    }

    private func runNextDebugPopoverCycle() {
        guard debugPopoverRemaining > 0 else { return }
        DirectStreamTelemetry.record(component: "app", event: "debug_popover_cycle", surface: "menu")
        showPopoverFromStatusItem()
        guard debugPopoverRemaining > 1 else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + debugPopoverVisibleSeconds) { [weak self] in
            guard let self, self.popover.isShown else { return }
            self.popover.performClose(nil)
        }
    }
}
