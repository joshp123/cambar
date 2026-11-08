/// An IPv4 address with its prefix length, as an interface reports it.
public struct IPv4Network: Equatable, Sendable, CustomStringConvertible {
    public let address: UInt32
    public let prefixLength: Int

    public init(address: UInt32, prefixLength: Int) {
        self.address = address
        self.prefixLength = prefixLength
    }

    public static func parse(_ dottedQuad: String) -> UInt32? {
        let parts = dottedQuad.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count == 4 else { return nil }
        var value: UInt32 = 0
        for part in parts {
            guard let octet = UInt8(part) else { return nil }
            value = value << 8 | UInt32(octet)
        }
        return value
    }

    /// True when `host` is an IPv4 address inside this network. A /32, such as
    /// a VPN or mobile-network address, contains only itself.
    public func contains(_ host: String) -> Bool {
        guard let hostAddress = Self.parse(host), prefixLength > 0 else { return false }
        let mask: UInt32 = prefixLength >= 32 ? .max : ~(UInt32.max >> UInt32(prefixLength))
        return hostAddress & mask == address & mask
    }

    public var description: String {
        let octets = [24, 16, 8, 0].map { String((address >> UInt32($0)) & 0xFF) }
        return octets.joined(separator: ".") + "/\(prefixLength)"
    }
}

public enum TailscaleAddress {
    /// Tailscale gives each device an address in 100.64.0.0/10.
    public static func isTailscale(_ network: IPv4Network) -> Bool {
        IPv4Network(address: network.address, prefixLength: 10).contains("100.64.0.0")
    }
}
