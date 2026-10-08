import CoreGraphics
import Foundation
import Testing
@testable import UXReviewKit

/// The window pick's live window list (HS2-VJ8VE8, docs/04 §4.2): when it reads the window
/// server again, and that the pick follows windows that move, resize, reorder, open, and close.
struct LiveWindowListTests {
    static let ownPID: Int32 = 99
    /// Capture chrome window ids (picker overlays, HUDs, the recording dim).
    static let chrome: Set<UInt32> = [4, 5]

    static func window(_ id: UInt32, pid: Int32 = 10, layer: Int = 0, _ frame: CGRect) -> WindowSnapshot {
        WindowSnapshot(windowID: id, ownerPID: pid, ownerName: "App \(pid)", title: "W\(id)", layer: layer, frame: frame)
    }

    /// A fake window server: what `read` returns is whatever the test put on screen last.
    final class Screen {
        var windows: [WindowSnapshot]
        var reads = 0
        init(_ windows: [WindowSnapshot]) { self.windows = windows }
        func read() -> [WindowSnapshot] {
            reads += 1
            return windows
        }
    }

    // MARK: - Transition matrix: list state × reason

    enum State: CaseIterable { case empty, fresh, stale }

    /// Every reason against every list state: only a pointer move over a fresh list reuses it.
    @Test(arguments: State.allCases, [LiveWindowList.Reason.pointerMoved, .timer, .click, .modeSwitch])
    func readsAgainUnlessAPointerMoveFindsAFreshList(state: State, reason: LiveWindowList.Reason) {
        var list = LiveWindowList()
        var now: TimeInterval = 100
        if state != .empty {
            list.refresh(for: .modeSwitch, now: now) { [Self.window(1, CGRect(x: 0, y: 0, width: 100, height: 100))] }
            now += state == .fresh ? LiveWindowList.pointerMaxAge / 2 : LiveWindowList.pointerMaxAge * 2
        }
        let expected = !(state == .fresh && reason == .pointerMoved)
        #expect(list.needsRead(for: reason, now: now) == expected)
        let before = list.reads
        list.refresh(for: reason, now: now) { [] }
        #expect(list.reads == before + (expected ? 1 : 0))
        if expected { #expect(list.readAt == now) }
    }

    @Test func startsEmptyAndUnread() {
        let list = LiveWindowList()
        #expect(list.windows.isEmpty)
        #expect(list.readAt == nil)
        #expect(list.reads == 0)
    }

    /// Changed reports a different list, not a read: re-reading the same layout changes nothing.
    @Test func reportsWhetherTheListChanged() {
        let screen = Screen([Self.window(1, CGRect(x: 0, y: 0, width: 100, height: 100))])
        var list = LiveWindowList()
        var changed = list.refresh(for: .modeSwitch, now: 0, read: screen.read)
        #expect(changed)
        changed = list.refresh(for: .timer, now: 1, read: screen.read)
        #expect(!changed)
        changed = list.refresh(for: .click, now: 2, read: screen.read)
        #expect(!changed)
        screen.windows[0].frame.origin.x = 5
        changed = list.refresh(for: .timer, now: 3, read: screen.read)
        #expect(changed)
        #expect(list.windows == screen.windows)
        #expect(screen.reads == 4)
    }

    /// A burst of pointer moves reads at most once per `pointerMaxAge`.
    @Test func throttlesPointerMoves() {
        let screen = Screen([])
        var list = LiveWindowList()
        list.refresh(for: .modeSwitch, now: 10, read: screen.read)
        // 100 moves 5 ms apart = 0.5 s: about one read per 50 ms.
        for step in 1 ... 100 {
            list.refresh(for: .pointerMoved, now: 10 + Double(step) * 0.005, read: screen.read)
        }
        #expect((9 ... 12).contains(screen.reads), "reads: \(screen.reads)")
    }

    /// Adversarial: a clock that steps backwards reads again rather than trusting the old list forever.
    @Test func backwardsClockCountsAsStale() {
        var list = LiveWindowList()
        list.refresh(for: .modeSwitch, now: 50) { [] }
        #expect(list.needsRead(for: .pointerMoved, now: 49))
        #expect(!list.needsRead(for: .pointerMoved, now: 50.01))
    }

    // MARK: - The pick follows the live layout

    /// What the picker does: refresh for the reason, then hit-test the list.
    static func pick(
        _ list: inout LiveWindowList,
        _ screen: Screen,
        at point: CGPoint,
        reason: LiveWindowList.Reason,
        now: TimeInterval
    ) -> UInt32? {
        list.refresh(for: reason, now: now, read: screen.read)
        return WindowSelection.pickTarget(at: point, in: list.windows, chrome: chrome)?.windowID
    }

    /// The reviewer's case: windows move and change order during the pick, and the highlight
    /// (timer, pointer) and the click follow them.
    @Test func followsWindowsThatMoveResizeAndReorder() {
        let editor = Self.window(1, CGRect(x: 0, y: 0, width: 800, height: 600))
        let browser = Self.window(2, pid: 11, CGRect(x: 900, y: 0, width: 800, height: 600))
        let screen = Screen([editor, browser])
        var list = LiveWindowList()
        let point = CGPoint(x: 100, y: 100)
        #expect(Self.pick(&list, screen, at: point, reason: .modeSwitch, now: 0) == 1)

        // The browser moves under the still pointer, on top: the timer catches it.
        screen.windows = [Self.window(2, pid: 11, CGRect(x: 50, y: 50, width: 400, height: 300)), editor]
        #expect(Self.pick(&list, screen, at: point, reason: .timer, now: LiveWindowList.timerInterval) == 2)

        // The editor is brought to the front: a click a moment later picks it, even inside the
        // pointer throttle window.
        screen.windows = [editor, Self.window(2, pid: 11, CGRect(x: 50, y: 50, width: 400, height: 300))]
        #expect(Self.pick(&list, screen, at: point, reason: .pointerMoved, now: 0.21) == 2) // throttled: still the old list
        #expect(Self.pick(&list, screen, at: point, reason: .click, now: 0.22) == 1)

        // The editor shrinks away from the pointer: the browser behind it is under it now.
        screen.windows = [Self.window(1, CGRect(x: 300, y: 300, width: 200, height: 200)), screen.windows[1]]
        #expect(Self.pick(&list, screen, at: point, reason: .pointerMoved, now: 0.5) == 2)
    }

    /// Windows that open or close during the pick; an empty screen then a refill (adversarial).
    @Test func followsWindowsThatOpenAndClose() {
        let screen = Screen([])
        var list = LiveWindowList()
        let point = CGPoint(x: 10, y: 10)
        #expect(Self.pick(&list, screen, at: point, reason: .modeSwitch, now: 0) == nil)
        screen.windows = [Self.window(7, CGRect(x: 0, y: 0, width: 200, height: 200))]
        #expect(Self.pick(&list, screen, at: point, reason: .timer, now: 0.2) == 7)
        screen.windows = []
        #expect(Self.pick(&list, screen, at: point, reason: .click, now: 0.25) == nil)
        screen.windows = [Self.window(8, CGRect(x: 0, y: 0, width: 200, height: 200))]
        #expect(Self.pick(&list, screen, at: point, reason: .timer, now: 0.45) == 8)
    }

    /// The existing rules still hold on a refreshed list: a floating panel wins over the document
    /// behind it, one of UX Review's own windows raised on top is picked (HS2-E14X2P), and
    /// capture chrome is never picked and never hides what is under it.
    @Test func keepsTheFloatingAndOwnWindowRules() {
        let document = Self.window(1, CGRect(x: 0, y: 0, width: 1000, height: 800))
        let screen = Screen([document])
        var list = LiveWindowList()
        let point = CGPoint(x: 100, y: 100)
        #expect(Self.pick(&list, screen, at: point, reason: .modeSwitch, now: 0) == 1)
        screen.windows = [Self.window(2, layer: 3, CGRect(x: 50, y: 50, width: 200, height: 200)), document]
        #expect(Self.pick(&list, screen, at: point, reason: .timer, now: 0.2) == 2)
        screen.windows = [Self.window(3, pid: Self.ownPID, CGRect(x: 0, y: 0, width: 300, height: 300))] + screen.windows
        #expect(Self.pick(&list, screen, at: point, reason: .timer, now: 0.4) == 3)
        // The picker overlay itself (UX Review chrome, screen-saver level) never occludes.
        screen.windows = [Self.window(4, pid: Self.ownPID, layer: 1000, CGRect(x: 0, y: 0, width: 3000, height: 2000)), document]
        #expect(Self.pick(&list, screen, at: point, reason: .click, now: 0.41) == 1)
        // Neither does chrome at an app level (the recording dim), while our editor still counts.
        screen.windows = [Self.window(5, pid: Self.ownPID, CGRect(x: 0, y: 0, width: 3000, height: 2000))] + screen.windows
        #expect(Self.pick(&list, screen, at: point, reason: .click, now: 0.42) == 1)
        screen.windows.insert(Self.window(3, pid: Self.ownPID, CGRect(x: 0, y: 0, width: 300, height: 300)), at: 1)
        #expect(Self.pick(&list, screen, at: point, reason: .click, now: 0.43) == 3)
        // Closed again: the document is back.
        screen.windows.remove(at: 1)
        #expect(Self.pick(&list, screen, at: point, reason: .timer, now: 0.63) == 1)
    }
}
