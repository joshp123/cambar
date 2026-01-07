import AVFoundation
import SwiftUI

struct LiveVideoView: NSViewRepresentable {
    let player: AVPlayer

    func makeNSView(context: Context) -> PlayerView {
        let view = PlayerView()
        view.setPlayer(player)
        return view
    }

    func updateNSView(_ nsView: PlayerView, context: Context) {
        nsView.setPlayer(player)
    }
}

final class PlayerView: NSView {
    private let playerLayer = AVPlayerLayer()

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        playerLayer.videoGravity = .resizeAspect
        layer = playerLayer
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        nil
    }

    func setPlayer(_ player: AVPlayer) {
        if playerLayer.player !== player {
            playerLayer.player = player
        }
    }
}
