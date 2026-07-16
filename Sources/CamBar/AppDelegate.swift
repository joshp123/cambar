import AppKit
import CamBarCore
import SwiftUI

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSPopoverDelegate {
    private let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
    private let popover = NSPopover()
    private let loginItemController = LoginItemController()
    private lazy var streamController = CameraStreamController(sourceURL: resolvedRTSPURL() ?? "")
    private lazy var playbackController = CameraPlaybackController(
        stream: streamController,
        surface: .menu,
        cornerStyle: .containerConcentric
    )
    private var windowController: CameraWindowController?
    private var workspaceObservers: [NSObjectProtocol] = []
    private var outsideClickMonitor: Any?
    private var popoverPresentation = PopoverPresentationState()
    private var pendingOpenIntent: OpenIntent?
    private var activeOpenIntent: OpenIntent?
    private var nativeVideoSize = CGSize(width: 2688, height: 1520)
    private lazy var uiState = CamBarUIState(videoSize: bestPopoverVideoSize(anchorButton: statusItem.button))

    func applicationDidFinishLaunching(_ notification: Notification) {
        DirectStreamTelemetry.reset()
        DirectStreamTelemetry.record(component: "app", event: "launch")
        loginItemController.ensureRegistered()
        configureMainMenu()
        configureStatusItem()
        configurePopover()

        streamController.onStateChange = { [weak self] state in
            self?.streamStateDidChange(state)
        }
        streamController.onVideoSizeChange = { [weak self] size in
            self?.nativeVideoSize = size
        }
        streamController.start()

        workspaceObservers.append(NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.willSleepNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.streamController.suspendForSleep()
            }
        })
        workspaceObservers.append(NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didWakeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.streamController.resumeAfterWake()
            }
        })
    }

    func applicationWillTerminate(_ notification: Notification) {
        for observer in workspaceObservers {
            NSWorkspace.shared.notificationCenter.removeObserver(observer)
        }
        if let outsideClickMonitor {
            NSEvent.removeMonitor(outsideClickMonitor)
        }
        windowController?.shutdown()
        playbackController.shutdown()
        streamController.shutdown()
        DirectStreamTelemetry.flush()
    }

    func applicationDidBecomeActive(_ notification: Notification) {
        DirectStreamTelemetry.record(component: "app", event: "app_activated")
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

    private func streamStateDidChange(_ state: CameraStreamController.State) {
        switch state {
        case .ready:
            uiState.status = .ready
        case .waitingToRetry, .stopped, .suspended:
            uiState.status = .unavailable
        case .connecting:
            uiState.status = .connecting
        }
    }

    private func retry() {
        playbackController.retryNow()
    }

    @objc private func handleStatusItemClick() {
        let event = NSApp.currentEvent
        if let event,
           event.type == .rightMouseUp || event.modifierFlags.contains(.control) {
            requestPopoverClose(reason: "status_context_menu", at: event.timestamp)
            showStatusMenu(for: event)
            return
        }
        let clickAt = event?.timestamp ?? ProcessInfo.processInfo.systemUptime
        let wantedVisibleBeforeClick = popoverPresentation.wantsVisible
        let command = popoverPresentation.toggle(at: clickAt)
        if !wantedVisibleBeforeClick, popoverPresentation.wantsVisible {
            pendingOpenIntent = OpenIntent(id: UUID().uuidString, startedAt: clickAt)
        }
        let openIntent = pendingOpenIntent ?? activeOpenIntent
        DirectStreamTelemetry.record(
            component: "app",
            event: "status_click",
            surface: "menu",
            openID: openIntent?.id,
            detail: "command=\(command) desired=\(popoverPresentation.wantsVisible) state=\(popoverPresentation.phase)"
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
            openID: activeOpenIntent?.id ?? pendingOpenIntent?.id,
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
        if pendingOpenIntent == nil {
            pendingOpenIntent = OpenIntent(
                id: UUID().uuidString,
                startedAt: ProcessInfo.processInfo.systemUptime
            )
        }
        let openIntent = pendingOpenIntent
        DirectStreamTelemetry.record(
            component: "app",
            event: "menu_open_requested",
            surface: "menu",
            openID: openIntent?.id,
            detail: "presentation_id=\(popoverPresentation.presentationID)"
        )
        let presentationID = popoverPresentation.presentationID
        startMonitoringOutsideClicks()
        popover.show(relativeTo: button.bounds, of: button, preferredEdge: .maxY)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { [weak self] in
            guard let self,
                  self.popoverPresentation.presentationID == presentationID,
                  self.popoverPresentation.phase == .opening else { return }
            if self.popover.isShown {
                DirectStreamTelemetry.record(
                    component: "app",
                    event: "menu_show_confirmed",
                    surface: "menu",
                    openID: self.pendingOpenIntent?.id ?? self.activeOpenIntent?.id
                )
                self.confirmPopoverShown()
            } else {
                DirectStreamTelemetry.record(
                    component: "app",
                    event: "menu_show_failed",
                    surface: "menu",
                    openID: self.pendingOpenIntent?.id
                )
                self.popoverPresentation.presentationFailed()
                self.pendingOpenIntent = nil
                self.stopMonitoringOutsideClicks()
            }
        }
    }

    private func openWindow() {
        DirectStreamTelemetry.record(component: "app", event: "window_open_requested", surface: "window")
        playbackController.suspend()
        if windowController == nil {
            windowController = CameraWindowController(
                stream: streamController,
                nativeVideoSize: nativeVideoSize,
                onClose: { [weak self] in
                    self?.playbackController.resumeAfterPopout()
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
        DirectStreamTelemetry.record(
            component: "app",
            event: "menu_will_show",
            surface: "menu",
            openID: pendingOpenIntent?.id
        )
    }

    func popoverDidShow(_ notification: Notification) {
        DirectStreamTelemetry.record(
            component: "app",
            event: "menu_did_show",
            surface: "menu",
            openID: pendingOpenIntent?.id
        )
        confirmPopoverShown()
    }

    private func confirmPopoverShown() {
        let shouldStartPlayback = popoverPresentation.phase == .opening
            && popoverPresentation.wantsVisible
        let command = popoverPresentation.didShow()
        if shouldStartPlayback,
           popoverPresentation.phase == .open,
           popoverPresentation.wantsVisible,
           let intent = pendingOpenIntent {
            activeOpenIntent = intent
            pendingOpenIntent = nil
            playbackController.show(openID: intent.id, startedAt: intent.startedAt)
        }
        apply(command)
    }

    func popoverWillClose(_ notification: Notification) {
        DirectStreamTelemetry.record(
            component: "app",
            event: "menu_will_close",
            surface: "menu",
            openID: activeOpenIntent?.id ?? pendingOpenIntent?.id
        )
    }

    func popoverDidClose(_ notification: Notification) {
        DirectStreamTelemetry.record(
            component: "app",
            event: "menu_closed",
            surface: "menu",
            openID: activeOpenIntent?.id ?? pendingOpenIntent?.id
        )
        stopMonitoringOutsideClicks()
        playbackController.hide()
        activeOpenIntent = nil
        let command = popoverPresentation.didClose()
        if !popoverPresentation.wantsVisible {
            pendingOpenIntent = nil
        }
        apply(command)
    }

    private struct OpenIntent {
        let id: String
        let startedAt: TimeInterval
    }

    private func resolvedRTSPURL() -> String? {
        if let override = StreamSourceResolver.loadRtspOverride() {
            return override
        }
        guard let config = StreamSourceResolver.loadCameraConfig(
            from: StreamSourceResolver.defaultConfigURL()
        ) else { return nil }
        return StreamSourceResolver.buildRtspURL(from: config)
    }
}
