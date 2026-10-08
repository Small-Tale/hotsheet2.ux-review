import Foundation

/// The window list a window pick hit-tests against, kept current while the pick runs, so the
/// highlight and the click follow windows that move, resize, open, close, or change stacking
/// order (HS2-VJ8VE8). Spec: docs/04-capture.md §4.2.
///
/// Reading the window server's list costs about a millisecond, so pointer moves reuse a list that
/// is at most `pointerMaxAge` old, while a click, a switch into window mode, and the periodic
/// timer always read it again. Times are monotonic seconds (`ProcessInfo.systemUptime`).
public struct LiveWindowList: Sendable {
    /// Why the picker wants the list.
    public enum Reason: Equatable, Sendable {
        /// The pointer moved: reuse a list that is fresh enough.
        case pointerMoved
        /// The periodic timer fired: windows may have changed under a still pointer.
        case timer
        /// The pick is being taken: it must use what is on screen now.
        case click
        /// Window mode just started (picking began, or Space switched to it).
        case modeSwitch
    }

    /// The oldest list a pointer move reuses (at most 20 reads a second while the pointer moves).
    public static let pointerMaxAge: TimeInterval = 0.05
    /// How often the picker re-reads the list while the pointer is still.
    public static let timerInterval: TimeInterval = 0.2

    /// Front to back, as the window server lists them. Empty until the first read.
    public private(set) var windows: [WindowSnapshot] = []
    /// When `windows` was read; nil before the first read.
    public private(set) var readAt: TimeInterval?
    /// How many times the list was read (for tests and diagnostics).
    public private(set) var reads = 0

    public init() {}

    /// Whether `reason` at `now` needs a new read rather than the list on hand.
    public func needsRead(for reason: Reason, now: TimeInterval) -> Bool {
        guard let readAt else { return true }
        switch reason {
        case .click, .modeSwitch, .timer:
            return true
        case .pointerMoved:
            // A clock that went backwards (it shouldn't) counts as stale rather than fresh forever.
            let age = now - readAt
            return age < 0 || age >= Self.pointerMaxAge
        }
    }

    /// Reads the list again when `reason` needs it. Returns whether the list changed (frames,
    /// order, windows added or removed), so the caller knows to hit-test and redraw again.
    @discardableResult
    public mutating func refresh(for reason: Reason, now: TimeInterval, read: () -> [WindowSnapshot]) -> Bool {
        guard needsRead(for: reason, now: now) else { return false }
        let next = read()
        reads += 1
        readAt = now
        guard next != windows else { return false }
        windows = next
        return true
    }
}
