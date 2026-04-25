import SwiftUI

struct ContentView: View {
    let relayAvailable: Bool
    let videoSize: CGSize
    let onOpenWindow: () -> Void

    var body: some View {
        ZStack(alignment: .bottomTrailing) {
            if relayAvailable {
                Go2RTCVideoView(surface: "menu")
            } else {
                Text("Camera unavailable")
                    .font(.callout.weight(.semibold))
                    .foregroundColor(.white)
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
        .frame(width: videoSize.width, height: videoSize.height)
        .background(Color.black)
    }
}
