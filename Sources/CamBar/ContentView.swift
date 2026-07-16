import Observation
import SwiftUI

@MainActor
@Observable
final class CamBarUIState {
    enum Status: Equatable {
        case connecting
        case ready
        case unavailable
    }

    var status: Status = .connecting
    var videoSize: CGSize

    init(videoSize: CGSize) {
        self.videoSize = videoSize
    }
}

struct ContentView: View {
    static let popoverCornerRadius: CGFloat = 10
    static let contentInset: CGFloat = 6
    static let videoCornerRadius = popoverCornerRadius - contentInset

    var state: CamBarUIState
    let playback: CameraPlaybackController
    let onOpenWindow: () -> Void
    let onRetry: () -> Void

    var body: some View {
        ZStack(alignment: .bottomTrailing) {
            Color(nsColor: .windowBackgroundColor)

            CameraVideoView(
                playback: playback,
                surface: .menu,
                cornerRadius: Self.videoCornerRadius
            )
                .frame(width: state.videoSize.width, height: state.videoSize.height)
                .padding(Self.contentInset)

            if state.status == .connecting {
                ProgressView()
                    .controlSize(.small)
                    .padding(10)
                    .background(.regularMaterial, in: Capsule())
            } else if state.status == .unavailable {
                Button("Camera unavailable — retry", action: onRetry)
                    .buttonStyle(.borderedProminent)
            }

            Button {
                onOpenWindow()
            } label: {
                Image(systemName: "arrow.up.left.and.arrow.down.right")
                    .font(.system(size: 12, weight: .semibold))
                    .frame(width: 28, height: 28)
                    .background(.regularMaterial, in: Circle())
                    .overlay {
                        Circle().stroke(.white.opacity(0.35), lineWidth: 0.5)
                    }
                    .contentShape(Circle())
            }
            .buttonStyle(.plain)
            .focusable(false)
            .help("Open window")
            .padding(Self.contentInset + 8)
        }
        .frame(width: contentSize.width, height: contentSize.height)
        .clipShape(RoundedRectangle(cornerRadius: Self.popoverCornerRadius, style: .continuous))
    }

    static func contentSize(forVideoSize videoSize: CGSize) -> CGSize {
        CGSize(
            width: videoSize.width + contentInset * 2,
            height: videoSize.height + contentInset * 2
        )
    }

    private var contentSize: CGSize {
        Self.contentSize(forVideoSize: state.videoSize)
    }
}
