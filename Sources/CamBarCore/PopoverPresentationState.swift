public struct PopoverPresentationState: Equatable, Sendable {
    public enum Phase: Equatable, Sendable {
        case closed
        case opening
        case open
        case closing
    }

    public enum Command: Equatable, Sendable {
        case none
        case show
        case close
    }

    public private(set) var phase: Phase = .closed
    public private(set) var wantsVisible = false
    public private(set) var lastIntentTimestamp = -Double.infinity
    public private(set) var presentationID: UInt64 = 0
    private var reopenRequestedDuringClosing = false

    public init() {}

    public mutating func toggle(at timestamp: Double) -> Command {
        guard accept(timestamp) else { return .none }
        wantsVisible.toggle()
        reopenRequestedDuringClosing = phase == .closing && wantsVisible
        return reconcile()
    }

    public mutating func requestOpen(at timestamp: Double) -> Command {
        guard accept(timestamp) else { return .none }
        wantsVisible = true
        reopenRequestedDuringClosing = phase == .closing
        return reconcile()
    }

    public mutating func requestClose(at timestamp: Double) -> Command {
        guard accept(timestamp) else { return .none }
        wantsVisible = false
        reopenRequestedDuringClosing = false
        return reconcile()
    }

    public mutating func didShow() -> Command {
        switch phase {
        case .opening:
            phase = .open
            return reconcile()
        case .closed:
            wantsVisible = false
            reopenRequestedDuringClosing = false
            return .close
        case .closing:
            wantsVisible = false
            reopenRequestedDuringClosing = false
            phase = .closing
            return .close
        case .open:
            return .none
        }
    }

    public mutating func didClose() -> Command {
        switch phase {
        case .closing:
            phase = .closed
            guard reopenRequestedDuringClosing, wantsVisible else {
                wantsVisible = false
                reopenRequestedDuringClosing = false
                return .none
            }
            reopenRequestedDuringClosing = false
            return reconcile()
        case .opening, .open:
            phase = .closed
            wantsVisible = false
            reopenRequestedDuringClosing = false
            return .none
        case .closed:
            return .none
        }
    }

    public mutating func presentationFailed() {
        guard phase == .opening else { return }
        phase = .closed
        wantsVisible = false
    }

    private mutating func accept(_ timestamp: Double) -> Bool {
        guard timestamp > lastIntentTimestamp else { return false }
        lastIntentTimestamp = timestamp
        return true
    }

    private mutating func reconcile() -> Command {
        switch (phase, wantsVisible) {
        case (.closed, true):
            presentationID &+= 1
            phase = .opening
            return .show
        case (.open, false):
            phase = .closing
            return .close
        case (.opening, false):
            // AppKit can ignore close() before an in-flight popover has
            // actually presented and then send neither delegate callback.
            // didShow (or the presentation timeout) reconciles this intent.
            return .none
        case (.opening, true), (.closing, _), (.closed, false), (.open, true):
            return .none
        }
    }
}
