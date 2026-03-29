import AppKit
import SwiftUI

@MainActor
final class CameraWindowController: NSWindowController, NSWindowDelegate {
    private let onClose: () -> Void

    init(
        frameProvider: CameraFrameProvider,
        fallbackProvider: CameraFrameProvider,
        onClose: @escaping () -> Void = {}
    ) {
        self.onClose = onClose
        let view = CameraWindowView(frameProvider: frameProvider, fallbackProvider: fallbackProvider)
        let hosting = NSHostingController(rootView: view)
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
    @ObservedObject var frameProvider: CameraFrameProvider
    @ObservedObject var fallbackProvider: CameraFrameProvider

    private var displayedProvider: CameraFrameProvider {
        if frameProvider.player == nil, fallbackProvider.player != nil {
            return fallbackProvider
        }
        return frameProvider
    }

    private var loadingMessage: String? {
        guard frameProvider.player == nil, fallbackProvider.player != nil else { return nil }
        if frameProvider.errorMessage != nil {
            return "Main stream unavailable. Showing preview."
        }
        return "Loading full resolution..."
    }

    var body: some View {
        VStack(spacing: 0) {
            GeometryReader { proxy in
                ZStack {
                    if let player = displayedProvider.player {
                        LiveVideoView(player: player)
                    } else if let error = frameProvider.errorMessage {
                        VStack(spacing: 6) {
                            Text("Camera unavailable")
                                .font(.headline)
                            Text(error)
                                .font(.caption)
                                .multilineTextAlignment(.center)
                        }
                        .foregroundColor(.white)
                        .padding(16)
                    } else {
                        Text("Waiting for stream…")
                            .foregroundColor(.white)
                    }

                    if let loadingMessage {
                        Text(loadingMessage)
                            .font(.caption.weight(.semibold))
                            .foregroundColor(.white)
                            .padding(.horizontal, 12)
                            .padding(.vertical, 6)
                            .background(.black.opacity(0.65), in: Capsule())
                            .padding(16)
                            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topTrailing)
                    }
                }
                .frame(width: proxy.size.width, height: proxy.size.height)
                .background(Color.black.opacity(0.95))
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)

            StreamStatusView(
                sourceURLMasked: displayedProvider.sourceURLMasked,
                lagSeconds: displayedProvider.lagSeconds,
                lastUpdated: displayedProvider.lastUpdated,
                showPlaceholders: true
            )
            .padding(8)
        }
    }
}
