import AppKit
import ApplicationServices
import CoreGraphics
import Darwin
import Foundation

private let appBundleIdentifier = "com.cambar"
private let statusItemIdentifier = "com.cambar.status-item"
private let telemetryURL = FileManager.default.homeDirectoryForCurrentUser
    .appendingPathComponent("Library/Caches/CamBar/direct/direct-stream-events.jsonl")

private struct Options {
    var reopenCycles = 3
    var firstOpenIdleSeconds: TimeInterval = 35
    var screenshotPath = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
        .appendingPathComponent(".build/smoke-ui-popover.png").path

    static func parse() throws -> Self {
        var result = Self()
        var arguments = Array(CommandLine.arguments.dropFirst())
        while !arguments.isEmpty {
            let argument = arguments.removeFirst()
            switch argument {
            case "--reopen-cycles":
                guard let value = arguments.first, let count = Int(value), count >= 1 else {
                    throw SmokeError.message("--reopen-cycles requires an integer of at least 1")
                }
                result.reopenCycles = count
                arguments.removeFirst()
            case "--screenshot":
                guard let value = arguments.first, !value.isEmpty else {
                    throw SmokeError.message("--screenshot requires a path")
                }
                result.screenshotPath = NSString(string: value).expandingTildeInPath
                arguments.removeFirst()
            case "--first-open-idle":
                guard let value = arguments.first,
                      let seconds = TimeInterval(value),
                      seconds >= 6 else {
                    throw SmokeError.message("--first-open-idle requires at least 6 seconds")
                }
                result.firstOpenIdleSeconds = seconds
                arguments.removeFirst()
            case "-h", "--help":
                print("Usage: smoke_ui.sh [--reopen-cycles COUNT] [--first-open-idle SECONDS] [--screenshot PATH]")
                exit(0)
            default:
                throw SmokeError.message("unknown argument: \(argument)")
            }
        }
        return result
    }
}

private enum SmokeError: Error, CustomStringConvertible {
    case message(String)

    var description: String {
        switch self {
        case let .message(message): message
        }
    }
}

private func assertCamBarIsNotFrontmost(_ context: String) throws {
    guard let current = NSWorkspace.shared.frontmostApplication else {
        throw SmokeError.message("frontmost application disappeared \(context)")
    }
    if current.bundleIdentifier == appBundleIdentifier {
        throw SmokeError.message("CamBar stole focus \(context)")
    }
}

private struct TelemetryEvent: Decodable {
    let schemaVersion: Int?
    let sequence: Int?
    let sessionID: String
    let component: String
    let event: String
    let surface: String?
    let openID: String?
    let videoSessionID: String?
    let uptimeMilliseconds: Int
    let elapsedMilliseconds: Int?
    let detail: String?

    enum CodingKeys: String, CodingKey {
        case schemaVersion = "schema_version"
        case sequence
        case sessionID = "session_id"
        case component
        case event
        case surface
        case openID = "open_id"
        case videoSessionID = "video_session_id"
        case uptimeMilliseconds = "uptime_ms"
        case elapsedMilliseconds = "elapsed_ms"
        case detail
    }
}

private final class TelemetryReader {
    private let decoder = JSONDecoder()
    private(set) var sessionID: String?

    func latestLaunchSession() throws -> String? {
        try allEvents().last(where: { $0.component == "app" && $0.event == "launch" })?.sessionID
    }

    func waitForLaunch(excluding previousSession: String?, timeout: TimeInterval) throws {
        try wait(timeout: timeout, description: "fresh launch telemetry") { events in
            guard let launch = events.last(where: {
                $0.component == "app"
                    && $0.event == "launch"
                    && $0.sessionID != previousSession
            }) else {
                return false
            }
            self.sessionID = launch.sessionID
            return true
        }
    }

    func events() throws -> [TelemetryEvent] {
        guard let sessionID else { return [] }
        let sessionEvents = try allEvents().filter { $0.sessionID == sessionID }
        guard let first = sessionEvents.first,
              first.event == "launch",
              first.schemaVersion == 2,
              first.sequence == 1 else {
            throw SmokeError.message("active telemetry session does not start with schema-v2 launch sequence 1")
        }
        for (prior, current) in zip(sessionEvents, sessionEvents.dropFirst()) {
            guard current.schemaVersion == 2,
                  let priorSequence = prior.sequence,
                  let currentSequence = current.sequence,
                  currentSequence == priorSequence + 1 else {
                throw SmokeError.message(
                    "active telemetry sequence gap after \(prior.sequence.map { String($0) } ?? "missing")"
                )
            }
        }
        return sessionEvents
    }

    func count(_ event: String, component: String? = nil, surface: String? = nil) throws -> Int {
        try matchingEvents(event, component: component, surface: surface).count
    }

    func matchingEvents(
        _ event: String,
        component: String? = nil,
        surface: String? = nil,
        openID: String? = nil
    ) throws -> [TelemetryEvent] {
        try events().filter {
            $0.event == event
                && (component == nil || $0.component == component)
                && (surface == nil || $0.surface == surface)
                && (openID == nil || $0.openID == openID)
        }
    }

    func waitForCount(
        _ event: String,
        count expected: Int,
        timeout: TimeInterval,
        component: String? = nil,
        surface: String? = nil
    ) throws {
        try wait(timeout: timeout, description: "\(event) count \(expected)") { _ in
            try self.count(event, component: component, surface: surface) >= expected
        }
    }

    func waitForEvent(
        _ event: String,
        timeout: TimeInterval,
        component: String? = nil,
        surface: String? = nil,
        openID: String? = nil,
        afterUptimeMilliseconds: Int? = nil
    ) throws -> TelemetryEvent {
        var result: TelemetryEvent?
        try wait(timeout: timeout, description: event) { _ in
            result = try self.matchingEvents(
                event,
                component: component,
                surface: surface,
                openID: openID
            ).last(where: {
                guard let afterUptimeMilliseconds else { return true }
                return $0.uptimeMilliseconds >= afterUptimeMilliseconds
            })
            return result != nil
        }
        guard let result else {
            throw SmokeError.message("timed out waiting for \(event)")
        }
        return result
    }

