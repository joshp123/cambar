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
            guard let medias = producer["medias"] as? [String],
                  medias.contains(where: { $0.hasPrefix("video") }) else { continue }
            hasVideo = true
            bytesReceived = max(bytesReceived, producer["bytes_recv"] as? Int ?? 0)
        }
        return RelayStreamSample(hasVideo: hasVideo, bytesReceived: bytesReceived)
    }

    public func isAdvancing(from previous: RelayStreamSample) -> Bool {
        hasVideo && previous.hasVideo && bytesReceived > previous.bytesReceived
    }
}

public struct RelayRuntimeLiveness: Sendable {
    private let stalledSampleLimit: Int
    private let missingSampleLimit: Int
    private var previousSample: RelayStreamSample?
    private var stalledSamples = 0
    private var missingSamples = 0

    public init(stalledSampleLimit: Int = 15, missingSampleLimit: Int = 30) {
        precondition(stalledSampleLimit > 0)
        precondition(missingSampleLimit > 0)
        self.stalledSampleLimit = stalledSampleLimit
        self.missingSampleLimit = missingSampleLimit
    }

    public mutating func observesFailure(_ sample: RelayStreamSample?) -> Bool {
        guard let sample else {
            missingSamples += 1
            return missingSamples >= missingSampleLimit
        }
        missingSamples = 0
        guard let priorSample = previousSample else {
            self.previousSample = sample
            return false
        }
        defer { previousSample = sample }

        if sample.isAdvancing(from: priorSample) {
            stalledSamples = 0
            return false
        }
        stalledSamples += 1
        return stalledSamples >= stalledSampleLimit
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
