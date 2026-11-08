import CamBarCore
import CryptoKit
import Foundation
import Network
import Security

/// How CamBar reaches the camera. At home it goes straight over the local
/// network, but only after the device there proves to be the camera by its
/// HTTPS certificate. Everywhere else it goes through Tailscale. The camera
/// login is never sent to a device that has not proved itself.
struct CameraRoute: Sendable, CustomStringConvertible {
    enum Kind: String, Sendable {
        case direct
        case tailscale
        /// No Tailscale interface: let macOS route it (for example a camera
        /// configured by host name rather than a home address).
        case system
    }

    let kind: Kind
    let interface: NWInterface?
    let reason: String

    var description: String {
        "\(kind.rawValue)\(interface.map { " interface=\($0.name)" } ?? "") reason=\(reason)"
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
        func fallbackRoute(_ reason: String) -> CameraRoute {
            tailscale.map { CameraRoute(kind: .tailscale, interface: $0, reason: reason) }
                ?? CameraRoute(kind: .system, interface: nil, reason: reason + "; no Tailscale interface")
        }

        guard let local else { return fallbackRoute("camera is not on a local network") }
        guard let learned = CameraIdentity.learnedFingerprint(host: host) else {
            return fallbackRoute("camera certificate not learned yet")
        }
        switch await CameraIdentity.fingerprint(host: host, over: local) {
        case learned?:
            return CameraRoute(kind: .direct, interface: local, reason: "camera certificate matches")
        case _?:
            return fallbackRoute("device at \(host) on \(local.name) is not the camera")
        case nil:
            return fallbackRoute("no camera answered on \(local.name)")
        }
    }
}

enum CameraIdentity {
    private static func defaultsKey(host: String) -> String { "cameraCertificateSHA256.\(host)" }

    static func learnedFingerprint(host: String) -> String? {
        UserDefaults.standard.string(forKey: defaultsKey(host: host))
    }

    /// Learns the certificate through Tailscale only, the one path that is
    /// authenticated end to end, so a local impostor can never be learned.
    static func learn(host: String, over tailscale: NWInterface) async {
        guard let fingerprint = await fingerprint(host: host, over: tailscale) else { return }
        let previous = learnedFingerprint(host: host)
        guard fingerprint != previous else { return }
        UserDefaults.standard.set(fingerprint, forKey: defaultsKey(host: host))
        DirectStreamTelemetry.record(
            component: "route",
            event: previous == nil ? "camera_certificate_learned" : "camera_certificate_changed",
            detail: "sha256=\(fingerprint.prefix(16))"
        )
    }

    /// SHA-256 of the certificate the device at `host:443` presents on
    /// `interface`, or nil if nothing answers within a second. Nothing is sent
    /// beyond the TLS greeting, and the handshake is abandoned once the
    /// certificate is read.
    static func fingerprint(host: String, over interface: NWInterface) async -> String? {
        final class OneShot: @unchecked Sendable {
            private let lock = NSLock()
            private var continuation: CheckedContinuation<String?, Never>?
            init(_ continuation: CheckedContinuation<String?, Never>) { self.continuation = continuation }
            func finish(_ value: String?) {
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
            let tls = NWProtocolTLS.Options()
            sec_protocol_options_set_verify_block(tls.securityProtocolOptions, { _, trust, complete in
                let chain = SecTrustCopyCertificateChain(sec_trust_copy_ref(trust).takeRetainedValue())
                    as? [SecCertificate]
                let leaf = chain?.first.map { SecCertificateCopyData($0) as Data }
                result.finish(leaf.map { SHA256.hash(data: $0).map { String(format: "%02x", $0) }.joined() })
                complete(false)
            }, queue)
            let parameters = NWParameters(tls: tls)
            parameters.requiredInterface = interface
            let connection = NWConnection(host: NWEndpoint.Host(host), port: 443, using: parameters)
            connection.stateUpdateHandler = { state in
                switch state {
                case .failed, .cancelled: result.finish(nil)
                default: break
                }
            }
            connection.start(queue: queue)
            queue.asyncAfter(deadline: .now() + 1) {
                result.finish(nil)
                connection.cancel()
            }
        }
    }
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
