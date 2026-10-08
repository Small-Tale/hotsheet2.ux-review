import Foundation

/// Keeps a display or region recording's own-window exceptions current (HS2-XT5K63).
///
/// The ScreenCaptureKit filter of a display or region capture excludes UX Review as a whole and
/// lists its on-screen windows that are not capture chrome as exceptions
/// (`WindowSelection.ownWindowsToCapture`, HS2-63B0PJ). A filter's exceptions are fixed, so while
/// recording the app re-reads the window list every `pollInterval` and updates the running
/// stream's filter whenever that set changes: an editor, Settings, or an alert that opens
/// mid-recording is then in the movie, and one that closes drops out. Chrome that appears (the
/// "Recording" HUD, the dim) never changes the set, so it never causes an update.
///
/// Updating the stream is asynchronous, so at most one update is in flight. A check during it
/// asks for nothing; the next check after it compares against what was applied. A failed update
/// leaves the applied set as it was and is retried by later checks, up to `maxAttempts` times for
/// the same set. Spec: docs/04-capture.md §4.3.
public struct RecordingWindowExceptions: Sendable {
    /// How often the recording re-reads the window list.
    public static let pollInterval: TimeInterval = 0.25
    /// How many times one set is tried before the follower stops retrying it.
    public static let maxAttempts = 3

    /// The exceptions the stream's filter lists now.
    public private(set) var applied: Set<UInt32>
    /// The set an update is in flight for; nil when none.
    public private(set) var inFlight: Set<UInt32>?
    /// The set the last updates failed for, and how many times in a row.
    public private(set) var failed: (set: Set<UInt32>, attempts: Int)?

    /// `applied` is the set the recording's filter started with.
    public init(applied: Set<UInt32>) {
        self.applied = applied
    }

    /// Checks the on-screen windows (front to back, any owner) against the filter. Returns the
    /// exceptions to apply when the stream's filter must be updated, or nil when it need not be
    /// (nothing changed, an update is in flight, or this set has failed `maxAttempts` times).
    /// A returned set is in flight until `finished` is called.
    public mutating func check(_ windows: [WindowSnapshot], ownPID: Int32, chrome: Set<UInt32>) -> Set<UInt32>? {
        guard inFlight == nil else { return nil }
        let wanted = WindowSelection.ownWindowsToCapture(in: windows, ownPID: ownPID, chrome: chrome)
        guard wanted != applied else {
            failed = nil
            return nil
        }
        if let failed, failed.set == wanted, failed.attempts >= Self.maxAttempts { return nil }
        inFlight = wanted
        return wanted
    }

    /// The in-flight update ended. On success its set is what the filter lists from now on.
    public mutating func finished(succeeded: Bool) {
        guard let target = inFlight else { return }
        inFlight = nil
        if succeeded {
            applied = target
            failed = nil
        } else {
            let attempts = failed.map { $0.set == target ? $0.attempts : 0 } ?? 0
            failed = (target, attempts + 1)
        }
    }
}
