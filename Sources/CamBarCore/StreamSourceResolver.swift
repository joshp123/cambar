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

    public static func resolveExecutablePath(_ name: String, overridePath: String?) -> String? {
        if let overridePath {
            let expanded = (overridePath as NSString).expandingTildeInPath
            if FileManager.default.isExecutableFile(atPath: expanded) {
                return expanded
            }
        }
        let envVar = name.uppercased() + "_PATH"
        if let envPath = ProcessInfo.processInfo.environment[envVar],
           FileManager.default.isExecutableFile(atPath: envPath) {
            return envPath
        }
        for dir in searchPaths() {
            let path = (dir as NSString).appendingPathComponent(name)
            if FileManager.default.isExecutableFile(atPath: path) {
                return path
            }
        }
        return nil
    }

    public static func defaultConfigURL() -> URL {
        URL(fileURLWithPath: (NSHomeDirectory() as NSString).appendingPathComponent(".config/camsnap/config.yaml"))
    }

    public static func searchPaths() -> [String] {
        var extraPaths = [
            "/opt/homebrew/bin",
            "/usr/local/bin",
            "/run/current-system/sw/bin",
            "/nix/var/nix/profiles/default/bin",
            (NSHomeDirectory() as NSString).appendingPathComponent(".nix-profile/bin"),
            (NSHomeDirectory() as NSString).appendingPathComponent(".local/bin"),
            "/usr/bin",
            "/bin"
        ]
        if let resourceURL = Bundle.main.resourceURL {
            let bundled = resourceURL.appendingPathComponent("bin").path
            extraPaths.insert(bundled, at: 0)
        }
        let inherited = (ProcessInfo.processInfo.environment["PATH"] ?? "")
            .split(separator: ":", omittingEmptySubsequences: true)
            .map(String.init)
        var seen = Set<String>()
        var result: [String] = []
        for path in extraPaths + inherited {
            guard !seen.contains(path) else { continue }
            seen.insert(path)
            result.append(path)
        }
        return result
    }

    public static func loadRtspOverride() -> String? {
        if let env = ProcessInfo.processInfo.environment["CAMBAR_RTSP_URL"],
           !env.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return env
        }
        return userDefaultString("rtspURL")
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
        var hasCamera = false
        for rawLine in text.split(whereSeparator: \.isNewline) {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            if line.isEmpty || line.hasPrefix("#") { continue }
            if line.hasPrefix("- name:") {
                if hasCamera {
                    break
                }
                hasCamera = true
                current.name = line.replacingOccurrences(of: "- name:", with: "")
                    .trimmingCharacters(in: .whitespaces)
                continue
            }
            let parts = line.split(separator: ":", maxSplits: 1, omittingEmptySubsequences: false)
            guard parts.count == 2 else { continue }
            let key = parts[0].trimmingCharacters(in: .whitespaces)
            let rawValue = parts[1].trimmingCharacters(in: .whitespaces)
            let value = stripQuotes(rawValue)
            switch key {
            case "host": current.host = value
            case "port": current.port = Int(value)
            case "protocol": current.protocolName = value
            case "username": current.username = value
            case "password": current.password = value
            case "stream": current.stream = value
            default: break
            }
        }
        return hasCamera ? current : nil
    }

    public static func buildRtspURL(from camera: CameraConfig) -> String? {
        if let stream = camera.stream, stream.contains("://") {
            return stream
        }
        guard let host = camera.host else { return nil }
        let scheme = camera.protocolName ?? "rtsp"
        let port = camera.port ?? 554
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
        let folder = caches.appendingPathComponent("CamBar", isDirectory: true)
            .appendingPathComponent(namespace, isDirectory: true)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        return folder
    }

    private static func userDefaultString(_ key: String) -> String? {
        guard let value = UserDefaults.standard.string(forKey: key)?
            .trimmingCharacters(in: .whitespacesAndNewlines),
              !value.isEmpty else {
            return nil
        }
        return value
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