    func assertNoFailures() throws {
        for forbidden in [
            "session_reconnecting",
            "stream_stalled",
            "decode_submission_failed",
            "decode_callback_failed",
            "frame_enqueue_failed",
            "visible_frame_timeout",
            "open_frame_deadline_exceeded",
            "surface_recovery_started",
        ] {
            let matches = try count(forbidden)
            guard matches == 0 else {
                throw SmokeError.message("telemetry recorded \(matches) \(forbidden) event(s)")
            }
        }
        let activations = try count("app_activated", component: "app")
        guard activations == 0 else {
            throw SmokeError.message("telemetry recorded \(activations) CamBar activation event(s)")
        }
    }

    private func wait(
        timeout: TimeInterval,
        description: String,
        predicate: ([TelemetryEvent]) throws -> Bool
    ) throws {
        let deadline = Date().addingTimeInterval(timeout)
        repeat {
            let events = try allEvents()
            if try predicate(events) { return }
            RunLoop.current.run(until: Date().addingTimeInterval(0.05))
        } while Date() < deadline
        throw SmokeError.message("timed out waiting for \(description)")
    }

    private func allEvents() throws -> [TelemetryEvent] {
        guard FileManager.default.fileExists(atPath: telemetryURL.path) else { return [] }
        let contents = try String(contentsOf: telemetryURL, encoding: .utf8)
        var lines = contents.split(separator: "\n", omittingEmptySubsequences: true)
        if !contents.hasSuffix("\n"), !lines.isEmpty {
            lines.removeLast()
        }
        return try lines.enumerated().compactMap { index, line in
            do {
                let data = Data(line.utf8)
                let object = try JSONSerialization.jsonObject(with: data) as? [String: Any]
                guard object?["schema_version"] as? Int == 2 else { return nil }
                return try decoder.decode(TelemetryEvent.self, from: data)
            } catch {
                throw SmokeError.message("malformed telemetry row \(index + 1): \(error)")
            }
        }
    }
}

private final class StatusItemDriver {
    private let processIdentifier: pid_t

    init(processIdentifier: pid_t) {
        self.processIdentifier = processIdentifier
    }

    func waitForFrame(timeout: TimeInterval) throws -> CGRect {
        try waitForFrame(identifier: statusItemIdentifier, timeout: timeout)
    }

    func waitForFrame(identifier: String, timeout: TimeInterval) throws -> CGRect {
        let deadline = Date().addingTimeInterval(timeout)
        var previousFrame: CGRect?
        repeat {
            if let element = findElement(identifier: identifier),
               let frame = frame(of: element),
               !frame.isEmpty,
               isOnActiveDisplay(frame) {
                if previousFrame == frame {
                    return frame
                }
                previousFrame = frame
            } else {
                previousFrame = nil
            }
            RunLoop.current.run(until: Date().addingTimeInterval(0.1))
        } while Date() < deadline
        throw SmokeError.message("could not locate AX identifier \(identifier)")
    }

    func press(identifier: String) throws {
        guard let element = findElement(identifier: identifier) else {
            throw SmokeError.message("could not locate AX identifier \(identifier)")
        }
        guard AXUIElementPerformAction(element, kAXPressAction as CFString) == .success else {
            throw SmokeError.message("could not press AX identifier \(identifier)")
        }
    }

    func clickStatusItem() throws {
        _ = try waitForFrame(timeout: 2)
        try press(identifier: statusItemIdentifier)
    }

    func burstClickStatusItem(count: Int = 2) throws {
        precondition(count >= 2)
        _ = try waitForFrame(timeout: 2)
        for _ in 0..<count {
            try press(identifier: statusItemIdentifier)
            usleep(10_000)
        }
        usleep(40_000)
    }

    func closeFirstWindow() throws {
        let application = AXUIElementCreateApplication(processIdentifier)
        guard let window = elementsAttribute(kAXWindowsAttribute as String, of: application).first else {
            throw SmokeError.message("CamBar popout window was not exposed through Accessibility")
        }
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(
            window,
            kAXCloseButtonAttribute as CFString,
            &value
        ) == .success,
        let closeButton = value as! AXUIElement? else {
            throw SmokeError.message("CamBar popout close button was unavailable")
        }
        guard AXUIElementPerformAction(closeButton, kAXPressAction as CFString) == .success else {
            throw SmokeError.message("CamBar popout close button could not be pressed")
        }
    }

    private func findElement(identifier: String) -> AXUIElement? {
        let application = AXUIElementCreateApplication(processIdentifier)
        var queue: [(AXUIElement, Int)] = [(application, 0)]
        var visited = Set<CFHashCode>()
        var inspected = 0

        while !queue.isEmpty, inspected < 2_000 {
            let (element, depth) = queue.removeFirst()
            let hash = CFHash(element)
            guard visited.insert(hash).inserted else { continue }
            inspected += 1

            if stringAttribute(kAXIdentifierAttribute as String, of: element) == identifier {
                return element
            }
            guard depth < 12 else { continue }
            for attribute in [
                kAXChildrenAttribute as String,
                kAXMenuBarAttribute as String,
                kAXExtrasMenuBarAttribute as String,
                kAXWindowsAttribute as String,
            ] {
                queue.append(contentsOf: elementsAttribute(attribute, of: element).map { ($0, depth + 1) })
            }
        }
        return nil
    }

