import CoreGraphics
import Testing
@testable import UXReviewKit

/// A recording's own-window exceptions follow UX Review's windows as they open and close
/// (HS2-XT5K63, docs/04 §4.3). Transition matrix: open, close, reopen, chrome appearing, no
/// change, an update in flight, and failed updates; then realistic multi-step sequences.
struct RecordingWindowExceptionsTests {
    static let ourPID: Int32 = 99

    static func own(_ id: UInt32, layer: Int = 0) -> WindowSnapshot {
        WindowSnapshot(
            windowID: id, ownerPID: ourPID, ownerName: "UX Review", title: nil, layer: layer,
            frame: CGRect(x: 0, y: 0, width: 600, height: 400)
        )
    }

    static let safari = WindowSnapshot(
        windowID: 1, ownerPID: 10, ownerName: "Safari", title: "Docs", layer: 0,
        frame: CGRect(x: 0, y: 0, width: 800, height: 600)
    )

    let editor = own(40), settings = own(41), alert = own(42, layer: 8)
    let hud = own(44, layer: 25), dim = own(45, layer: 23)
    let chrome: Set<UInt32> = [44, 45]

    /// One check; `succeeds` finishes a returned update (nil leaves it in flight).
    static func step(
        _ exceptions: inout RecordingWindowExceptions,
        _ windows: [WindowSnapshot],
        chrome: Set<UInt32>,
        succeeds: Bool? = true
    ) -> Set<UInt32>? {
        let update = exceptions.check(windows, ownPID: ourPID, chrome: chrome)
        if update != nil, let succeeds { exceptions.finished(succeeded: succeeds) }
        return update
    }

    @Test func noChangeNeedsNoUpdate() {
        var exceptions = RecordingWindowExceptions(applied: [40])
        #expect(Self.step(&exceptions, [editor, Self.safari], chrome: chrome) == nil)
        #expect(Self.step(&exceptions, [Self.safari, editor], chrome: chrome) == nil, "reordering is no change")
        var empty = RecordingWindowExceptions(applied: [])
        #expect(Self.step(&empty, [Self.safari], chrome: chrome) == nil)
        #expect(Self.step(&empty, [], chrome: chrome) == nil)
    }

    @Test func aWindowThatOpensIsAdded() {
        var exceptions = RecordingWindowExceptions(applied: [40])
        #expect(Self.step(&exceptions, [settings, editor, Self.safari], chrome: chrome) == [40, 41])
        #expect(exceptions.applied == [40, 41])
        #expect(Self.step(&exceptions, [settings, editor, Self.safari], chrome: chrome) == nil)
    }

    @Test func aWindowThatClosesIsRemoved() {
        var exceptions = RecordingWindowExceptions(applied: [40, 41])
        #expect(Self.step(&exceptions, [editor], chrome: chrome) == [40])
        #expect(Self.step(&exceptions, [], chrome: chrome) == [])
        #expect(exceptions.applied.isEmpty)
    }

    @Test func aWindowThatReopensIsAddedAgain() {
        var exceptions = RecordingWindowExceptions(applied: [40])
        #expect(Self.step(&exceptions, [], chrome: chrome) == [])
        #expect(Self.step(&exceptions, [editor], chrome: chrome) == [40], "same id back on screen")
        #expect(Self.step(&exceptions, [Self.own(46)], chrome: chrome) == [46], "reopened as a new window")
    }

    @Test func chromeAppearingNeverUpdates() {
        var exceptions = RecordingWindowExceptions(applied: [40])
        #expect(Self.step(&exceptions, [hud, editor], chrome: chrome) == nil, "the Recording HUD")
        #expect(Self.step(&exceptions, [hud, dim, editor], chrome: chrome) == nil, "the region dim")
        #expect(Self.step(&exceptions, [editor], chrome: chrome) == nil, "chrome going away")
        // Chrome is told apart by id, not level: an alert at a high level is kept.
        #expect(Self.step(&exceptions, [hud, alert, editor], chrome: chrome) == [40, 42])
    }

    @Test func otherAppsNeverUpdate() {
        var exceptions = RecordingWindowExceptions(applied: [40])
        let more = WindowSnapshot(
            windowID: 2, ownerPID: 11, ownerName: "Notes", title: nil, layer: 0,
            frame: CGRect(x: 0, y: 0, width: 300, height: 300)
        )
        #expect(Self.step(&exceptions, [more, editor, Self.safari], chrome: chrome) == nil)
    }

