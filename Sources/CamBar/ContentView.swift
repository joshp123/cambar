import SwiftUI

struct ContentView: View {
    static let videoBorderWidth: CGFloat = 2

    let relayAvailable: Bool
    let videoSize: CGSize
    let onOpenWindow: () -> Void

    var body: some View {
        ZStack(alignment: .bottomTrailing) {
            Color.white

            if relayAvailable {
                Go2RTCVideoView(surface: "menu")
                    .padding(Self.videoBorderWidth)
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
        .frame(width: contentSize.width, height: contentSize.height)
    }

    static func contentSize(forVideoSize videoSize: CGSize) -> CGSize {
        CGSize(
            width: videoSize.width + videoBorderWidth * 2,
            height: videoSize.height + videoBorderWidth * 2
        )
    }

    private var contentSize: CGSize {
        Self.contentSize(forVideoSize: videoSize)
    }
}