    private func stringAttribute(_ attribute: String, of element: AXUIElement) -> String? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &value) == .success else {
            return nil
        }
        return value as? String
    }

    private func elementsAttribute(_ attribute: String, of element: AXUIElement) -> [AXUIElement] {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &value) == .success else {
            return []
        }
        if let elements = value as? [AXUIElement] { return elements }
        if let element = value as! AXUIElement? { return [element] }
        return []
    }

    private func frame(of element: AXUIElement) -> CGRect? {
        var positionValue: CFTypeRef?
        var sizeValue: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXPositionAttribute as CFString, &positionValue) == .success,
              AXUIElementCopyAttributeValue(element, kAXSizeAttribute as CFString, &sizeValue) == .success,
              let positionValue,
              let sizeValue,
              CFGetTypeID(positionValue) == AXValueGetTypeID(),
              CFGetTypeID(sizeValue) == AXValueGetTypeID() else {
            return nil
        }
        var position = CGPoint.zero
        var size = CGSize.zero
        guard AXValueGetValue(positionValue as! AXValue, .cgPoint, &position),
              AXValueGetValue(sizeValue as! AXValue, .cgSize, &size) else {
            return nil
        }
        return CGRect(origin: position, size: size)
    }

    private func isOnActiveDisplay(_ frame: CGRect) -> Bool {
        var displays = [CGDirectDisplayID](repeating: 0, count: 16)
        var count: UInt32 = 0
        guard CGGetActiveDisplayList(UInt32(displays.count), &displays, &count) == .success else {
            return false
        }
        return displays.prefix(Int(count)).contains {
            CGDisplayBounds($0).contains(CGPoint(x: frame.midX, y: frame.midY))
        }
    }
}

private func runProcess(_ executable: String, _ arguments: [String], allowFailure: Bool = false) throws {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: executable)
    process.arguments = arguments
    process.standardOutput = FileHandle.nullDevice
    process.standardError = FileHandle.nullDevice
    try process.run()
    process.waitUntilExit()
    if !allowFailure, process.terminationStatus != 0 {
        throw SmokeError.message("command failed: \(executable) \(arguments.joined(separator: " "))")
    }
}

private struct ProcessResourceSnapshot {
    let processIdentifier: pid_t
    let residentBytes: UInt64
    let cpuNanoseconds: UInt64
    let threadCount: Int32

    func summary(prefix: String) -> String {
        String(
            format: "%@ resource pid=%d resident_mb=%.1f cpu_seconds=%.3f threads=%d",
            prefix,
            processIdentifier,
            Double(residentBytes) / 1_048_576,
            Double(cpuNanoseconds) / 1_000_000_000,
            threadCount
        )
    }

    func delta(from baseline: ProcessResourceSnapshot) -> String? {
        guard processIdentifier == baseline.processIdentifier,
              cpuNanoseconds >= baseline.cpuNanoseconds else { return nil }
        return String(
            format: "IDLE_DELTA resource pid=%d resident_mb=%+.1f cpu_seconds=+%.3f threads=%+d",
            processIdentifier,
            (Double(residentBytes) - Double(baseline.residentBytes)) / 1_048_576,
            Double(cpuNanoseconds - baseline.cpuNanoseconds) / 1_000_000_000,
            threadCount - baseline.threadCount
        )
    }
}

private final class OwnedProcesses {
    private let appURL: URL
    private let pidFileURL: URL
    private(set) var appPID: pid_t?

    init(appURL: URL, pidFileURL: URL) {
        self.appURL = appURL
        self.pidFileURL = pidFileURL
    }

    func registerApp(_ application: NSRunningApplication) throws {
        let pid = application.processIdentifier
        let expectedPath = appURL.appendingPathComponent("Contents/MacOS/CamBar").standardizedFileURL.path
        guard processPath(pid) == expectedPath else {
            throw SmokeError.message("launched CamBar PID \(pid) has an unexpected executable path")
        }
        appPID = pid
        try writePIDFile()
    }

    func assertNoChildProcesses() throws {
        guard let appPID else { throw SmokeError.message("CamBar PID was not registered") }
        let children = directChildren(of: appPID)
        guard children.isEmpty else {
            throw SmokeError.message("native CamBar spawned child process(es): \(children)")
        }
    }

    func resourceSnapshot() throws -> ProcessResourceSnapshot {
        guard let appPID, processPath(appPID) == appExecutablePath else {
            throw SmokeError.message("CamBar process is unavailable for resource sampling")
        }
        var info = proc_taskinfo()
        let expectedSize = Int32(MemoryLayout<proc_taskinfo>.size)
        let actualSize = proc_pidinfo(appPID, PROC_PIDTASKINFO, 0, &info, expectedSize)
        guard actualSize == expectedSize else {
            throw SmokeError.message("could not sample CamBar process resources")
        }
        return ProcessResourceSnapshot(
            processIdentifier: appPID,
            residentBytes: info.pti_resident_size,
            cpuNanoseconds: info.pti_total_user + info.pti_total_system,
            threadCount: info.pti_threadnum
        )
    }

    func terminate() {
        if let appPID,
           processPath(appPID) == appExecutablePath,
           let application = NSRunningApplication(processIdentifier: appPID) {
            application.terminate()
        }
        usleep(500_000)
        if let appPID, processPath(appPID) == appExecutablePath {
            Darwin.kill(appPID, SIGKILL)
        }
    }

    private var appExecutablePath: String {
        appURL.appendingPathComponent("Contents/MacOS/CamBar").standardizedFileURL.path
    }

    private func writePIDFile() throws {
        let contents = appPID.map { "app \($0) 0\n" } ?? ""
        try contents.write(to: pidFileURL, atomically: true, encoding: .utf8)
    }

    private func directChildren(of parentPID: pid_t) -> [pid_t] {
        var capacity = 16
        while true {
            var children = [pid_t](repeating: 0, count: capacity)
            let count = proc_listchildpids(
                parentPID,
                &children,
                Int32(children.count * MemoryLayout<pid_t>.size)
            )
            guard count > 0 else { return [] }
            if Int(count) < capacity {
                return Array(children.prefix(Int(count))).filter { $0 > 0 }
            }
            capacity = max(capacity * 2, Int(count) + 16)
        }
    }

