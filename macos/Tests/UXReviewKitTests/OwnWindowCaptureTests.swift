import CoreGraphics
import Testing
@testable import UXReviewKit

/// Which of UX Review's own windows display and region captures keep (HS2-63B0PJ, docs/04 §4.3).
struct OwnWindowCaptureTests {
    static let ourPID: Int32 = 99

    static func own(_ id: UInt32, layer: Int = 0) -> WindowSnapshot {
        WindowSnapshot(
            windowID: id, ownerPID: ourPID, ownerName: "UX Review", title: nil, layer: layer,
            frame: CGRect(x: 0, y: 0, width: 600, height: 400)
        )
    }

    /// Other apps' windows: never listed, they are captured anyway.
    let others = [
        WindowSnapshot(
            windowID: 1, ownerPID: 10, ownerName: "Safari", title: "Docs", layer: 0,
            frame: CGRect(x: 0, y: 0, width: 800, height: 600)
        ),
        WindowSnapshot(
            windowID: 2, ownerPID: 11, ownerName: "Control Center", title: nil, layer: 25,
            frame: CGRect(x: 0, y: 0, width: 2000, height: 30)
        ),
    ]

    let editor = own(40), submit = own(41), statusItem = own(42, layer: 25)
    let overlay = own(43, layer: 1000), hud = own(44, layer: 25), dim = own(45, layer: 23)
    let chrome: Set<UInt32> = [43, 44, 45]

    /// The editor, Submit Review, and the menu bar item are kept; the picker overlay, the HUD, and
    /// the recording dim are not, whatever their level.
    @Test func keepsOwnWindowsExceptCaptureChrome() {
        let list = [overlay, hud, dim, editor, submit, statusItem] + others
        #expect(WindowSelection.ownWindowsToCapture(in: list, ownPID: Self.ourPID, chrome: chrome) == [40, 41, 42])
    }

    @Test func edgeCases() {
        // Only other apps on screen, or nothing at all: no exceptions.
        #expect(WindowSelection.ownWindowsToCapture(in: others, ownPID: Self.ourPID, chrome: chrome).isEmpty)
        #expect(WindowSelection.ownWindowsToCapture(in: [], ownPID: Self.ourPID, chrome: chrome).isEmpty)
        // No chrome registered: every own window is kept.
        #expect(WindowSelection.ownWindowsToCapture(in: [editor, hud], ownPID: Self.ourPID, chrome: []) == [40, 44])
        // A chrome id that is no longer on screen changes nothing.
        #expect(WindowSelection.ownWindowsToCapture(in: [editor], ownPID: Self.ourPID, chrome: [99]) == [40])
        // Only chrome on screen: nothing is kept.
        #expect(WindowSelection.ownWindowsToCapture(in: [overlay, hud, dim], ownPID: Self.ourPID, chrome: chrome).isEmpty)
    }

    /// Captured, but still never picked: the editor on top under the pointer occludes.
    @Test func thePickerStillNeverPicksOwnWindows() {
        #expect(WindowSelection.pickTarget(at: CGPoint(x: 100, y: 100), in: [editor] + others, ownPID: Self.ourPID) == nil)
        #expect(WindowSelection.pickTarget(at: CGPoint(x: 100, y: 100), in: [overlay] + others, ownPID: Self.ourPID)?.windowID == 1)
    }
}
