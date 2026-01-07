import SwiftUI

struct ContentView: View {
    @ObservedObject var frameProvider: CameraFrameProvider
    let onReload: () -> Void
    let onOpenCache: () -> Void
    let onOpenWindow: () -> Void
    let onQuit: () -> Void
    @State private var showSettings = false

    var body: some View {
        VStack(spacing: 10) {
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
            .frame(width: 640, height: 360)
            .background(Color.black.opacity(0.9))
            .cornerRadius(8)

            HStack {
                Text("Camera: \(frameProvider.cameraName)")
                Spacer()
                if let updated = frameProvider.lastUpdated {
                    Text("Updated \(updated.formatted(date: .omitted, time: .standard))")
                        .foregroundColor(.secondary)
                } else {
                    Text("No stream yet")
                        .foregroundColor(.secondary)
                }
            }
            .font(.caption)

            HStack {
                Button("Reload") { onReload() }
                Button("Open Window") { onOpenWindow() }
                Button("Settings") { showSettings = true }
                Button("Open Cache") { onOpenCache() }
                Spacer()
                Button("Quit") { onQuit() }
            }
        }
        .padding(12)
        .sheet(isPresented: $showSettings) {
            SettingsView(onApply: onReload)
        }
    }
}