    private func processPath(_ pid: pid_t) -> String? {
        guard pid > 0 else { return nil }
        var buffer = [CChar](repeating: 0, count: 4_096)
        let length = proc_pidpath(pid, &buffer, UInt32(buffer.count))
        guard length > 0 else { return nil }
        return String(cString: buffer)
    }
}

private func runningCamBar(appURL: URL) -> NSRunningApplication? {
    let expectedExecutable = appURL.appendingPathComponent("Contents/MacOS/CamBar").standardizedFileURL
    return NSRunningApplication.runningApplications(withBundleIdentifier: appBundleIdentifier).first {
        $0.executableURL?.standardizedFileURL == expectedExecutable
    }
}

private func waitForCamBar(appURL: URL, timeout: TimeInterval) throws -> NSRunningApplication {
    let deadline = Date().addingTimeInterval(timeout)
    repeat {
        if let application = runningCamBar(appURL: appURL), !application.isTerminated {
            return application
        }
        RunLoop.current.run(until: Date().addingTimeInterval(0.05))
    } while Date() < deadline
    throw SmokeError.message("CamBar did not launch")
}

private func capturePopoverScreenshot(processIdentifier: pid_t, path: String) throws {
    guard let windows = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID)
        as? [[String: Any]] else {
        throw SmokeError.message("window inventory unavailable; cannot capture required screenshot")
    }
    let candidates: [(id: CGWindowID, area: CGFloat)] = windows.compactMap { window in
        guard let ownerPID = window[kCGWindowOwnerPID as String] as? Int,
              ownerPID == Int(processIdentifier),
              let number = window[kCGWindowNumber as String] as? CGWindowID,
              let boundsDictionary = window[kCGWindowBounds as String] as? [String: Any],
              let bounds = CGRect(dictionaryRepresentation: boundsDictionary as CFDictionary),
              bounds.width >= 300,
              bounds.height >= 150 else { return nil }
        return (number, bounds.width * bounds.height)
    }
    guard let window = candidates.max(by: { $0.area < $1.area }) else {
        throw SmokeError.message("popover window not found for required screenshot")
    }
    let outputURL = URL(fileURLWithPath: path)
    try FileManager.default.createDirectory(
        at: outputURL.deletingLastPathComponent(),
        withIntermediateDirectories: true
    )
    let captureStartedAt = Date()
    try runProcess("/usr/sbin/screencapture", ["-x", "-l", String(window.id), outputURL.path])
    let values = try outputURL.resourceValues(forKeys: [.contentModificationDateKey, .fileSizeKey])
    guard let modifiedAt = values.contentModificationDate,
          modifiedAt >= captureStartedAt.addingTimeInterval(-1),
          (values.fileSize ?? 0) > 0 else {
        throw SmokeError.message("required popover screenshot was not freshly written")
    }
    try assertScreenshotContainsVideo(outputURL)
    print("Screenshot visual artifact: \(outputURL.path)")
}

private func assertScreenshotContainsVideo(_ url: URL) throws {
    guard let data = try? Data(contentsOf: url),
          let bitmap = NSBitmapImageRep(data: data),
          bitmap.pixelsWide > 20,
          bitmap.pixelsHigh > 20 else {
        throw SmokeError.message("could not decode screenshot for black-frame analysis")
    }
    var luminances: [Double] = []
    for row in 1...18 {
        for column in 1...32 {
            let x = column * (bitmap.pixelsWide - 1) / 33
            let y = row * (bitmap.pixelsHigh - 1) / 19
            guard let color = bitmap.colorAt(x: x, y: y)?.usingColorSpace(.deviceRGB) else { continue }
            luminances.append(
                0.2126 * Double(color.redComponent)
                    + 0.7152 * Double(color.greenComponent)
                    + 0.0722 * Double(color.blueComponent)
            )
        }
    }
    guard !luminances.isEmpty else {
        throw SmokeError.message("screenshot contained no sampleable pixels")
    }
    let mean = luminances.reduce(0, +) / Double(luminances.count)
    let variance = luminances.reduce(0) { $0 + pow($1 - mean, 2) } / Double(luminances.count)
    let nonBlackFraction = Double(luminances.filter { $0 > 0.04 }.count) / Double(luminances.count)
    guard nonBlackFraction >= 0.10, sqrt(variance) >= 0.02 else {
        throw SmokeError.message(
            String(
                format: "screenshot failed video-content check (nonblack=%.2f contrast=%.3f)",
                nonBlackFraction,
                sqrt(variance)
            )
        )
    }
}

private func screenshotPath(for cycle: Int, basePath: String) -> String {
    guard cycle > 1 else { return basePath }
    let url = URL(fileURLWithPath: basePath)
    let pathExtension = url.pathExtension
    let baseName = url.deletingPathExtension().lastPathComponent
    let fileName = pathExtension.isEmpty
        ? "\(baseName)-cycle-\(cycle)"
        : "\(baseName)-cycle-\(cycle).\(pathExtension)"
    return url.deletingLastPathComponent().appendingPathComponent(fileName).path
}

private func assertExactCounts(
    telemetry: TelemetryReader,
    statusClicks: Int,
    presentationRequests: Int,
    playbackOpens: Int,
    closes: Int
) throws {
    let expectations: [(String, Int)] = [
        ("status_click", statusClicks),
        ("menu_open_requested", presentationRequests),
        ("playback_open_started", playbackOpens),
        ("cover_shown", playbackOpens),
        ("cover_hidden", playbackOpens),
        ("live_view", playbackOpens),
        ("menu_closed", closes),
    ]
    for (event, expected) in expectations {
        let actual = try telemetry.count(event, surface: "menu")
        guard actual == expected else {
            throw SmokeError.message("expected exactly \(expected) \(event) event(s), found \(actual)")
        }
    }
    let sessionsStarted = try telemetry.count("session_started", component: "stream")
    guard sessionsStarted == 1 else {
        throw SmokeError.message("expected exactly one app-owned stream generation, found \(sessionsStarted)")
    }
    let sessionsStopped = try telemetry.count("session_stopped", component: "stream")
    guard sessionsStopped == 0 else {
        throw SmokeError.message("app-owned stream stopped \(sessionsStopped) time(s)")
    }
    try telemetry.assertNoFailures()
}

