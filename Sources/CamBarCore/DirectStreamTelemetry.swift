import Foundation
import OSLog

public enum DirectStreamTelemetry {
    private static let queue = DispatchQueue(label: "CamBar.direct-telemetry")
    private static let enabled = ProcessInfo.processInfo.environment["CAMBAR_DIAGNOSTICS"] == "1"
    private static let logger = Logger(subsystem: "com.cambar", category: "stream")

    public static var logURL: URL {
        StreamSourceResolver.makeCacheFolderURL(namespace: "direct")
            .appendingPathComponent("direct-stream-events.jsonl")
    }

    public static func reset() {
        guard enabled else { return }
        queue.sync {
            try? FileManager.default.createDirectory(
                at: logURL.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            try? Data().write(to: logURL, options: .atomic)
        }
    }

    public static func record(
        component: String,
        event: String,
        stream: String? = nil,
        surface: String? = nil,
        elapsedMilliseconds: Int? = nil,
        detail: String? = nil
    ) {
        let safeDetail = detail.map(StreamSourceResolver.redactRtspCredentials(in:))
        var message = "component=\(component) event=\(event)"
        if let stream { message += " stream=\(stream)" }
        if let surface { message += " surface=\(surface)" }
        if let elapsedMilliseconds { message += " elapsed_ms=\(elapsedMilliseconds)" }
        if let safeDetail { message += " detail=\(safeDetail)" }
        logger.info("\(message, privacy: .public)")

        guard enabled else { return }
        queue.async {
            var fields: [String: Any] = [
                "time": ISO8601DateFormatter().string(from: Date()),
                "uptime_ms": Int(ProcessInfo.processInfo.systemUptime * 1_000),
                "component": component,
                "event": event
            ]
            if let stream {
                fields["stream"] = stream
            }
            if let surface {
                fields["surface"] = surface
            }
            if let elapsedMilliseconds {
                fields["elapsed_ms"] = elapsedMilliseconds
            }
            if let safeDetail {
                fields["detail"] = safeDetail
            }

            guard JSONSerialization.isValidJSONObject(fields),
                  let data = try? JSONSerialization.data(withJSONObject: fields, options: [.sortedKeys]),
                  let line = String(data: data, encoding: .utf8)?.appending("\n"),
                  let lineData = line.data(using: .utf8) else {
                return
            }
            if FileManager.default.fileExists(atPath: logURL.path),
               let handle = try? FileHandle(forWritingTo: logURL) {
                handle.seekToEndOfFile()
                handle.write(lineData)
                try? handle.close()
            } else {
                try? lineData.write(to: logURL, options: .atomic)
            }
        }
    }

    public static func flush() {
        guard enabled else { return }
        queue.sync {}
    }
}
