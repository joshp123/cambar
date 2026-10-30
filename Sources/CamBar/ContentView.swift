import Observation
import SwiftUI

@MainActor
@Observable
final class CamBarUIState {
    var cameraUnavailable = false
    var fallbackStreamHeight: Int?
    var videoSize: CGSize

    init(videoSize: CGSize) {
        self.videoSize = videoSize
    }
}

/// Quiet sign that the link forced the lower-quality stream.
struct FallbackStreamBadge: View {
    let height: Int

    var body: some View {
        HStack(spacing: 4) {
            Image(systemName: "wifi.exclamationmark")
            Text("\(height)p")
        }
        .font(.system(size: 11, weight: .semibold))
        .foregroundStyle(.secondary)
        .padding(.horizontal, 9)
        .frame(height: 24)
        .background(.regularMaterial, in: Capsule())
        .help("Weak connection: showing the \(height)p stream")
        .accessibilityIdentifier("com.cambar.fallback-stream-badge")
    }
}

struct ContentView: View {
    static let contentInset: CGFloat = 6

    var state: CamBarUIState
    let playback: CameraPlaybackController
    let onOpenWindow: () -> Void
    let onRetry: () -> Void

    var body: some View {
        ZStack(alignment: .bottomTrailing) {
            Color(nsColor: .windowBackgroundColor)

            CameraVideoView(playback: playback)
                .frame(width: state.videoSize.width, height: state.videoSize.height)
                .padding(Self.contentInset)

            if state.cameraUnavailable {
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
            .accessibilityIdentifier("com.cambar.open-window")
            .help("Open window")
            .padding(Self.contentInset + 8)
        }
        .overlay(alignment: .bottomLeading) {
            if let height = state.fallbackStreamHeight {
                FallbackStreamBadge(height: height)
                    .padding(Self.contentInset + 10)
            }
        }
        .frame(width: contentSize.width, height: contentSize.height)
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
