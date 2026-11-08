import CamBarCore
import CryptoKit
import Foundation
import Network
import Security

/// How CamBar reaches the camera. At home it goes straight over the local
/// network, but only after the device there proves to be the camera: it must
/// present the camera's HTTPS certificate and complete a TLS handshake with
/// it, which needs the camera's private key. Everywhere else it goes through
/// Tailscale. The camera login is never sent anywhere else.
struct CameraRoute: Sendable, CustomStringConvertible {
    let decision: CameraRoutePolicy.Decision
    let localCheck: CameraRoutePolicy.LocalCheck
    let interface: NWInterface?
    let reason: String

    var description: String {
        "\(decision.rawValue)\(interface.map { " interface=\($0.name)" } ?? "") reason=\(reason)"
    }

    static func choose(host: String, interfaces: [NWInterface]) async -> CameraRoute {
        let tailscale = interfaces.first { interface in
            interface.name.hasPrefix("utun")
                && InterfaceAddresses.ipv4(of: interface.name).contains(where: TailscaleAddress.isTailscale)
        }
        let local = interfaces.first { interface in
            !interface.name.hasPrefix("utun")
                && InterfaceAddresses.ipv4(of: interface.name).contains { $0.contains(host) }
        }
        let localCheck: CameraRoutePolicy.LocalCheck
        if local == nil {
            localCheck = .notOnLocalNetwork
        } else if let learned = CameraIdentity.learnedFingerprint(host: host), let local {
            localCheck = await CameraIdentity.check(host: host, over: local, expected: learned)
        } else {
            localCheck = .certificateNotLearned
        }
        let (decision, reason) = CameraRoutePolicy.decide(
            hostIsIPv4Address: IPv4Network.parse(host) != nil,
            localCheck: localCheck,
            tailscaleConnected: tailscale != nil,
            localInterfaceName: local?.name ?? "the local network"
        )
        let interface: NWInterface? = switch decision {
        case .direct: local
        case .tailscale: tailscale
        case .systemRouting, .unavailable: nil
        }
        return CameraRoute(decision: decision, localCheck: localCheck, interface: interface, reason: reason)
    }
}

enum CameraIdentity {
    private static func defaultsKey(host: String) -> String { "cameraCertificateSHA256.\(host)" }

    static func learnedFingerprint(host: String) -> String? {
        UserDefaults.standard.string(forKey: defaultsKey(host: host))
    }

    /// Learns the certificate through Tailscale only, the one path that is
    /// authenticated end to end, so a local impostor can never be learned.
    /// Returns true when the stored certificate is new or changed.
    static func learn(host: String, over tailscale: NWInterface) async -> Bool? {
        guard case let .proven(fingerprint) = await handshake(host: host, over: tailscale, expected: nil) else {
            return nil
        }
        let previous = learnedFingerprint(host: host)
        guard fingerprint != previous else { return false }
        UserDefaults.standard.set(fingerprint, forKey: defaultsKey(host: host))
        DirectStreamTelemetry.record(
            component: "route",
            event: previous == nil ? "camera_certificate_learned" : "camera_certificate_changed",
            detail: "sha256=\(fingerprint.prefix(16))"
        )
        return true
    }

    static func check(host: String, over interface: NWInterface, expected: String) async -> CameraRoutePolicy.LocalCheck {
        switch await handshake(host: host, over: interface, expected: expected) {
        case .proven: .proven
        case .presentedOtherCertificate: .otherDevice
        case .noHandshake: .noAnswer
        }
    }

    enum HandshakeResult: Equatable {
        /// SHA-256 of the certificate, proven by a completed TLS handshake,
        /// which needs the certificate's private key.
        case proven(String)
        case presentedOtherCertificate
        case noHandshake
    }

    /// TLS handshake with `host:443` on `interface`. With `expected` set, any
    /// other certificate aborts it. Two-second limit; no application data is
    /// sent.
    static func handshake(host: String, over interface: NWInterface, expected: String?) async -> HandshakeResult {
        final class OneShot: @unchecked Sendable {
            private let lock = NSLock()
            private var continuation: CheckedContinuation<HandshakeResult, Never>?
            init(_ continuation: CheckedContinuation<HandshakeResult, Never>) { self.continuation = continuation }
            func finish(_ value: HandshakeResult) {
                lock.lock()
                let pending = continuation
                continuation = nil
                lock.unlock()
                pending?.resume(returning: value)
            }
        }

        let queue = DispatchQueue(label: "CamBar.camera-identity")
        return await withCheckedContinuation { continuation in
            let result = OneShot(continuation)
            let presented = PresentedFingerprint()
            let tls = NWProtocolTLS.Options()
            sec_protocol_options_set_verify_block(tls.securityProtocolOptions, { _, trust, complete in
                let chain = SecTrustCopyCertificateChain(sec_trust_copy_ref(trust).takeRetainedValue())
                    as? [SecCertificate]
                let fingerprint = chain?.first.map {
                    SHA256.hash(data: SecCertificateCopyData($0) as Data).map { String(format: "%02x", $0) }.joined()
                }
                presented.value = fingerprint
                // The camera's certificate is self-signed, so trust is decided
                // by the pin, and the handshake that follows proves possession.
                complete(fingerprint != nil && (expected == nil || fingerprint == expected))
            }, queue)
            let parameters = NWParameters(tls: tls)
            parameters.requiredInterface = interface
            let connection = NWConnection(host: NWEndpoint.Host(host), port: 443, using: parameters)
            connection.stateUpdateHandler = { state in
                switch state {
                case .ready:
                    result.finish(presented.value.map(HandshakeResult.proven) ?? .noHandshake)
                    connection.cancel()
                case .failed, .cancelled, .waiting:
                    let rejected = presented.value != nil && expected != nil && presented.value != expected
                    result.finish(rejected ? .presentedOtherCertificate : .noHandshake)
                    connection.cancel()
                default:
                    break
                }
            }
            connection.start(queue: queue)
            queue.asyncAfter(deadline: .now() + 2) {
                result.finish(.noHandshake)
                connection.cancel()
            }
        }
    }
}

/// Written and read only on the identity check's serial queue.
private final class PresentedFingerprint: @unchecked Sendable {
    var value: String?
}

enum InterfaceAddresses {
    static func ipv4(of interfaceName: String) -> [IPv4Network] {
        var networks: [IPv4Network] = []
        var head: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&head) == 0 else { return [] }
        defer { freeifaddrs(head) }
        var cursor = head
        while let entry = cursor?.pointee {
            defer { cursor = entry.ifa_next }
            guard String(cString: entry.ifa_name) == interfaceName,
                  let address = entry.ifa_addr, address.pointee.sa_family == UInt8(AF_INET),
                  let netmask = entry.ifa_netmask else { continue }
            let ip = address.withMemoryRebound(to: sockaddr_in.self, capacity: 1) { $0.pointee.sin_addr.s_addr }
            let mask = netmask.withMemoryRebound(to: sockaddr_in.self, capacity: 1) { $0.pointee.sin_addr.s_addr }
            networks.append(IPv4Network(address: UInt32(bigEndian: ip), prefixLength: mask.nonzeroBitCount))
        }
        return networks
    }
}
