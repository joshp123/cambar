import SwiftUI

struct Go2RTCVideoView: NSViewRepresentable {
    let surface: String
    let autoStart: Bool

    init(surface: String, autoStart: Bool = true) {
        self.surface = surface
        self.autoStart = autoStart
    }

    @MainActor
    static func start(surface: String) {
        VideoHostRegistry.shared.start(surface: surface)
    }

    @MainActor
    static func warm(surface: String, size: CGSize) {
        VideoHostRegistry.shared.warm(surface: surface, size: size)
    }

    @MainActor
    static func markOpen(surface: String) {
        VideoHostRegistry.shared.markOpen(surface: surface)
    }

    @MainActor
    static func stop(surface: String, reason: String) {
        VideoHostRegistry.shared.stop(surface: surface, reason: reason)
    }

    @MainActor
    static func applyClipPath(surface: String, svgPath: String) {
        VideoHostRegistry.shared.applyClipPath(surface: surface, svgPath: svgPath)
    }

    @MainActor
    static func probe(surface: String, reason: String) {
        VideoHostRegistry.shared.probe(surface: surface, reason: reason)
    }

    func makeNSView(context: Context) -> VideoHostView {
        let hostView = VideoHostView(surface: surface, autoStart: autoStart)
        VideoHostRegistry.shared.register(hostView)
        return hostView
    }

    func updateNSView(_ nsView: VideoHostView, context: Context) {
        nsView.autoStart = autoStart
        VideoHostRegistry.shared.register(nsView)
        if autoStart {
            nsView.startIfVisible()
        }
    }
}
