import Foundation

/// Where a capture is in its life cycle. One capture runs at a time:
///
///     idle → picking → countingDown(n…1) → capturing → idle            (screenshot)
///     idle → picking → countingDown(n…1) → recording → finishing → idle (video)
///
/// Cancel (Esc, menu, hotkey) and failures return to idle from picking or counting down; a
/// running recording is stopped, never discarded. Spec: docs/04-capture.md §4.10.
public enum CapturePhase: Equatable, Sendable {
    case idle
    case picking(CaptureRequest)
    case countingDown(CaptureRequest, remaining: Int)
    case capturing
    case recording(startedAt: Date)
    case finishing

    public enum Event: Equatable, Sendable {
        case start(CaptureRequest)
        /// The target was chosen; begins the countdown (or capture, without a delay).
        case picked
        /// One countdown second elapsed.
        case tick
        case recordingStarted(Date)
        case stopRequested
        /// The capture or recording was saved.
        case finished
        case cancelled
        case failed
    }

    public var isIdle: Bool { self == .idle }

    public var isCountingDown: Bool {
        if case .countingDown = self { return true }
        return false
    }

    public var isRecording: Bool {
        if case .recording = self { return true }
        return false
    }

    /// The next phase, or nil when `event` is not valid in this phase (callers ignore it).
    public func next(_ event: Event) -> CapturePhase? {
        switch (self, event) {
        case let (.idle, .start(request)):
            .picking(request)
        case let (.picking(request), .picked):
            Self.afterCountdown(request, remaining: request.delaySeconds)
        case let (.countingDown(request, remaining), .tick):
            Self.afterCountdown(request, remaining: remaining - 1)
        case (.picking, .cancelled), (.countingDown, .cancelled), (.picking, .failed), (.countingDown, .failed):
            .idle
        case let (.capturing, .recordingStarted(date)):
            .recording(startedAt: date)
        case (.capturing, .finished), (.capturing, .failed), (.finishing, .finished), (.finishing, .failed):
            .idle
        case (.recording, .stopRequested), (.recording, .failed):
            .finishing
        default:
            nil
        }
    }

    private static func afterCountdown(_ request: CaptureRequest, remaining: Int) -> CapturePhase {
        remaining > 0 ? .countingDown(request, remaining: remaining) : .capturing
    }
}
