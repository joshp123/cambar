import AppKit
import CamBarCore
import SwiftUI

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSPopoverDelegate {
    private let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
    private let popover = NSPopover()
    private let loginItemController = LoginItemController()
    private let relayController = Go2RTCRelayController()
    private let playbackController = CameraPlaybackController(
        surface: .menu,
        cornerStyle: .containerConcentric
    )
    private var windowController: CameraWindowController?
    private var wakeObserver: NSObjectProtocol?
    private var outsideClickMonitor: Any?
    private var popoverPresentation = PopoverPresentationState()
    private var relayAvailable = false
    private var relayReady = false
    private let nativeVideoSize = CGSize(width: 2688, height: 1520)
    private lazy var uiState = CamBarUIState(videoSize: bestPopoverVideoSize(anchorButton: statusItem.button))

    func applicationDidFinishLaunching(_ notification: Notification) {
        DirectStreamTelemetry.reset()
        DirectStreamTelemetry.record(component: "app", event: "launch")
        loginItemController.ensureRegistered()
        configureMainMenu()
        configureStatusItem()
        configurePopover()

        relayController.onStateChange = { [weak self] state in
            self?.relayStateDidChange(state)
        }
        relayController.start()

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
        if let outsideClickMonitor {
            NSEvent.removeMonitor(outsideClickMonitor)
        }
        windowController?.shutdown()
        playbackController.shutdown()
        relayController.stop()
        DirectStreamTelemetry.flush()
    }

    private func configureStatusItem() {
        guard let button = statusItem.button else { return }
        let image = NSImage(systemSymbolName: "video.fill", accessibilityDescription: "CamBar")
        image?.isTemplate = true
        button.image = image
        button.setAccessibilityLabel("CamBar")
        button.setAccessibilityIdentifier("com.cambar.status-item")
        button.sendAction(on: [.leftMouseUp, .rightMouseUp])
        button.target = self
        button.action = #selector(handleStatusItemClick)
    }

    private func configureMainMenu() {
        let mainMenu = NSMenu()
        let appMenuItem = NSMenuItem()
        let appMenu = NSMenu()
        let quitItem = NSMenuItem(title: "Quit CamBar", action: #selector(quit), keyEquivalent: "q")
        quitItem.target = self
        appMenu.addItem(quitItem)
        appMenuItem.submenu = appMenu
        mainMenu.addItem(appMenuItem)
        NSApp.mainMenu = mainMenu
    }

    private func configurePopover() {
        popover.delegate = self
        popover.behavior = .applicationDefined
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

    private func startMonitoringOutsideClicks() {
        guard outsideClickMonitor == nil else { return }
        outsideClickMonitor = NSEvent.addGlobalMonitorForEvents(
            matching: [.leftMouseDown, .rightMouseDown, .otherMouseDown]
        ) { [weak self] event in
            let timestamp = event.timestamp
            let screenPoint = NSEvent.mouseLocation
            let windowNumber = event.windowNumber
            Task { @MainActor [weak self] in
                self?.handleGlobalMouseDown(
                    screenPoint: screenPoint,
                    windowNumber: windowNumber,
                    timestamp: timestamp
                )
            }
        }
    }

    private func handleGlobalMouseDown(
        screenPoint: NSPoint,
        windowNumber: Int,
        timestamp: TimeInterval
    ) {
        if let button = statusItem.button,
           let window = button.window {
            let rectInWindow = button.convert(button.bounds, to: nil)
            let screenRect = window.convertToScreen(rectInWindow)
            if StatusItemHitRegion.contains(
                screenPoint: screenPoint,
                eventWindowNumber: windowNumber,
                statusRect: screenRect,
                statusWindowNumber: window.windowNumber
            ) {
                DirectStreamTelemetry.record(
                    component: "app",
                    event: "status_hit_ignored_by_outside_monitor",
                    surface: "menu"
                )
                return
            }
        }
        requestPopoverClose(reason: "outside_click", at: timestamp)
    }

    private func stopMonitoringOutsideClicks() {
        guard let outsideClickMonitor else { return }
        NSEvent.removeMonitor(outsideClickMonitor)
        self.outsideClickMonitor = nil
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
        relayAvailable = switch state {
        case .warming, .ready: true
        case .starting, .waitingToRetry, .stopped: false
        }
        relayReady = state == .ready
        playbackController.setRelayState(available: relayAvailable, ready: relayReady)
        windowController?.setRelayState(available: relayAvailable, ready: relayReady)
    }

    private func retry() {
        playbackController.retryNow()
        if relayController.state != .ready {
            relayController.restart()
        }
    }

    @objc private func handleStatusItemClick() {
        guard let event = NSApp.currentEvent else { return }
        if event.type == .rightMouseUp || event.modifierFlags.contains(.control) {
            requestPopoverClose(reason: "status_context_menu", at: event.timestamp)
            showStatusMenu(for: event)
            return
        }
        let command = popoverPresentation.toggle(at: event.timestamp)
        DirectStreamTelemetry.record(
            component: "app",
            event: "status_click",
            surface: "menu",
            detail: "desired=\(popoverPresentation.wantsVisible) state=\(popoverPresentation.phase)"
        )
        apply(command)
    }

    private func showStatusMenu(for event: NSEvent) {
        guard let button = statusItem.button else { return }
        let menu = NSMenu()
        let quitItem = NSMenuItem(title: "Quit CamBar", action: #selector(quit), keyEquivalent: "q")
        quitItem.target = self
        menu.addItem(quitItem)
        NSMenu.popUpContextMenu(menu, with: event, for: button)
    }

    @objc private func quit() {
        DirectStreamTelemetry.record(component: "app", event: "quit_requested")
        NSApp.terminate(nil)
    }

    private func requestPopoverClose(reason: String, at timestamp: TimeInterval? = nil) {
        let command = popoverPresentation.requestClose(
            at: timestamp ?? NSApp.currentEvent?.timestamp ?? ProcessInfo.processInfo.systemUptime
        )
        DirectStreamTelemetry.record(
            component: "app",
            event: "menu_close_requested",
            surface: "menu",
            detail: "reason=\(reason) state=\(popoverPresentation.phase)"
        )
        apply(command)
    }

    private func apply(_ command: PopoverPresentationState.Command) {
        switch command {
        case .show:
            presentPopoverFromStatusItem()
        case .close:
            popover.close()
        case .none:
            break
        }
    }

    private func presentPopoverFromStatusItem() {
        guard let button = statusItem.button else {
            popoverPresentation.presentationFailed()
            return
        }
        if windowController != nil {
            windowController?.close()
        }
        let size = bestPopoverVideoSize(anchorButton: button)
        uiState.videoSize = size
        popover.contentSize = ContentView.contentSize(forVideoSize: size)
        DirectStreamTelemetry.record(component: "app", event: "menu_open_requested", surface: "menu")
        startMonitoringOutsideClicks()
        popover.show(relativeTo: button.bounds, of: button, preferredEdge: .maxY)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { [weak self] in
            guard let self,
                  self.popoverPresentation.phase == .opening else { return }
            if self.popover.isShown {
                DirectStreamTelemetry.record(component: "app", event: "menu_show_confirmed", surface: "menu")
                self.confirmPopoverShown()
            } else {
                DirectStreamTelemetry.record(component: "app", event: "menu_show_failed", surface: "menu")
                self.popoverPresentation.presentationFailed()
                self.stopMonitoringOutsideClicks()
            }
        }
    }

    private func openWindow() {
        DirectStreamTelemetry.record(component: "app", event: "window_open_requested", surface: "window")
        playbackController.suspend()
        if windowController == nil {
            windowController = CameraWindowController(
                nativeVideoSize: nativeVideoSize,
                relayAvailable: relayAvailable,
                relayReady: relayReady,
                onClose: { [weak self] in
                    self?.playbackController.prewarm()
                    self?.windowController = nil
                }
            )
        }
        NSApp.activate(ignoringOtherApps: true)
        windowController?.present()
        requestPopoverClose(reason: "window_opened")
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
        DirectStreamTelemetry.record(component: "app", event: "menu_will_show", surface: "menu")
    }

    func popoverDidShow(_ notification: Notification) {
        DirectStreamTelemetry.record(component: "app", event: "menu_did_show", surface: "menu")
        confirmPopoverShown()
    }

    private func confirmPopoverShown() {
        let shouldStartPlayback = popoverPresentation.phase == .opening
            && popoverPresentation.wantsVisible
        let command = popoverPresentation.didShow()
        if shouldStartPlayback,
           popoverPresentation.phase == .open,
           popoverPresentation.wantsVisible {
            playbackController.show()
        }
        apply(command)
    }

    func popoverWillClose(_ notification: Notification) {
        DirectStreamTelemetry.record(component: "app", event: "menu_will_close", surface: "menu")
    }

    func popoverDidClose(_ notification: Notification) {
        DirectStreamTelemetry.record(component: "app", event: "menu_closed", surface: "menu")
        stopMonitoringOutsideClicks()
        playbackController.hide()
        apply(popoverPresentation.didClose())
    }
}
