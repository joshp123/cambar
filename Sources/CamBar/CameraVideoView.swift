import SwiftUI

enum CameraVideoCornerStyle: Equatable {
    case square
    case containerConcentric
}

struct CameraVideoView: NSViewRepresentable {
    let playback: CameraPlaybackController

    func makeNSView(context: Context) -> CameraVideoContainerView {
        playback.container
    }

    func updateNSView(_ nsView: CameraVideoContainerView, context: Context) {
        precondition(nsView === playback.container)
    }
}
