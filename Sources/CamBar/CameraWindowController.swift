import AppKit
import SwiftUI

@MainActor
final class CameraWindowController: NSWindowController, NSWindowDelegate {
    private let onClose: () -> Void

    init(
        playback: CameraPlaybackController,
        nativeVideoSize: CGSize,
        onClose: @escaping () -> Void = {}
    ) {
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

    func windowWillClose(_ notification: Notification) {
        onClose()
    }
}

struct CameraWindowView: View {
    let playback: CameraPlaybackController

    var body: some View {
        CameraVideoView(playback: playback, surface: .window, cornerRadius: 0)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(Color.black)
    }
}
