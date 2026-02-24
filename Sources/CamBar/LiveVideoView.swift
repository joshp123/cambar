import AVFoundation
import AppKit
import SwiftUI

final class PlayerLayerView: NSView {
    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer = AVPlayerLayer()
        configureLayer()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        nil
    }

    var player: AVPlayer? {
        get { (layer as? AVPlayerLayer)?.player }
        set {
            (layer as? AVPlayerLayer)?.player = newValue
            configureLayer()
            updateScale()
        }
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        updateScale()
    }

    override func layout() {
        super.layout()
        updateScale()
    }

    private func configureLayer() {
        guard let playerLayer = layer as? AVPlayerLayer else { return }
        playerLayer.videoGravity = .resizeAspect
        playerLayer.magnificationFilter = .linear
        playerLayer.minificationFilter = .trilinear
        playerLayer.allowsEdgeAntialiasing = true
        playerLayer.needsDisplayOnBoundsChange = true
    }

    private func updateScale() {
        let scale = window?.backingScaleFactor ?? NSScreen.main?.backingScaleFactor ?? 2
        layer?.contentsScale = scale
        (layer as? AVPlayerLayer)?.contentsScale = scale
    }
}

struct LiveVideoView: NSViewRepresentable {
    let player: AVPlayer

    func makeNSView(context: Context) -> PlayerLayerView {
        let view = PlayerLayerView(frame: .zero)
        view.player = player
        return view
    }

    func updateNSView(_ nsView: PlayerLayerView, context: Context) {
        if nsView.player !== player {
            nsView.player = player
        }
    }
}
