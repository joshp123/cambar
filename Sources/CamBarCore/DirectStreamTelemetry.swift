import Foundation
import OSLog

public enum DirectStreamTelemetry {
    private static let queue = DispatchQueue(label: "CamBar.direct-telemetry")
    private static let logger = Logger(subsystem: "com.cambar", category: "stream")
    private static let maximumLogBytes: UInt64 = 4 * 1_024 * 1_024
    private static let sessionID = UUID().uuidString
    private static let buildID = Bundle.main.object(forInfoDictionaryKey: "GitCommit") as? String
    nonisolated(unsafe) private static var sequence = 0
    nonisolated(unsafe) private static let timestampFormatter = ISO8601DateFormatter()
    /// Set once at startup by the headless probe so it never mixes its events
    /// into the running app's log.
    nonisolated(unsafe) public static var writesToStandardErrorInsteadOfLogFile = false

    /// Lets the off-screen probe react to events it would otherwise only log.
    nonisolated(unsafe) public static var observer: (@Sendable (_ event: String, _ openID: String?, _ elapsedMilliseconds: Int?, _ detail: String?) -> Void)?

    public static let logURL = FileManager.default
        .urls(for: .cachesDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("CamBar/direct/direct-stream-events.jsonl")

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
        observer?(event, openID, elapsedMilliseconds, detail)
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
        if !writesToStandardErrorInsteadOfLogFile {
            logger.info("\(message, privacy: .public)")
        }

        queue.async {
            sequence += 1
            var fields: [String: Any] = [
                "schema_version": 2,
                "sequence": sequence,
                "time": timestampFormatter.string(from: occurredAt),
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
            if writesToStandardErrorInsteadOfLogFile {
                FileHandle.standardError.write(lineData)
                return
            }
            prepareLogFile()
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
        // Read the size from disk each time: URL resource values are cached on
        // the URL instance, so they would report the size at first read forever.
        let size = (try? FileManager.default.attributesOfItem(atPath: logURL.path)[.size] as? UInt64) ?? 0
        if size >= maximumLogBytes {
            retainNewestHalfOfLog()
        }
    }

    private static func retainNewestHalfOfLog() {
        guard let data = try? Data(contentsOf: logURL), !data.isEmpty else { return }
        let suffix = data[(data.count / 2)...]
        let newline = suffix.firstIndex(of: 0x0A)
        let retained: Data
        if let newline, newline < data.index(before: data.endIndex) {
            retained = Data(data[data.index(after: newline)...])
        } else {
            retained = Data()
        }
        try? retained.write(to: logURL, options: .atomic)
    }
}
