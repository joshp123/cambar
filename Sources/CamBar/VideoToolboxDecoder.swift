import CoreMedia
import CoreVideo
import CamBarCore
import Foundation
import IPCamKit
import VideoToolbox

struct DecodedCameraFrame: @unchecked Sendable {
    let generation: String
    let pixelBuffer: CVPixelBuffer
    let presentationTime: CMTime
    let decodedAt: TimeInterval
}

/// The out-of-band parameter sets a decoder session is built from.
enum VideoParameterSets: Equatable, Sendable {
    case h264(sps: Data, pps: Data)
    case h265(vps: Data, sps: Data, pps: Data)

    var vps: Data? {
        if case let .h265(vps, _, _) = self { return vps }
        return nil
    }

    var codec: VideoCodecKind {
        switch self {
        case .h264: .h264
        case .h265: .h265
        }
    }
}

final class VideoToolboxDecoder: @unchecked Sendable {
    enum DecoderError: Error, CustomStringConvertible {
        case invalidParameterSets
        case formatDescription(OSStatus)
        case sessionCreation(OSStatus)
        case sessionConfiguration(OSStatus)
        case hardwareDecoderUnavailable
        case blockBuffer(OSStatus)
        case sampleBuffer(OSStatus)
        case decode(OSStatus)

        var description: String {
            switch self {
            case .invalidParameterSets: "invalid H.264 parameter sets"
            case let .formatDescription(status): "format description failed (\(status))"
            case let .sessionCreation(status): "decoder session creation failed (\(status))"
            case let .sessionConfiguration(status): "decoder session configuration failed (\(status))"
            case .hardwareDecoderUnavailable: "hardware decoder was not selected"
            case let .blockBuffer(status): "compressed block buffer failed (\(status))"
            case let .sampleBuffer(status): "compressed sample buffer failed (\(status))"
            case let .decode(status): "VideoToolbox decode failed (\(status))"
            }
        }
    }

    let usesHardwareDecoder: Bool
    let codec: VideoCodecKind

    private let callbackContext: CallbackContext
    private let callbackContextPointer: UnsafeMutableRawPointer
    private var session: VTDecompressionSession?
    private var formatDescription: CMVideoFormatDescription?
    private let lock = NSLock()
    private var invalidated = false

    init(
        generation: String,
        parameterSets: VideoParameterSets,
        onFrame: @escaping @Sendable (DecodedCameraFrame) -> Void,
        onError: @escaping @Sendable (OSStatus) -> Void
    ) throws {
        codec = parameterSets.codec

        let context = CallbackContext(
            generation: generation,
            onFrame: onFrame,
            onError: onError
        )
        callbackContext = context
        callbackContextPointer = Unmanaged.passRetained(context).toOpaque()

        do {
            let format = try Self.makeFormatDescription(parameterSets)
            formatDescription = format

            let decoderSpecification: [String: Any] = [
                kVTVideoDecoderSpecification_RequireHardwareAcceleratedVideoDecoder as String: true,
            ]
            let imageBufferAttributes: [String: Any] = [
                kCVPixelBufferPixelFormatTypeKey as String:
                    Int(kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange),
                kCVPixelBufferIOSurfacePropertiesKey as String: [:] as [String: Any],
                kCVPixelBufferMetalCompatibilityKey as String: true,
            ]
            var callback = VTDecompressionOutputCallbackRecord(
                decompressionOutputCallback: Self.outputCallback,
                decompressionOutputRefCon: callbackContextPointer
            )
            var createdSession: VTDecompressionSession?
            let status = VTDecompressionSessionCreate(
                allocator: kCFAllocatorDefault,
                formatDescription: format,
                decoderSpecification: decoderSpecification as CFDictionary,
                imageBufferAttributes: imageBufferAttributes as CFDictionary,
                outputCallback: &callback,
                decompressionSessionOut: &createdSession
            )
            guard status == noErr, let createdSession else {
                throw DecoderError.sessionCreation(status)
            }
            session = createdSession
            let realtimeStatus = VTSessionSetProperty(
                createdSession,
                key: kVTDecompressionPropertyKey_RealTime,
                value: kCFBooleanTrue
            )
            guard realtimeStatus == noErr else {
                throw DecoderError.sessionConfiguration(realtimeStatus)
            }

            var unmanagedHardwareValue: Unmanaged<CFTypeRef>?
            let hardwareStatus = withUnsafeMutablePointer(to: &unmanagedHardwareValue) {
                VTSessionCopyProperty(
                    createdSession,
                    key: kVTDecompressionPropertyKey_UsingHardwareAcceleratedVideoDecoder,
                    allocator: kCFAllocatorDefault,
                    valueOut: UnsafeMutableRawPointer($0)
                )
            }
            let hardwareValue = unmanagedHardwareValue?.takeRetainedValue()
            guard hardwareStatus == noErr,
                  (hardwareValue as? Bool) == true else {
                throw DecoderError.hardwareDecoderUnavailable
            }
            usesHardwareDecoder = true
        } catch {
            if let session {
                VTDecompressionSessionInvalidate(session)
                self.session = nil
            }
            callbackContext.deactivate()
            Unmanaged<CallbackContext>.fromOpaque(callbackContextPointer).release()
            throw error
        }
    }

