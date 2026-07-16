import SwiftUI

enum CameraVideoCornerStyle: Equatable {
    case square
    case containerConcentric
}

struct CameraVideoView: NSViewRepresentable {
    let playback: CameraPlaybackController
    let surface: CameraPlaybackController.Surface
    let cornerStyle: CameraVideoCornerStyle

    func makeCoordinator() -> Coordinator {
        Coordinator(playback: playback, surface: surface)
    }

    func makeNSView(context: Context) -> CameraVideoContainerView {
        let container = CameraVideoContainerView(cornerStyle: cornerStyle)
        playback.register(container, for: surface)
        return container
    }

    func updateNSView(_ nsView: CameraVideoContainerView, context: Context) {
        nsView.setCornerStyle(cornerStyle)
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
