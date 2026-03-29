import AppKit
import SwiftUI

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSPopoverDelegate {
    private let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
    private let popover = NSPopover()
    private let previewProvider = CameraFrameProvider(autoStart: false, preferPreviewStream: true, cacheNamespace: "hls-preview")
    private let mainProvider = CameraFrameProvider(autoStart: false, preferPreviewStream: false, cacheNamespace: "hls-main")
    private let localNetworkPrompter = LocalNetworkPrompter()
    private let keepMainStreamWarm = ProcessInfo.processInfo.environment["CAMBAR_KEEP_MAIN_STREAM_WARM"] == "1"
        || UserDefaults.standard.bool(forKey: "cambar.keepMainStreamWarm")
    private var windowController: CameraWindowController?
    private var wakeObserver: NSObjectProtocol?
    private var currentVideoMode: ContentView.VideoMode = .small
    private var isPopoverShown = false
    private var isWindowOpen = false

    private var storedVideoMode: ContentView.VideoMode {
        get {
            ContentView.VideoMode.fromStoredValue(
                UserDefaults.standard.string(forKey: ContentView.VideoMode.defaultsKey)
            )
        }
        set {
            UserDefaults.standard.set(newValue.rawValue, forKey: ContentView.VideoMode.defaultsKey)
        }
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        localNetworkPrompter.start()
        wakeObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didWakeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.previewProvider.reload()
                self.refreshMainStreamIfNeeded()
            }
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { [weak self] in
            self?.previewProvider.startStreaming()
            self?.refreshMainStreamIfNeeded()
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 6) { [weak self] in
            self?.localNetworkPrompter.stop()
        }
        if ProcessInfo.processInfo.environment["CAMBAR_OPEN_WINDOW"] == "1" {
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.4) { [weak self] in
                self?.openWindow()
            }
        }

        if let button = statusItem.button {
            let image = NSImage(systemSymbolName: "video.fill", accessibilityDescription: "CamBar")
            image?.isTemplate = true
            button.image = image
            button.target = self
            button.action = #selector(togglePopover)
        }

        let initialVideoMode = storedVideoMode
        currentVideoMode = initialVideoMode
        popover.delegate = self
        popover.behavior = .transient
        popover.contentSize = NSSize(
            width: initialVideoMode.popoverSize.width,
            height: initialVideoMode.popoverSize.height
        )
        popover.contentViewController = NSHostingController(
            rootView: ContentView(
                previewProvider: previewProvider,
                mainProvider: mainProvider,
                initialVideoMode: initialVideoMode,
                onOpenWindow: { [weak self] in
                    self?.openWindow()
                },
                onVideoModeChanged: { [weak self] mode in
                    self?.handleVideoModeChange(mode)
                }
            )
        )
    }

    func applicationWillTerminate(_ notification: Notification) {
        if let wakeObserver {
            NSWorkspace.shared.notificationCenter.removeObserver(wakeObserver)
            self.wakeObserver = nil
        }
        previewProvider.stop()
        mainProvider.stop()
    }

    @objc private func togglePopover() {
        if popover.isShown {
            popover.performClose(nil)
            return
        }
        guard let button = statusItem.button else { return }
        popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
    }

    private func openWindow() {
        if windowController == nil {
            windowController = CameraWindowController(
                frameProvider: mainProvider,
                fallbackProvider: previewProvider,
                onClose: { [weak self] in
                    self?.isWindowOpen = false
                    self?.refreshMainStreamIfNeeded()
                }
            )
        }
        isWindowOpen = true
        refreshMainStreamIfNeeded()
        windowController?.showWindow(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    private func handleVideoModeChange(_ mode: ContentView.VideoMode) {
        currentVideoMode = mode
        storedVideoMode = mode
        setPopoverSize(for: mode)
        refreshMainStreamIfNeeded()
    }

    private func setPopoverSize(for mode: ContentView.VideoMode) {
        let size = mode.popoverSize
        popover.contentSize = NSSize(width: size.width, height: size.height)
    }

    func popoverWillShow(_ notification: Notification) {
        isPopoverShown = true
        refreshMainStreamIfNeeded()
    }

    func popoverDidClose(_ notification: Notification) {
        isPopoverShown = false
        refreshMainStreamIfNeeded()
    }

    private func refreshMainStreamIfNeeded() {
        let needsMainStream = keepMainStreamWarm || isWindowOpen || (isPopoverShown && currentVideoMode == .large)
        if needsMainStream {
            mainProvider.startStreaming()
        } else {
            mainProvider.stop()
        }
    }
}
