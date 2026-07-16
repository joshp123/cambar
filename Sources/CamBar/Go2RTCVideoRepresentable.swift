import SwiftUI

struct CameraVideoView: NSViewRepresentable {
    let playback: CameraPlaybackController
    let surface: CameraPlaybackController.Surface
    let cornerRadius: CGFloat

    func makeCoordinator() -> Coordinator {
        Coordinator(playback: playback, surface: surface)
    }

    func makeNSView(context: Context) -> CameraVideoContainerView {
        let container = CameraVideoContainerView(cornerRadius: cornerRadius)
        playback.register(container, for: surface)
        return container
    }

    func updateNSView(_ nsView: CameraVideoContainerView, context: Context) {
        nsView.setCornerRadius(cornerRadius)
        playback.register(nsView, for: surface)
    }

    static func dismantleNSView(_ nsView: CameraVideoContainerView, coordinator: Coordinator) {
        coordinator.playback.unregister(nsView, for: coordinator.surface)
    }

    @MainActor
    final class Coordinator {
        let playback: CameraPlaybackController
        let surface: CameraPlaybackController.Surface

        init(playback: CameraPlaybackController, surface: CameraPlaybackController.Surface) {
            self.playback = playback
            self.surface = surface
        }
    }
}
