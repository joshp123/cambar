import AppKit
import SwiftUI

@MainActor
final class CameraWindowController: NSWindowController, NSWindowDelegate {
    private let onClose: () -> Void

    init(onClose: @escaping () -> Void = {}) {
        self.onClose = onClose
        let hosting = NSHostingController(rootView: CameraWindowView())
        let window = NSWindow(contentViewController: hosting)
        window.title = "CamBar"
        window.setContentSize(NSSize(width: 1280, height: 720))
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
    var body: some View {
        Go2RTCVideoView(surface: "window")
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(Color.black)
    }
}
