import Foundation
import OSLog

public enum DirectStreamTelemetry {
    private static let queue = DispatchQueue(label: "CamBar.direct-telemetry")
    private static let logger = Logger(subsystem: "com.cambar", category: "stream")
    private static let maximumLogBytes: UInt64 = 4 * 1_024 * 1_024
    private static let sessionID = UUID().uuidString
    private static let buildID = Bundle.main.object(forInfoDictionaryKey: "GitCommit") as? String
    nonisolated(unsafe) private static var sequence = 0

    public static var logURL: URL {
        StreamSourceResolver.makeCacheFolderURL(namespace: "direct")
            .appendingPathComponent("direct-stream-events.jsonl")
    }

    public static func reset() {
        queue.sync {
            prepareLogFile()
        }
    }

    public static func record(
        component: String,
        event: String,
        stream: String? = nil,
        surface: String? = nil,
        openID: String? = nil,
        videoSessionID: String? = nil,
        elapsedMilliseconds: Int? = nil,
        detail: String? = nil
    ) {
        let occurredAt = Date()
        let occurredUptimeMilliseconds = Int(ProcessInfo.processInfo.systemUptime * 1_000)
        let safeDetail = detail.map(StreamSourceResolver.redactRtspCredentials(in:))
        var message = "component=\(component) event=\(event)"
        if let stream { message += " stream=\(stream)" }
        if let surface { message += " surface=\(surface)" }
        if let openID { message += " open_id=\(openID)" }
        if let videoSessionID { message += " video_session_id=\(videoSessionID)" }
        if let elapsedMilliseconds { message += " elapsed_ms=\(elapsedMilliseconds)" }
        if let safeDetail { message += " detail=\(safeDetail)" }
        logger.info("\(message, privacy: .public)")

        queue.async {
            prepareLogFile()
            sequence += 1
            var fields: [String: Any] = [
                "schema_version": 2,
                "sequence": sequence,
                "time": ISO8601DateFormatter().string(from: occurredAt),
                "uptime_ms": occurredUptimeMilliseconds,
                "session_id": sessionID,
                "component": component,
                "event": event
            ]
            if let buildID {
                fields["build_id"] = buildID
            }
            if let stream {
                fields["stream"] = stream
            }
            if let surface {
                fields["surface"] = surface
            }
            if let openID {
                fields["open_id"] = openID
            }
            if let videoSessionID {
                fields["video_session_id"] = videoSessionID
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
        queue.sync {}
    }

    private static func prepareLogFile() {
        try? FileManager.default.createDirectory(
            at: logURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        let size = (try? logURL.resourceValues(forKeys: [.fileSizeKey]).fileSize).map(UInt64.init) ?? 0
        if size >= maximumLogBytes {
            try? Data().write(to: logURL, options: .atomic)
        }
    }
}
