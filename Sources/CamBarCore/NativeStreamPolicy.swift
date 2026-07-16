import Foundation

public enum NativeFrameFreshness {
    public static let maximumCachedAge: TimeInterval = 0.1

    public static func canPresentCachedFrame(
        now: TimeInterval,
        decodedAt: TimeInterval
    ) -> Bool {
        now >= decodedAt && now - decodedAt <= maximumCachedAge
    }

    public static func isPostOpenFrame(
        sequence: UInt64,
        baselineSequence: UInt64,
        decodedAt: TimeInterval,
        openedAt: TimeInterval
    ) -> Bool {
        sequence > baselineSequence && decodedAt >= openedAt
    }
}

public enum NativeStreamRetryPolicy {
    public static func delay(afterFailure failureCount: Int) -> TimeInterval {
        let delays: [TimeInterval] = [0.1, 0.5, 2, 5]
        return delays[min(max(failureCount, 1) - 1, delays.count - 1)]
    }
}

public enum H264StreamContinuity {
    public static func isDiscontinuous(packetLoss: UInt16) -> Bool {
        packetLoss > 0
    }
}

public enum AVCCPacketizer {
    public static func packetizeH264Video(_ nalUnits: [Data]) -> Data {
        var data = Data()
        data.reserveCapacity(nalUnits.reduce(0) { $0 + ($1.isEmpty ? 0 : 4 + $1.count) })
        for nalUnit in nalUnits where !nalUnit.isEmpty {
            let type = nalUnit[nalUnit.startIndex] & 0x1F
            guard !(6...9).contains(type) else { continue }
            var length = UInt32(nalUnit.count).bigEndian
            withUnsafeBytes(of: &length) { data.append(contentsOf: $0) }
            data.append(nalUnit)
        }
        return data
    }
}
