import Darwin
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

public enum NativeStreamFallbackPolicy {
    /// Showing video this stale is worse than showing less detail.
    public static let maximumSecondsBehind: TimeInterval = 3
    /// Consecutive failures that also mean the link is too weak for main.
    public static let mainFailuresBeforeFallback = 3
    public static let retryMainAfter: TimeInterval = 300
}

/// How far a session has slipped behind real time: wall time passed minus
/// video time received. It is measured from the session's best moment because
/// the starting offset is unknown, and it is cumulative because window-to-window
/// jitter cancels out while a real shortage adds up. Camera and Mac clocks
/// differ by a few parts per million, which the allowance absorbs on streams
/// that stay warm for days.
public struct RealTimeLagTracker: Sendable {
    private static let clockDriftAllowance = 0.0001

    private var wallSeconds = 0.0
    private var lag = 0.0
    private var minimumLag = 0.0

    public init() {}

    public mutating func add(wallSeconds wall: TimeInterval, mediaSeconds: TimeInterval) {
        wallSeconds += wall
        lag += wall - mediaSeconds
        minimumLag = min(minimumLag, lag)
    }

    public var secondsBehind: TimeInterval {
        max(0, lag - minimumLag - wallSeconds * Self.clockDriftAllowance)
    }
}

/// Process CPU time and memory footprint, sampled for the heartbeat.
public struct ProcessResourceUsage: Sendable {
    public let uptime: TimeInterval
    public let cpuSeconds: TimeInterval
    public let memoryMegabytes: Int

    public static func sample() -> ProcessResourceUsage {
        var usage = rusage()
        getrusage(RUSAGE_SELF, &usage)
        let cpuSeconds = TimeInterval(usage.ru_utime.tv_sec + usage.ru_stime.tv_sec)
            + TimeInterval(usage.ru_utime.tv_usec + usage.ru_stime.tv_usec) / 1_000_000
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(
            MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<natural_t>.size
        )
        let status = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count)
            }
        }
        return ProcessResourceUsage(
            uptime: ProcessInfo.processInfo.systemUptime,
            cpuSeconds: cpuSeconds,
            memoryMegabytes: status == KERN_SUCCESS ? Int(info.phys_footprint / 1_048_576) : -1
        )
    }

    /// Percent of one core used since `earlier`.
    public func cpuPercent(since earlier: ProcessResourceUsage) -> Double {
        let wall = uptime - earlier.uptime
        return wall > 0 ? (cpuSeconds - earlier.cpuSeconds) / wall * 100 : 0
    }
}

public enum VideoCodecKind: String, Sendable {
    case h264
    case h265
}

public enum AVCCPacketizer {
    /// Length-prefixes picture NAL units for VideoToolbox, dropping parameter
    /// sets, access-unit delimiters and SEI, which travel out of band.
    public static func packetize(_ nalUnits: [Data], codec: VideoCodecKind) -> Data {
        var data = Data()
        data.reserveCapacity(nalUnits.reduce(0) { $0 + ($1.isEmpty ? 0 : 4 + $1.count) })
        for nalUnit in nalUnits where !nalUnit.isEmpty {
            let header = nalUnit[nalUnit.startIndex]
            switch codec {
            case .h264:
                guard !(6...9).contains(header & 0x1F) else { continue }
            case .h265:
                guard ![32, 33, 34, 35, 39, 40].contains((header >> 1) & 0x3F) else { continue }
            }
            var length = UInt32(nalUnit.count).bigEndian
            withUnsafeBytes(of: &length) { data.append(contentsOf: $0) }
            data.append(nalUnit)
        }
        return data
    }
}
