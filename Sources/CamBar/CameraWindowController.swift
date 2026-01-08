import AppKit
import SwiftUI

@MainActor
final class CameraWindowController: NSWindowController {
    init(frameProvider: CameraFrameProvider) {
        let view = CameraWindowView(frameProvider: frameProvider)
        let hosting = NSHostingController(rootView: view)
        let window = NSWindow(contentViewController: hosting)
        window.title = "CamBar"
        window.setContentSize(NSSize(width: 1280, height: 720))
        window.styleMask = [.titled, .closable, .resizable, .miniaturizable]
        window.isReleasedWhenClosed = false
        super.init(window: window)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        nil
    }
}

struct CameraWindowView: View {
    @ObservedObject var frameProvider: CameraFrameProvider

    var body: some View {
        VStack(spacing: 0) {
            GeometryReader { proxy in
                ZStack {
                    if let player = frameProvider.player {
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
                }
                .frame(width: proxy.size.width, height: proxy.size.height)
                .background(Color.black.opacity(0.95))
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)

            HStack {
                Text("Camera: \(frameProvider.cameraName)")
                Spacer()
                if let lag = frameProvider.lagSeconds {
                    Text("Lag \(lag, specifier: "%.1f")s")
                        .foregroundColor(.secondary)
                } else {
                    Text("Lag --")
                        .foregroundColor(.secondary)
                }
                if let updated = frameProvider.lastUpdated {
                    Text("Updated \(updated.formatted(date: .omitted, time: .standard))")
                        .foregroundColor(.secondary)
                } else {
                    Text("No stream yet")
                        .foregroundColor(.secondary)
                }
            }
            .font(.caption)
            .padding(8)
        }
    }
}
