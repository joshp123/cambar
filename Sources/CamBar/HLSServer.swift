import Foundation
import Network

final class HLSServer: @unchecked Sendable {
    private let root: URL
    private let queue = DispatchQueue(label: "CamBar.hls.server")
    private var listener: NWListener?
    private(set) var baseURL: URL?
    private let onReady: ((URL) -> Void)?
    private let logURL: URL

    init(root: URL, onReady: ((URL) -> Void)? = nil) {
        self.root = root
        self.onReady = onReady
        self.logURL = root.appendingPathComponent("requests.log")
    }

    func start() {
        guard listener == nil else { return }
        do {
            let listener = try NWListener(using: .tcp, on: .any)
            listener.stateUpdateHandler = { [weak self] state in
                guard let self else { return }
                if case .ready = state, let port = listener.port {
                    if let url = URL(string: "http://127.0.0.1:\(port)") {
                        self.baseURL = url
                        self.onReady?(url)
                    }
                }
            }
            listener.newConnectionHandler = { [weak self] connection in
                self?.handle(connection)
            }
            listener.start(queue: queue)
            self.listener = listener
        } catch {
            return
        }
    }

    func stop() {
        listener?.cancel()
        listener = nil
        baseURL = nil
    }

    private func handle(_ connection: NWConnection) {
        connection.start(queue: queue)
        connection.receive(minimumIncompleteLength: 1, maximumLength: 8192) { [weak self] data, _, _, _ in
            guard let self else {
                connection.cancel()
                return
            }
            guard let data, !data.isEmpty,
                  let request = String(data: data, encoding: .utf8) else {
                connection.cancel()
                return
            }
            let method = self.requestMethod(from: request)
            let path = self.requestPath(from: request)
            let range = self.requestRange(from: request)
            self.logRequest(method: method, path: path, range: range)
            self.respond(to: connection, method: method, path: path, range: range)
        }
    }

    private func requestMethod(from request: String) -> String {
        guard let line = request.split(whereSeparator: \.isNewline).first else { return "GET" }
        let parts = line.split(separator: " ")
        guard let method = parts.first else { return "GET" }
        return String(method)
    }

    private func requestPath(from request: String) -> String {
        guard let line = request.split(whereSeparator: \.isNewline).first else { return "/" }
        let parts = line.split(separator: " ")
        guard parts.count >= 2 else { return "/" }
        return String(parts[1])
    }

    private func respond(to connection: NWConnection, method: String, path: String, range: ByteRange?) {
        let sanitized = sanitize(path)
        let fileURL = root.appendingPathComponent(sanitized)
        guard fileURL.path.hasPrefix(root.path),
              let data = try? Data(contentsOf: fileURL) else {
            send(connection, status: "404 Not Found", contentType: "text/plain", body: Data("Not found".utf8))
            return
        }
        let contentType = mimeType(for: fileURL.path)
        if let range {
            let total = data.count
            let start = max(0, range.start)
            let end = min(range.end ?? (total - 1), total - 1)
            if start >= total || end < start {
                send(connection, status: "416 Range Not Satisfiable", contentType: "text/plain", body: Data())
                return
            }
            let slice = data.subdata(in: start..<(end + 1))
        let headers = [
            "HTTP/1.1 206 Partial Content",
            "Content-Type: \(contentType)",
            "Content-Length: \(slice.count)",
            "Accept-Ranges: bytes",
            "Content-Range: bytes \(start)-\(end)/\(total)",
            "Cache-Control: no-store, no-cache, must-revalidate, max-age=0",
            "Pragma: no-cache",
            "Expires: 0",
            "Connection: close",
            "\r\n"
        ].joined(separator: "\r\n")

            var payload = Data(headers.utf8)
            if method.uppercased() != "HEAD" {
                payload.append(slice)
            }
            connection.send(content: payload, completion: .contentProcessed { _ in
                connection.cancel()
            })
            return
        }
        if method.uppercased() == "HEAD" {
            send(connection, status: "200 OK", contentType: contentType, body: Data())
            return
        }
        send(connection, status: "200 OK", contentType: contentType, body: data)
    }

    private func send(_ connection: NWConnection, status: String, contentType: String, body: Data) {
        let headers = [
            "HTTP/1.1 \(status)",
            "Content-Type: \(contentType)",
            "Content-Length: \(body.count)",
            "Cache-Control: no-store, no-cache, must-revalidate, max-age=0",
            "Pragma: no-cache",
            "Expires: 0",
            "Accept-Ranges: bytes",
            "Connection: close",
            "\r\n"
        ].joined(separator: "\r\n")

        var payload = Data(headers.utf8)
        payload.append(body)
        connection.send(content: payload, completion: .contentProcessed { _ in
            connection.cancel()
        })
    }

    private func sanitize(_ path: String) -> String {
        var trimmed = path
        if trimmed.hasPrefix("/") {
            trimmed.removeFirst()
        }
        if let queryIndex = trimmed.firstIndex(of: "?") {
            trimmed = String(trimmed[..<queryIndex])
        }
        if let fragmentIndex = trimmed.firstIndex(of: "#") {
            trimmed = String(trimmed[..<fragmentIndex])
        }
        if trimmed.isEmpty {
            trimmed = "master.m3u8"
        }
        return trimmed
    }

    private func requestRange(from request: String) -> ByteRange? {
        guard let rangeLine = request.split(whereSeparator: \.isNewline)
            .first(where: { $0.lowercased().hasPrefix("range:") }) else {
            return nil
        }
        let parts = rangeLine.split(separator: ":", maxSplits: 1)
        guard parts.count == 2 else { return nil }
        let value = parts[1].trimmingCharacters(in: .whitespaces)
        guard value.lowercased().hasPrefix("bytes=") else { return nil }
        let bytes = value.dropFirst("bytes=".count)
        let bounds = bytes.split(separator: "-", maxSplits: 1)
        guard let startString = bounds.first, let start = Int(startString) else { return nil }
        let end = bounds.count > 1 ? Int(bounds[1]) : nil
        return ByteRange(start: start, end: end)
    }

    private func logRequest(method: String, path: String, range: ByteRange?) {
        let rangeText: String
        if let range {
            if let end = range.end {
                rangeText = "bytes \(range.start)-\(end)"
            } else {
                rangeText = "bytes \(range.start)-"
            }
        } else {
            rangeText = "none"
        }
        let timestamp = ISO8601DateFormatter().string(from: Date())
        let line = "\(timestamp) \(method) \(path) range=\(rangeText)\n"
        if let data = line.data(using: .utf8) {
            if FileManager.default.fileExists(atPath: logURL.path),
               let handle = try? FileHandle(forWritingTo: logURL) {
                handle.seekToEndOfFile()
                handle.write(data)
                try? handle.close()
            } else {
                try? data.write(to: logURL, options: .atomic)
            }
        }
    }

    private struct ByteRange {
        let start: Int
        let end: Int?
    }

    private func mimeType(for path: String) -> String {
        if path.hasSuffix(".m3u8") {
            return "application/vnd.apple.mpegurl"
        }
        if path.hasSuffix(".ts") {
            return "video/MP2T"
        }
        return "application/octet-stream"
    }
}