private func requireOpenEvent(
    _ eventName: String,
    openID: String,
    videoSessionID: String,
    after statusClick: TelemetryEvent,
    telemetry: TelemetryReader,
    timeout: TimeInterval = 3
) throws -> TelemetryEvent {
    let event = try telemetry.waitForEvent(
        eventName,
        timeout: timeout,
        component: "video",
        surface: "menu",
        openID: openID,
        afterUptimeMilliseconds: statusClick.uptimeMilliseconds
    )
    guard event.videoSessionID == videoSessionID else {
        let actualSessionID = event.videoSessionID ?? "missing"
        throw SmokeError.message(
            "\(eventName) for open \(openID) used video session \(actualSessionID), "
                + "expected \(videoSessionID)"
        )
    }
    return event
}

private struct WarmOpenResult {
    let openID: String
    let elapsedMilliseconds: Int
}

private func requireWarmOpen(
    after statusClick: TelemetryEvent,
    videoSessionID: String,
    telemetry: TelemetryReader
) throws -> WarmOpenResult {
    guard let openID = statusClick.openID else {
        throw SmokeError.message("opening status_click had no open_id")
    }
    _ = try telemetry.waitForEvent(
        "menu_open_requested",
        timeout: 3,
        component: "app",
        surface: "menu",
        openID: openID,
        afterUptimeMilliseconds: statusClick.uptimeMilliseconds
    )
    let playbackOpen = try requireOpenEvent(
        "playback_open_started",
        openID: openID,
        videoSessionID: videoSessionID,
        after: statusClick,
        telemetry: telemetry
    )
    _ = try requireOpenEvent(
        "cover_shown",
        openID: openID,
        videoSessionID: videoSessionID,
        after: statusClick,
        telemetry: telemetry
    )
    let liveView = try requireOpenEvent(
        "live_view",
        openID: openID,
        videoSessionID: videoSessionID,
        after: statusClick,
        telemetry: telemetry
    )
    _ = try requireOpenEvent(
        "cover_hidden",
        openID: openID,
        videoSessionID: videoSessionID,
        after: statusClick,
        telemetry: telemetry
    )
    guard let elapsedMilliseconds = liveView.elapsedMilliseconds,
          (0...500).contains(elapsedMilliseconds) else {
        let actualElapsed = liveView.elapsedMilliseconds.map { String($0) } ?? "missing"
        throw SmokeError.message(
            "open \(openID) live_view elapsed_ms was \(actualElapsed); expected at most 500"
        )
    }
    let observedElapsed = liveView.uptimeMilliseconds - statusClick.uptimeMilliseconds
    guard (0...500).contains(observedElapsed),
          playbackOpen.uptimeMilliseconds >= statusClick.uptimeMilliseconds else {
        throw SmokeError.message(
            "open \(openID) telemetry spanned \(observedElapsed) ms "
                + "from status_click to live_view; expected at most 500"
        )
    }
    for indicator in try telemetry.matchingEvents(
        "connection_indicator_shown",
        component: "video",
        surface: "menu",
        openID: openID
    ) where indicator.videoSessionID != videoSessionID {
        throw SmokeError.message("connection_indicator_shown was attributed to the wrong video session")
    }
    return WarmOpenResult(openID: openID, elapsedMilliseconds: elapsedMilliseconds)
}

private func detailInteger(_ key: String, in event: TelemetryEvent) -> Int? {
    event.detail?
        .split(whereSeparator: { $0.isWhitespace })
        .first(where: { $0.hasPrefix("\(key)=") })
        .flatMap { Int($0.dropFirst(key.count + 1)) }
}

private func assertAdvancingHeartbeat(_ event: TelemetryEvent, generation: String) throws {
    guard event.videoSessionID == generation,
          let intervalFrames = detailInteger("interval_frames", in: event),
          intervalFrames > 0 else {
        throw SmokeError.message("frame_heartbeat did not report advancing frames for generation \(generation)")
    }
}

private func percentile(_ values: [Int], _ fraction: Double) -> Int {
    precondition(!values.isEmpty)
    let sorted = values.sorted()
    let rank = max(1, Int(ceil(fraction * Double(sorted.count))))
    return sorted[min(rank - 1, sorted.count - 1)]
}