    @Test func oneUpdateInFlightAtATime() {
        var exceptions = RecordingWindowExceptions(applied: [40])
        #expect(Self.step(&exceptions, [settings, editor], chrome: chrome, succeeds: nil) == [40, 41])
        #expect(exceptions.inFlight == [40, 41])
        // While it runs, more changes ask for nothing…
        #expect(Self.step(&exceptions, [alert, settings, editor], chrome: chrome, succeeds: nil) == nil)
        exceptions.finished(succeeded: true)
        #expect(exceptions.applied == [40, 41])
        #expect(exceptions.inFlight == nil)
        // …and the next check catches up with them.
        #expect(Self.step(&exceptions, [alert, settings, editor], chrome: chrome) == [40, 41, 42])
    }

    @Test func aChangeUndoneDuringAnUpdateIsUndoneAfterIt() {
        var exceptions = RecordingWindowExceptions(applied: [40])
        #expect(Self.step(&exceptions, [alert, editor], chrome: chrome, succeeds: nil) == [40, 42])
        // The alert closes before the update lands.
        #expect(Self.step(&exceptions, [editor], chrome: chrome, succeeds: nil) == nil)
        exceptions.finished(succeeded: true)
        #expect(Self.step(&exceptions, [editor], chrome: chrome) == [40])
    }

    @Test func finishingWithNothingInFlightChangesNothing() {
        var exceptions = RecordingWindowExceptions(applied: [40])
        exceptions.finished(succeeded: true)
        exceptions.finished(succeeded: false)
        #expect(exceptions.applied == [40])
        #expect(exceptions.failed == nil)
        #expect(Self.step(&exceptions, [editor], chrome: chrome) == nil)
    }

    @Test func aFailedUpdateIsRetriedThenGivenUp() {
        var exceptions = RecordingWindowExceptions(applied: [40])
        let windows = [settings, editor]
        for attempt in 1 ... RecordingWindowExceptions.maxAttempts {
            #expect(Self.step(&exceptions, windows, chrome: chrome, succeeds: false) == [40, 41], "attempt \(attempt)")
            #expect(exceptions.applied == [40], "a failed update applies nothing")
            #expect(exceptions.failed?.attempts == attempt)
        }
        #expect(Self.step(&exceptions, windows, chrome: chrome, succeeds: false) == nil, "given up on this set")
        // A different set is tried afresh, and going back to what is applied clears the failure.
        #expect(Self.step(&exceptions, [alert, settings, editor], chrome: chrome, succeeds: false) == [40, 41, 42])
        #expect(exceptions.failed?.attempts == 1)
        #expect(Self.step(&exceptions, [editor], chrome: chrome) == nil)
        #expect(exceptions.failed == nil)
        #expect(Self.step(&exceptions, windows, chrome: chrome) == [40, 41], "retried after the failure cleared")
        #expect(exceptions.applied == [40, 41])
    }

    @Test func aFailureThenSuccessResetsTheCount() {
        var exceptions = RecordingWindowExceptions(applied: [40])
        #expect(Self.step(&exceptions, [settings, editor], chrome: chrome, succeeds: false) == [40, 41])
        #expect(Self.step(&exceptions, [settings, editor], chrome: chrome) == [40, 41])
        #expect(exceptions.failed == nil)
        #expect(exceptions.applied == [40, 41])
    }

    /// A realistic recording: start with the editor, open Settings, the HUD appears, an alert
    /// comes and goes, Settings closes, everything closes, then the editor reopens.
    @Test func aRecordingSession() {
        var exceptions = RecordingWindowExceptions(applied: [40])
        let sequence: [([WindowSnapshot], Set<UInt32>?)] = [
            ([hud, editor, Self.safari], nil),
            ([hud, settings, editor, Self.safari], [40, 41]),
            ([hud, settings, editor, Self.safari], nil),
            ([hud, alert, settings, editor, Self.safari], [40, 41, 42]),
            ([hud, settings, editor, Self.safari], [40, 41]),
            ([hud, editor, Self.safari], [40]),
            ([hud, Self.safari], []),
            ([hud, Self.safari], nil),
            ([hud, editor, Self.safari], [40]),
        ]
        for (index, (windows, expected)) in sequence.enumerated() {
            #expect(Self.step(&exceptions, windows, chrome: chrome) == expected, "step \(index)")
        }
        #expect(exceptions.applied == [40])
    }
}
