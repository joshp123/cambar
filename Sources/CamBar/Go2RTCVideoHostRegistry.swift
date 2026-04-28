import CoreGraphics

@MainActor
final class VideoHostRegistry {
    static let shared = VideoHostRegistry()

    private var hosts: [String: WeakVideoHost] = [:]

    func register(_ host: VideoHostView) {
        hosts[host.surface] = WeakVideoHost(host)
    }

    func start(surface: String) {
        hosts[surface]?.host?.startIfVisible()
    }

    func warm(surface: String, size: CGSize) {
        hosts[surface]?.host?.warm(size: size)
    }

    func markOpen(surface: String) {
        hosts[surface]?.host?.markOpen()
    }

    func stop(surface: String, reason: String) {
        hosts[surface]?.host?.stopVisibleSession(reason: reason)
    }

    func probe(surface: String, reason: String) {
        hosts[surface]?.host?.recordDOMState(reason: reason)
    }

    func applyClipPath(surface: String, svgPath: String) {
        hosts[surface]?.host?.applyClipPath(svgPath)
    }
}

private final class WeakVideoHost {
    weak var host: VideoHostView?

    init(_ host: VideoHostView) {
        self.host = host
    }
}