    deinit {
        invalidate()
        Unmanaged<CallbackContext>.fromOpaque(callbackContextPointer).release()
    }

    /// `output: false` advances decoder state without producing a picture,
    /// which is how a viewer catches up through cached frames.
    func decode(_ frame: PublicVideoFrame, output: Bool = true) throws {
        let compressed = AVCCPacketizer.packetize(frame.nalus, codec: codec)
        guard !compressed.isEmpty else { return }

        lock.lock()
        let currentSession = invalidated ? nil : session
        let currentFormat = formatDescription
        lock.unlock()
        guard let currentSession, let currentFormat else { return }

        var blockBuffer: CMBlockBuffer?
        var status = CMBlockBufferCreateWithMemoryBlock(
            allocator: kCFAllocatorDefault,
            memoryBlock: nil,
            blockLength: compressed.count,
            blockAllocator: kCFAllocatorDefault,
            customBlockSource: nil,
            offsetToData: 0,
            dataLength: compressed.count,
            flags: 0,
            blockBufferOut: &blockBuffer
        )
        guard status == kCMBlockBufferNoErr, let blockBuffer else {
            throw DecoderError.blockBuffer(status)
        }
        status = compressed.withUnsafeBytes { bytes in
            guard let baseAddress = bytes.baseAddress else { return kCMBlockBufferBadCustomBlockSourceErr }
            return CMBlockBufferReplaceDataBytes(
                with: baseAddress,
                blockBuffer: blockBuffer,
                offsetIntoDestination: 0,
                dataLength: compressed.count
            )
        }
        guard status == kCMBlockBufferNoErr else {
            throw DecoderError.blockBuffer(status)
        }

        var timing = CMSampleTimingInfo(
            duration: .invalid,
            presentationTimeStamp: CMTime(seconds: frame.timestamp, preferredTimescale: 90_000),
            decodeTimeStamp: .invalid
        )
        var sampleSize = compressed.count
        var sampleBuffer: CMSampleBuffer?
        status = CMSampleBufferCreateReady(
            allocator: kCFAllocatorDefault,
            dataBuffer: blockBuffer,
            formatDescription: currentFormat,
            sampleCount: 1,
            sampleTimingEntryCount: 1,
            sampleTimingArray: &timing,
            sampleSizeEntryCount: 1,
            sampleSizeArray: &sampleSize,
            sampleBufferOut: &sampleBuffer
        )
        guard status == noErr, let sampleBuffer else {
            throw DecoderError.sampleBuffer(status)
        }
        let attachments = CMSampleBufferGetSampleAttachmentsArray(
            sampleBuffer,
            createIfNecessary: true
        ) as NSArray?
        if !frame.isKeyframe,
           let first = attachments?.firstObject as? NSMutableDictionary {
            first[kCMSampleAttachmentKey_NotSync] = true
        }

        var infoFlags = VTDecodeInfoFlags()
        status = VTDecompressionSessionDecodeFrame(
            currentSession,
            sampleBuffer: sampleBuffer,
            flags: output ? .asynchronousRealtime : .asynchronousWithoutOutput,
            frameRefcon: output ? nil : Self.noOutputMarker,
            infoFlagsOut: &infoFlags,
        )
        guard status == noErr else {
            throw DecoderError.decode(status)
        }
    }

    func invalidate() {
        lock.lock()
        guard !invalidated else {
            lock.unlock()
            return
        }
        invalidated = true
        let currentSession = session
        session = nil
        formatDescription = nil
        lock.unlock()

        callbackContext.deactivate()
        if let currentSession {
            VTDecompressionSessionFinishDelayedFrames(currentSession)
            VTDecompressionSessionWaitForAsynchronousFrames(currentSession)
            VTDecompressionSessionInvalidate(currentSession)
        }
    }

