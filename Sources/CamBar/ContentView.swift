import SwiftUI

struct ContentView: View {
    enum VideoMode: Equatable {
        case small
        case large

        var videoSize: CGSize {
            switch self {
            case .small:
                return CGSize(width: 672, height: 380)
            case .large:
                return CGSize(width: 1344, height: 760)
            }
        }

        var popoverSize: CGSize {
            switch self {
            case .small:
                return CGSize(width: 696, height: 468)
            case .large:
                return CGSize(width: 1368, height: 848)
            }
        }

        var toggleTitle: String {
            switch self {
            case .small: return "Make Bigger"
            case .large: return "Make Smaller"
            }
        }

        var toggled: VideoMode {
            switch self {
            case .small: return .large
            case .large: return .small
            }
        }
    }

    @ObservedObject var previewProvider: CameraFrameProvider
    @ObservedObject var mainProvider: CameraFrameProvider
    let onOpenWindow: () -> Void
    let onVideoModeChanged: (VideoMode) -> Void

    @State private var videoMode: VideoMode = .small

    private var activeProvider: CameraFrameProvider {
        videoMode == .small ? previewProvider : mainProvider
    }

    var body: some View {
        VStack(spacing: 10) {
            ZStack {
                if let player = activeProvider.player {
                    LiveVideoView(player: player)
                } else if let error = activeProvider.errorMessage {
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
            }
            .frame(width: videoMode.videoSize.width, height: videoMode.videoSize.height)
            .background(Color.black.opacity(0.9))
            .cornerRadius(8)

            HStack(spacing: 10) {
                Text("Source: \(activeProvider.sourceURLMasked ?? "—")")
                    .lineLimit(1)
                    .truncationMode(.middle)
                Spacer()
                if let lag = activeProvider.lagSeconds {
                    Text("Lag \(lag, specifier: "%.1f")s")
                        .foregroundColor(.secondary)
                }
                if let updated = activeProvider.lastUpdated {
                    Text("Updated \(updated.formatted(date: .omitted, time: .standard))")
                        .foregroundColor(.secondary)
                }
            }
            .font(.caption)

            HStack {
                Button(videoMode.toggleTitle) {
                    videoMode = videoMode.toggled
                }
                Button("Pop Out") {
                    onOpenWindow()
                }
                Spacer()
            }
        }
        .padding(12)
        .onAppear {
            onVideoModeChanged(videoMode)
        }
        .onChange(of: videoMode) { _, newMode in
            onVideoModeChanged(newMode)
        }
    }
}
