/// The security boundary for the camera login: it goes only to a camera that
/// proved itself on the local network, or through Tailscale. Never anywhere
/// else, whatever the network around the Mac looks like.
public enum CameraRoutePolicy {
    public enum Decision: String, Equatable, Sendable {
        case direct
        case tailscale
        /// A camera configured by host name: macOS routes it.
        case systemRouting
        /// No proven camera and no Tailscale: do not connect.
        case unavailable
    }

    /// What the local network says about the camera's address.
    public enum LocalCheck: Equatable, Sendable {
        case notOnLocalNetwork
        case certificateNotLearned
        /// Presented the learned certificate and completed a TLS handshake
        /// with it, which needs the camera's private key.
        case proven
        case otherDevice
        case noAnswer
    }

    public static func decide(
        hostIsIPv4Address: Bool,
        localCheck: LocalCheck,
        tailscaleConnected: Bool,
        localInterfaceName: String = "the local network"
    ) -> (decision: Decision, reason: String) {
        guard hostIsIPv4Address else { return (.systemRouting, "camera is configured by host name") }
        if localCheck == .proven { return (.direct, "camera proved its certificate on \(localInterfaceName)") }
        let reason = switch localCheck {
        case .notOnLocalNetwork: "camera is not on a local network"
        case .certificateNotLearned: "camera certificate not learned yet"
        case .otherDevice: "device on \(localInterfaceName) is not the camera"
        case .noAnswer: "no camera answered on \(localInterfaceName)"
        case .proven: ""
        }
        return tailscaleConnected
            ? (.tailscale, reason)
            : (.unavailable, reason + "; Tailscale is not connected")
    }
}
