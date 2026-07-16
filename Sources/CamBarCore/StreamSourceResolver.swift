import Foundation

public enum StreamSourceResolver {
    public struct CameraConfig {
        public var name: String?
        public var host: String?
        public var port: Int?
        public var protocolName: String?
        public var username: String?
        public var password: String?
        public var stream: String?

        public init(
            name: String? = nil,
            host: String? = nil,
            port: Int? = nil,
            protocolName: String? = nil,
            username: String? = nil,
            password: String? = nil,
            stream: String? = nil
        ) {
            self.name = name
            self.host = host
            self.port = port
            self.protocolName = protocolName
            self.username = username
            self.password = password
            self.stream = stream
        }
    }

    public static func bundledGo2RTCPath() -> String? {
        guard let path = Bundle.main.resourceURL?
            .appendingPathComponent("bin/go2rtc")
            .path,
              FileManager.default.isExecutableFile(atPath: path) else { return nil }
        return path
    }

    public static func defaultConfigURL() -> URL {
        URL(fileURLWithPath: (NSHomeDirectory() as NSString).appendingPathComponent(".config/camsnap/config.yaml"))
    }

    public static func loadRtspOverride() -> String? {
        if let env = ProcessInfo.processInfo.environment["CAMBAR_RTSP_URL"],
           !env.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return env
        }
        return nil
    }

    public static func maskRtspURL(_ raw: String) -> String {
        guard var components = URLComponents(string: raw) else {
            return raw
        }
        if components.password != nil {
            components.password = "***"
        }
        return components.string ?? raw
    }

    public static func redactRtspCredentials(in data: Data) -> Data {
        guard let text = String(data: data, encoding: .utf8) else {
            return data
        }
        return Data(redactRtspCredentials(in: text).utf8)
    }

    public static func redactRtspCredentials(in text: String) -> String {
        let pattern = #"rtsp://([^:\s/@]+):([^@\s]+)@"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else {
            return text
        }
        let range = NSRange(text.startIndex..<text.endIndex, in: text)
        return regex.stringByReplacingMatches(
            in: text,
            range: range,
            withTemplate: "rtsp://$1:***@"
        )
    }

    public static func loadCameraConfig(from url: URL) -> CameraConfig? {
        guard let data = try? Data(contentsOf: url),
              let text = String(data: data, encoding: .utf8) else {
            return nil
        }
        var current = CameraConfig()
        var insideCameras = false
        var hasCamera = false
        for rawLine in text.split(whereSeparator: \.isNewline) {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            if line.isEmpty || line.hasPrefix("#") { continue }

            if !insideCameras {
                insideCameras = line == "cameras:"
                continue
            }
            if rawLine.first?.isWhitespace != true, !line.hasPrefix("-") {
                break
            }
            if line == "-" || line.hasPrefix("- ") {
                if hasCamera {
                    break
                }
                hasCamera = true
                let itemStart = line.dropFirst().trimmingCharacters(in: .whitespaces)
                if itemStart.isEmpty { continue }
                guard applyConfigEntry(String(itemStart), to: &current) else { return nil }
            } else if hasCamera {
                guard applyConfigEntry(line, to: &current) else { return nil }
            }
        }
        return hasCamera ? current : nil
    }

    public static func buildRtspURL(from camera: CameraConfig) -> String? {
        if let stream = camera.stream, stream.contains("://") {
            guard let components = URLComponents(string: stream),
                  ["rtsp", "rtsps"].contains(components.scheme?.lowercased() ?? ""),
                  components.host != nil else { return nil }
            return stream
        }
        guard let host = camera.host?.trimmingCharacters(in: .whitespacesAndNewlines),
              !host.isEmpty, !host.contains(where: \.isWhitespace) else { return nil }
        let scheme = (camera.protocolName ?? "rtsp").lowercased()
        guard ["rtsp", "rtsps"].contains(scheme) else { return nil }
        let port = camera.port ?? 554
        guard (1...65_535).contains(port) else { return nil }
        var userInfo = ""
        if let username = camera.username {
            let user = username.addingPercentEncoding(withAllowedCharacters: .urlUserAllowed) ?? username
            if let password = camera.password {
                let pass = password.addingPercentEncoding(withAllowedCharacters: .urlPasswordAllowed) ?? password
                userInfo = "\(user):\(pass)@"
            } else {
                userInfo = "\(user)@"
            }
        }
        let streamPath = camera.stream ?? "Streaming/Channels/101"
        let path = streamPath.hasPrefix("/") ? streamPath : "/\(streamPath)"
        return "\(scheme)://\(userInfo)\(host):\(port)\(path)"
    }

    public static func makeCacheFolderURL(namespace: String) -> URL {
        let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)
            .first ?? URL(fileURLWithPath: NSTemporaryDirectory())
        return caches.appendingPathComponent("CamBar", isDirectory: true)
            .appendingPathComponent(namespace, isDirectory: true)
    }

    private static func applyConfigEntry(_ line: String, to camera: inout CameraConfig) -> Bool {
        let parts = line.split(separator: ":", maxSplits: 1, omittingEmptySubsequences: false)
        guard parts.count == 2 else { return true }
        let key = parts[0].trimmingCharacters(in: .whitespaces)
        let value = stripQuotes(parts[1].trimmingCharacters(in: .whitespaces))
        switch key {
        case "name": camera.name = value
        case "host": camera.host = value
        case "port":
            guard let port = Int(value) else { return false }
            camera.port = port
        case "protocol": camera.protocolName = value
        case "username": camera.username = value
        case "password": camera.password = value
        case "stream": camera.stream = value
        default: break
        }
        return true
    }

    private static func stripQuotes(_ value: String) -> String {
        guard value.count >= 2 else { return value }
        let first = value.first
        let last = value.last
        if (first == "\"" && last == "\"") || (first == "'" && last == "'") {
            return String(value.dropFirst().dropLast())
        }
        return value
    }
}