    private static func makeFormatDescription(
        _ parameterSets: VideoParameterSets
    ) throws -> CMVideoFormatDescription {
        let sets: [Data] = switch parameterSets {
        case let .h264(sps, pps): [sps, pps]
        case let .h265(vps, sps, pps): [vps, sps, pps]
        }
        guard sets.allSatisfy({ !$0.isEmpty }) else {
            throw DecoderError.invalidParameterSets
        }
        // VideoToolbox needs every parameter set alive for the whole call.
        let copies = sets.map { data -> UnsafeMutableBufferPointer<UInt8> in
            let copy = UnsafeMutableBufferPointer<UInt8>.allocate(capacity: data.count)
            _ = copy.initialize(from: data)
            return copy
        }
        defer { copies.forEach { $0.deallocate() } }
        var pointers = copies.map { UnsafePointer($0.baseAddress!) }
        var sizes = copies.map(\.count)

        var description: CMVideoFormatDescription?
        let status = switch parameterSets {
        case .h264:
            CMVideoFormatDescriptionCreateFromH264ParameterSets(
                allocator: kCFAllocatorDefault,
                parameterSetCount: pointers.count,
                parameterSetPointers: &pointers,
                parameterSetSizes: &sizes,
                nalUnitHeaderLength: 4,
                formatDescriptionOut: &description
            )
        case .h265:
            CMVideoFormatDescriptionCreateFromHEVCParameterSets(
                allocator: kCFAllocatorDefault,
                parameterSetCount: pointers.count,
                parameterSetPointers: &pointers,
                parameterSetSizes: &sizes,
                nalUnitHeaderLength: 4,
                extensions: nil,
                formatDescriptionOut: &description
            )
        }
        guard status == noErr, let description else {
            throw DecoderError.formatDescription(status)
        }
        return description
    }

    /// Non-nil per-frame refcon: VideoToolbox treats do-not-output as a hint.
    private static var noOutputMarker: UnsafeMutableRawPointer? {
        UnsafeMutableRawPointer(bitPattern: 1)
    }

    private static let outputCallback: VTDecompressionOutputCallback = {
        outputRefCon,
        sourceFrameRefCon,
        status,
        _,
        imageBuffer,
        presentationTimeStamp,
        _ in
        guard let outputRefCon else { return }
        let context = Unmanaged<CallbackContext>
            .fromOpaque(outputRefCon)
            .takeUnretainedValue()
        guard status == noErr else {
            context.report(error: status)
            return
        }
        guard sourceFrameRefCon == nil, let imageBuffer else { return }
        context.publish(
            pixelBuffer: imageBuffer,
            presentationTime: presentationTimeStamp
        )
    }

    private final class CallbackContext: @unchecked Sendable {
        private let lock = NSLock()
        private let generation: String
        private let onFrame: @Sendable (DecodedCameraFrame) -> Void
        private let onError: @Sendable (OSStatus) -> Void
        private var active = true

        init(
            generation: String,
            onFrame: @escaping @Sendable (DecodedCameraFrame) -> Void,
            onError: @escaping @Sendable (OSStatus) -> Void
        ) {
            self.generation = generation
            self.onFrame = onFrame
            self.onError = onError
        }

        func deactivate() {
            lock.lock()
            active = false
            lock.unlock()
        }

        func publish(pixelBuffer: CVPixelBuffer, presentationTime: CMTime) {
            lock.lock()
            let shouldPublish = active
            lock.unlock()
            guard shouldPublish else { return }
            onFrame(
                DecodedCameraFrame(
                    generation: generation,
                    pixelBuffer: pixelBuffer,
                    presentationTime: presentationTime,
                    decodedAt: ProcessInfo.processInfo.systemUptime
                )
            )
        }

        func report(error: OSStatus) {
            lock.lock()
            let shouldReport = active
            lock.unlock()
            if shouldReport { onError(error) }
        }
    }
}

private extension VTDecodeFrameFlags {
    /// Decode asynchronously without the 1x-only low-power hint. A live stream
    /// must be able to catch up promptly after a short scheduling stall.
    static let asynchronousRealtime = VTDecodeFrameFlags(rawValue: 1 << 0)
    static let asynchronousWithoutOutput = VTDecodeFrameFlags(rawValue: 1 << 0 | 1 << 1)
}
