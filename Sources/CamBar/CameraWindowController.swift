import AppKit
import SwiftUI

@MainActor
final class CameraWindowController: NSWindowController, NSWindowDelegate {
    private let playback: CameraPlaybackController
    private let onClose: () -> Void
    private var isPresentingCamera = false

    init(
        playback: CameraPlaybackController,
        nativeVideoSize: CGSize,
        onClose: @escaping () -> Void = {}
    ) {
        self.playback = playback
        self.onClose = onClose
        let hosting = NSHostingController(rootView: CameraWindowView(playback: playback))
        let window = NSWindow(contentViewController: hosting)
        window.title = "CamBar"
        window.backgroundColor = .black
        let initialWidth: CGFloat = 1280
        let initialSize = NSSize(width: initialWidth, height: initialWidth * nativeVideoSize.height / nativeVideoSize.width)
        window.setContentSize(initialSize)
        window.contentAspectRatio = nativeVideoSize
        window.styleMask = [.titled, .closable, .resizable, .miniaturizable]
        window.isReleasedWhenClosed = false
        super.init(window: window)
        window.delegate = self
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        nil
    }

    func present() {
        showWindow(nil)
        window?.makeKeyAndOrderFront(nil)
        setCameraVisible(true)
    }

    func windowWillClose(_ notification: Notification) {
        setCameraVisible(false)
        onClose()
    }

    func windowDidMiniaturize(_ notification: Notification) {
        setCameraVisible(false)
    }

    func windowDidDeminiaturize(_ notification: Notification) {
        updateCameraVisibility()
    }

    func windowDidChangeOcclusionState(_ notification: Notification) {
        updateCameraVisibility()
    }

    private func updateCameraVisibility() {
        guard let window else { return }
        setCameraVisible(window.isVisible && !window.isMiniaturized && window.occlusionState.contains(.visible))
    }

    private func setCameraVisible(_ visible: Bool) {
        guard visible != isPresentingCamera else { return }
        isPresentingCamera = visible
        if visible {
            playback.show(.window)
        } else {
            playback.hide(.window)
        }
    }
}

struct CameraWindowView: View {
    let playback: CameraPlaybackController

    var body: some View {
        CameraVideoView(playback: playback, surface: .window, cornerStyle: .square)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(Color.black)
    }
}
