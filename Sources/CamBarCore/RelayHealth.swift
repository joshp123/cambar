import Foundation

public struct RelayStreamSample: Equatable, Sendable {
    public let hasVideo: Bool
    public let bytesReceived: Int

    public init(hasVideo: Bool, bytesReceived: Int) {
        self.hasVideo = hasVideo
        self.bytesReceived = bytesReceived
    }

    public static func decode(_ data: Data) -> RelayStreamSample? {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let producers = json["producers"] as? [[String: Any]] else {
            return nil
        }

        var hasVideo = false
        var bytesReceived = 0
        for producer in producers {
            if let medias = producer["medias"] as? [String] {
                hasVideo = hasVideo || medias.contains { $0.hasPrefix("video") }
            }
            bytesReceived = max(bytesReceived, producer["bytes_recv"] as? Int ?? 0)
        }
        return RelayStreamSample(hasVideo: hasVideo, bytesReceived: bytesReceived)
    }

    public func isAdvancing(from previous: RelayStreamSample) -> Bool {
        hasVideo && previous.hasVideo && bytesReceived > previous.bytesReceived
    }
}

public struct RelayRetryPolicy: Equatable, Sendable {
    private let delays: [TimeInterval]

    public init(delays: [TimeInterval] = [1, 2, 5, 10, 30]) {
        precondition(!delays.isEmpty)
        self.delays = delays
    }

    public func delay(afterFailure failureCount: Int) -> TimeInterval {
        delays[min(max(failureCount - 1, 0), delays.count - 1)]
    }
}
