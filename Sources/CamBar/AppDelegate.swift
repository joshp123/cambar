import AppKit
import SwiftUI

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
    private let popover = NSPopover()
    private let frameProvider = CameraFrameProvider(autoStart: false)
    private let localNetworkPrompter = LocalNetworkPrompter()
    private var windowController: CameraWindowController?

    func applicationDidFinishLaunching(_ notification: Notification) {
        localNetworkPrompter.start()
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { [weak self] in
            self?.frameProvider.startStreaming()
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

        popover.behavior = .transient
        popover.contentSize = NSSize(width: 680, height: 440)
        popover.contentViewController = NSHostingController(
            rootView: ContentView(
                frameProvider: frameProvider,
                onReload: { [weak frameProvider] in
                    frameProvider?.reload()
                },
                onOpenConfig: {
                    CameraFrameProvider.openConfig()
                },
                onOpenCache: {
                    CameraFrameProvider.openCacheFolder()
                },
                onOpenWindow: { [weak self] in
                    self?.openWindow()
                },
                onQuit: {
                    NSApp.terminate(nil)
                }
            )
        )
    }

    func applicationWillTerminate(_ notification: Notification) {
        frameProvider.stop()
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
            windowController = CameraWindowController(frameProvider: frameProvider)
        }
        windowController?.showWindow(nil)
        NSApp.activate(ignoringOtherApps: true)
    }
}
