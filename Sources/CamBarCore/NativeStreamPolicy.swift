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

public enum NativeFrameCadence {
    public static let defaultFrameDuration: TimeInterval = 1.0 / 25.0
    public static let minimumFrameDuration: TimeInterval = 1.0 / 60.0
    public static let maximumFrameDuration: TimeInterval = 1.0 / 10.0
    public static let discontinuityThreshold: TimeInterval = 0.5

    public static func updatedFrameDuration(
        current: TimeInterval,
        presentationDelta: TimeInterval
    ) -> TimeInterval {
        guard presentationDelta >= minimumFrameDuration,
              presentationDelta <= maximumFrameDuration,
              presentationDelta <= current * 1.5 else { return current }
        return current * 0.8 + presentationDelta * 0.2
    }

    public static func presentationLead(frameDuration: TimeInterval) -> TimeInterval {
        min(max(frameDuration, minimumFrameDuration), 0.05)
    }

    public static func requiresReanchor(
        presentationTime: TimeInterval,
        previousPresentationTime: TimeInterval?,
        targetDisplayTime: TimeInterval?,
        now: TimeInterval,
        consecutiveLateFrames: Int
    ) -> Bool {
        guard let previousPresentationTime,
              let targetDisplayTime else { return true }
        return presentationTime <= previousPresentationTime
            || presentationTime - previousPresentationTime > discontinuityThreshold
            || targetDisplayTime > now + discontinuityThreshold
            || (isLate(targetDisplayTime: targetDisplayTime, now: now)
                && consecutiveLateFrames >= 2)
    }

    public static func isLate(
        targetDisplayTime: TimeInterval,
        now: TimeInterval
    ) -> Bool {
        targetDisplayTime < now - minimumFrameDuration
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