private func run() throws {
    let options = try Options.parse()
    let appURL = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Applications/CamBar.app")
    guard FileManager.default.fileExists(atPath: appURL.path) else {
        throw SmokeError.message("CamBar is not installed at \(appURL.path)")
    }
    guard AXIsProcessTrusted() else {
        throw SmokeError.message(
            "Accessibility permission is required for the terminal running Scripts/smoke_ui.sh"
        )
    }
    guard runningCamBar(appURL: appURL) == nil else {
        throw SmokeError.message("CamBar is already running; refusing to disturb it")
    }
    guard let pidFilePath = ProcessInfo.processInfo.environment["CAMBAR_SMOKE_PID_FILE"],
          !pidFilePath.isEmpty else {
        throw SmokeError.message("CAMBAR_SMOKE_PID_FILE is required; run through Scripts/smoke_ui.sh")
    }

    try assertCamBarIsNotFrontmost("before launch")
    let ownership = OwnedProcesses(appURL: appURL, pidFileURL: URL(fileURLWithPath: pidFilePath))
    defer {
        ownership.terminate()
    }

    let telemetry = TelemetryReader()
    let previousTelemetrySession = try telemetry.latestLaunchSession()
    try runProcess("/usr/bin/open", ["-g", "-j", "-n", appURL.path])
    let application = try waitForCamBar(appURL: appURL, timeout: 10)
    try ownership.registerApp(application)
    try ownership.assertNoChildProcesses()
    try telemetry.waitForLaunch(excluding: previousTelemetrySession, timeout: 10)
    try assertCamBarIsNotFrontmost("after background launch")

    let driver = StatusItemDriver(processIdentifier: application.processIdentifier)
    _ = try driver.waitForFrame(timeout: 10)
    try driver.clickStatusItem()
    _ = try telemetry.waitForEvent(
        "status_click",
        timeout: 2,
        component: "app",
        surface: "menu"
    )
    guard let coldClick = try telemetry.matchingEvents(
        "status_click",
        component: "app",
        surface: "menu"
    ).last,
          let coldOpenID = coldClick.openID else {
        throw SmokeError.message("immediate cold click did not create an open intent")
    }

    let streamSession = try telemetry.waitForEvent(
        "session_started",
        timeout: 12,
        component: "stream"
    )
    guard let streamGeneration = streamSession.videoSessionID else {
        throw SmokeError.message("stream session_started event has no video_session_id")
    }
    let connected = try telemetry.waitForEvent("connected", timeout: 12, component: "rtsp")
    guard connected.videoSessionID == streamGeneration else {
        throw SmokeError.message("RTSP connection used a different stream generation")
    }
    let decoderStarted = try telemetry.waitForEvent("started", timeout: 12, component: "decoder")
    guard decoderStarted.videoSessionID == streamGeneration,
          decoderStarted.detail?.contains("hardware=true") == true else {
        throw SmokeError.message("decoder did not start in hardware for the active stream generation")
    }
    let firstFrame = try telemetry.waitForEvent(
        "first_frame",
        timeout: 12,
        component: "video"
    )
    guard firstFrame.videoSessionID == streamGeneration else {
        throw SmokeError.message("first_frame used a different stream generation")
    }
    let coldLiveView = try requireOpenEvent(
        "live_view",
        openID: coldOpenID,
        videoSessionID: streamGeneration,
        after: coldClick,
        telemetry: telemetry,
        timeout: 6
    )
    let coldElapsed = coldLiveView.uptimeMilliseconds - coldClick.uptimeMilliseconds
    guard coldElapsed <= 5_500 else {
        throw SmokeError.message("cold click-to-visible took \(coldElapsed) ms; hard limit is 5500 ms")
    }
    print("COLD_OPEN_LATENCY click_to_visible_ms=\(coldElapsed)")
    try capturePopoverScreenshot(
        processIdentifier: application.processIdentifier,
        path: screenshotPath(for: 1, basePath: options.screenshotPath) + ".cold.png"
    )
    try driver.clickStatusItem()
    _ = try telemetry.waitForEvent(
        "menu_closed",
        timeout: 3,
        component: "app",
        surface: "menu",
        openID: coldOpenID,
        afterUptimeMilliseconds: coldLiveView.uptimeMilliseconds
    )
    let firstHeartbeat = try telemetry.waitForEvent(
        "frame_heartbeat",
        timeout: 12,
        component: "video",
        afterUptimeMilliseconds: firstFrame.uptimeMilliseconds
    )
    guard streamSession.uptimeMilliseconds <= connected.uptimeMilliseconds,
          connected.uptimeMilliseconds <= decoderStarted.uptimeMilliseconds,
          decoderStarted.uptimeMilliseconds <= firstFrame.uptimeMilliseconds,
          firstFrame.uptimeMilliseconds <= firstHeartbeat.uptimeMilliseconds else {
        throw SmokeError.message("native stream health telemetry arrived out of order")
    }
    try assertAdvancingHeartbeat(firstHeartbeat, generation: streamGeneration)
    try telemetry.assertNoFailures()

    let totalOpenCycles = 1 + options.reopenCycles
    var warmOpenLatencies: [Int] = []

    let heartbeatCountBeforeIdle = try telemetry.count("frame_heartbeat", component: "video")
    let idleBaseline = try ownership.resourceSnapshot()
    print(idleBaseline.summary(prefix: "IDLE_BASELINE"))
    RunLoop.current.run(until: Date().addingTimeInterval(options.firstOpenIdleSeconds))
    let heartbeatsAfterIdle = try telemetry.matchingEvents(
        "frame_heartbeat",
        component: "video"
    )
    guard heartbeatsAfterIdle.count > heartbeatCountBeforeIdle else {
        throw SmokeError.message("stream did not emit another frame_heartbeat during idle")
    }
    for heartbeat in heartbeatsAfterIdle.dropFirst(heartbeatCountBeforeIdle) {
        try assertAdvancingHeartbeat(heartbeat, generation: streamGeneration)
    }
    let idleFinal = try ownership.resourceSnapshot()
    print(idleFinal.summary(prefix: "IDLE_FINAL"))
    guard idleFinal.residentBytes <= 256 * 1_048_576 else {
        throw SmokeError.message("CamBar resident memory exceeded 256 MB while idle-warm")
    }
    guard idleFinal.threadCount <= 64 else {
        throw SmokeError.message("CamBar exceeded 64 threads while idle-warm")
    }
    if let delta = idleFinal.delta(from: idleBaseline) {
        print(delta)
        let cpuPercent = Double(idleFinal.cpuNanoseconds - idleBaseline.cpuNanoseconds)
            / 1_000_000_000 / options.firstOpenIdleSeconds * 100
        print(String(format: "IDLE_CPU_PERCENT whole_cambar=%.2f", cpuPercent))
        guard cpuPercent <= 35 else {
            throw SmokeError.message(String(format: "CamBar idle-warm CPU was %.2f%%; limit is 35%%", cpuPercent))
        }
        let residentGrowth = Int64(idleFinal.residentBytes) - Int64(idleBaseline.residentBytes)
        guard residentGrowth <= 32 * 1_048_576 else {
            throw SmokeError.message("CamBar resident memory grew by more than 32 MB while idle-warm")
        }
    }
    try ownership.assertNoChildProcesses()
    try telemetry.assertNoFailures()
    try assertCamBarIsNotFrontmost("after first-open idle")

    let popoutStatusClickCount = try telemetry.count("status_click", surface: "menu")
    try driver.clickStatusItem()
    try telemetry.waitForCount(
        "status_click",
        count: popoutStatusClickCount + 1,
        timeout: 2,
        component: "app",
        surface: "menu"
    )
    guard let popoutMenuClick = try telemetry.matchingEvents(
        "status_click",
        component: "app",
        surface: "menu"
    ).last else {
        throw SmokeError.message("popout setup click was not recorded")
    }
    let popoutMenuOpen = try requireWarmOpen(
        after: popoutMenuClick,
        videoSessionID: streamGeneration,
        telemetry: telemetry
    )
    warmOpenLatencies.append(popoutMenuOpen.elapsedMilliseconds)
    _ = try driver.waitForFrame(
        identifier: "com.cambar.open-window",
        timeout: 2
    )
    try driver.press(identifier: "com.cambar.open-window")
    let windowRequested = try telemetry.waitForEvent(
        "window_open_requested",
        timeout: 2,
        component: "app",
        surface: "window",
        afterUptimeMilliseconds: popoutMenuClick.uptimeMilliseconds
    )
    _ = try telemetry.waitForEvent(
        "live_view",
        timeout: 3,
        component: "video",
        surface: "window",
        afterUptimeMilliseconds: windowRequested.uptimeMilliseconds
    )
    try capturePopoverScreenshot(
        processIdentifier: application.processIdentifier,
        path: options.screenshotPath + ".window.png"
    )
    try driver.closeFirstWindow()
    _ = try telemetry.waitForEvent(
        "window_closed",
        timeout: 2,
        component: "app",
        surface: "window",
        afterUptimeMilliseconds: windowRequested.uptimeMilliseconds
    )
    try telemetry.assertNoFailures()
    print("PASS: native popout displayed non-black video and closed")

    for cycle in 1...totalOpenCycles {
        let phase = cycle == 1 ? "idle first open" : "reopen \(cycle - 1)/\(options.reopenCycles)"
        let statusClicksBeforeOpen = try telemetry.count("status_click", surface: "menu")
        try driver.clickStatusItem()
        try telemetry.waitForCount(
            "status_click",
            count: statusClicksBeforeOpen + 1,
            timeout: 2,
            component: "app",
            surface: "menu"
        )
        guard let statusClick = try telemetry.matchingEvents(
            "status_click",
            component: "app",
            surface: "menu"
        ).last else { throw SmokeError.message("opening status_click was not recorded") }
        let warmOpen = try requireWarmOpen(
            after: statusClick,
            videoSessionID: streamGeneration,
            telemetry: telemetry
        )
        let openID = warmOpen.openID
        warmOpenLatencies.append(warmOpen.elapsedMilliseconds)
        try telemetry.assertNoFailures()
        try assertCamBarIsNotFrontmost("after \(phase) open")
        try capturePopoverScreenshot(
            processIdentifier: application.processIdentifier,
            path: screenshotPath(for: cycle, basePath: options.screenshotPath)
        )

        let statusClicksBeforeClose = try telemetry.count("status_click", surface: "menu")
        try driver.clickStatusItem()
        try telemetry.waitForCount(
            "status_click",
            count: statusClicksBeforeClose + 1,
            timeout: 2,
            component: "app",
            surface: "menu"
        )
        guard let closeClick = try telemetry.matchingEvents(
            "status_click",
            component: "app",
            surface: "menu"
        ).last,
              closeClick.openID == openID else {
            throw SmokeError.message("closing status_click did not retain open_id \(openID)")
        }
        _ = try telemetry.waitForEvent(
            "menu_closed",
            timeout: 3,
            component: "app",
            surface: "menu",
            openID: openID,
            afterUptimeMilliseconds: closeClick.uptimeMilliseconds
        )
        try telemetry.assertNoFailures()
        try ownership.assertNoChildProcesses()
        try assertCamBarIsNotFrontmost("after \(phase) close")
        print("PASS: \(phase) open/live-frame/close")
    }

    let openingBurstClickCount = try telemetry.count("status_click", component: "app", surface: "menu")
    try driver.burstClickStatusItem()
    try telemetry.waitForCount(
        "status_click",
        count: openingBurstClickCount + 2,
        timeout: 2,
        component: "app",
        surface: "menu"
    )
    let openingBurstClicks = Array(try telemetry.matchingEvents(
        "status_click",
        component: "app",
        surface: "menu"
    ).suffix(2))
    guard openingBurstClicks.count == 2,
          let openingBurstID = openingBurstClicks[0].openID,
          openingBurstClicks[1].openID == openingBurstID,
          openingBurstClicks[0].detail?.contains("command=show") == true,
          openingBurstClicks[0].detail?.contains("state=opening") == true,
          openingBurstClicks[1].detail?.contains("command=none") == true,
          openingBurstClicks[1].detail?.contains("desired=false") == true,
          openingBurstClicks[1].detail?.contains("state=opening") == true else {
        throw SmokeError.message("open-close burst did not land while the popover was opening")
    }
    _ = try telemetry.waitForEvent(
        "menu_closed",
        timeout: 3,
        component: "app",
        surface: "menu",
        openID: openingBurstID,
        afterUptimeMilliseconds: openingBurstClicks[1].uptimeMilliseconds
    )
    guard try telemetry.matchingEvents(
        "playback_open_started",
        component: "video",
        surface: "menu",
        openID: openingBurstID
    ).isEmpty else {
        throw SmokeError.message("open-close-during-opening burst incorrectly started playback")
    }
    try telemetry.assertNoFailures()
    try assertCamBarIsNotFrontmost("after open-close-during-opening burst")

    let raceOpenClickCount = try telemetry.count("status_click", component: "app", surface: "menu")
    try driver.clickStatusItem()
    try telemetry.waitForCount(
        "status_click",
        count: raceOpenClickCount + 1,
        timeout: 2,
        component: "app",
        surface: "menu"
    )
    guard let raceOpenClick = try telemetry.matchingEvents(
        "status_click",
        component: "app",
        surface: "menu"
    ).last else { throw SmokeError.message("race setup open click was not recorded") }
    let raceWarmOpen = try requireWarmOpen(
        after: raceOpenClick,
        videoSessionID: streamGeneration,
        telemetry: telemetry
    )
    let raceOpenID = raceWarmOpen.openID
    warmOpenLatencies.append(raceWarmOpen.elapsedMilliseconds)

    let closingBurstClickCount = try telemetry.count("status_click", component: "app", surface: "menu")
    try driver.burstClickStatusItem()
    try telemetry.waitForCount(
        "status_click",
        count: closingBurstClickCount + 2,
        timeout: 2,
        component: "app",
        surface: "menu"
    )
    let closingBurstClicks = Array(try telemetry.matchingEvents(
        "status_click",
        component: "app",
        surface: "menu"
    ).suffix(2))
    guard closingBurstClicks.count == 2,
          closingBurstClicks[0].openID == raceOpenID,
          closingBurstClicks[0].detail?.contains("command=close") == true,
          closingBurstClicks[0].detail?.contains("state=closing") == true,
          let reopenedID = closingBurstClicks[1].openID,
          reopenedID != raceOpenID,
          closingBurstClicks[1].detail?.contains("command=none") == true,
          closingBurstClicks[1].detail?.contains("desired=true") == true,
          closingBurstClicks[1].detail?.contains("state=closing") == true else {
        throw SmokeError.message("close-reopen burst did not land while the popover was closing")
    }
    _ = try telemetry.waitForEvent(
        "menu_closed",
        timeout: 3,
        component: "app",
        surface: "menu",
        openID: raceOpenID,
        afterUptimeMilliseconds: closingBurstClicks[0].uptimeMilliseconds
    )
    let convergedReopen = try requireWarmOpen(
        after: closingBurstClicks[1],
        videoSessionID: streamGeneration,
        telemetry: telemetry
    )
    let convergedReopenID = convergedReopen.openID
    warmOpenLatencies.append(convergedReopen.elapsedMilliseconds)
    guard convergedReopenID == reopenedID else {
        throw SmokeError.message("close-reopen burst converged to the wrong open_id")
    }
    try capturePopoverScreenshot(
        processIdentifier: application.processIdentifier,
        path: screenshotPath(for: totalOpenCycles + 1, basePath: options.screenshotPath)
    )
    let finalCloseClickCount = try telemetry.count("status_click", component: "app", surface: "menu")
    try driver.clickStatusItem()
    try telemetry.waitForCount(
        "status_click",
        count: finalCloseClickCount + 1,
        timeout: 2,
        component: "app",
        surface: "menu"
    )
    guard let finalCloseClick = try telemetry.matchingEvents(
        "status_click",
        component: "app",
        surface: "menu"
    ).last, finalCloseClick.openID == reopenedID else {
        throw SmokeError.message("final burst cleanup close lost the reopened open_id")
    }
    _ = try telemetry.waitForEvent(
        "menu_closed",
        timeout: 3,
        component: "app",
        surface: "menu",
        openID: reopenedID,
        afterUptimeMilliseconds: finalCloseClick.uptimeMilliseconds
    )
    try telemetry.assertNoFailures()
    try assertCamBarIsNotFrontmost("after lifecycle bursts")

    try assertExactCounts(
        telemetry: telemetry,
        statusClicks: totalOpenCycles * 2 + 9,
        presentationRequests: totalOpenCycles + 5,
        playbackOpens: totalOpenCycles + 4,
        closes: totalOpenCycles + 5
    )
    let observedGenerations = Set(try telemetry.events().compactMap(\.videoSessionID))
    guard observedGenerations == Set([streamGeneration]) else {
        throw SmokeError.message(
            "expected only stream generation \(streamGeneration), found \(observedGenerations.sorted())"
        )
    }
    let decoderStarts = try telemetry.matchingEvents("started", component: "decoder")
    guard !decoderStarts.isEmpty,
          decoderStarts.allSatisfy({ $0.detail?.contains("hardware=true") == true }) else {
        throw SmokeError.message("not every decoder generation used hardware decoding")
    }
    let p50 = percentile(warmOpenLatencies, 0.50)
    let p95 = percentile(warmOpenLatencies, 0.95)
    let enforceP95Target = warmOpenLatencies.count >= 20
    print(
        "WARM_OPEN_LATENCY samples=\(warmOpenLatencies.count) p50_ms=\(p50) p95_ms=\(p95) "
            + "limit_ms=500 p95_target_ms=100 enforced=\(enforceP95Target)"
    )
    if enforceP95Target, p95 > 100 {
        throw SmokeError.message("warm-open p95 was \(p95) ms; expected at most 100 ms with 20+ samples")
    }
    try ownership.assertNoChildProcesses()
    try assertCamBarIsNotFrontmost("at completion")
    print(
        "PASS: \(totalOpenCycles) warm open/close cycles plus lifecycle bursts, <=500 ms live view, "
            + "one hardware-decoded native stream, advancing heartbeats, no pipeline failures, child processes, "
            + "or focus activation; screenshots retained as visual artifacts"
    )
}

do {
    try run()
} catch {
    fputs("ERROR: \(error)\n", stderr)
    exit(1)
}
