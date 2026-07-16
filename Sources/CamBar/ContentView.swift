import SwiftUI

@MainActor
final class CamBarUIState: ObservableObject {
    @Published var relayAvailable = false
    @Published var videoSize: CGSize

    init(videoSize: CGSize) {
        self.videoSize = videoSize
    }
}

struct ContentView: View {
    static let videoBorderWidth: CGFloat = 2

    @ObservedObject var state: CamBarUIState
    let playback: CameraPlaybackController
    let onOpenWindow: () -> Void
    let onRetry: () -> Void

    var body: some View {
        ZStack(alignment: .bottomTrailing) {
            Color.white

            CameraVideoView(playback: playback, surface: .menu, cornerRadius: 0)
                .frame(width: state.videoSize.width, height: state.videoSize.height)
                .padding(Self.videoBorderWidth)

            if !state.relayAvailable {
                Button("Camera unavailable — retry", action: onRetry)
                    .buttonStyle(.borderedProminent)
            }

            Button {
                onOpenWindow()
            } label: {
                Image(systemName: "arrow.up.left.and.arrow.down.right")
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
            .help("Open window")
            .padding(10)
        }
        .frame(width: contentSize.width, height: contentSize.height)
    }

    static func contentSize(forVideoSize videoSize: CGSize) -> CGSize {
        CGSize(
            width: videoSize.width + videoBorderWidth * 2,
            height: videoSize.height + videoBorderWidth * 2
        )
    }

    private var contentSize: CGSize {
        Self.contentSize(forVideoSize: state.videoSize)
    }
}
