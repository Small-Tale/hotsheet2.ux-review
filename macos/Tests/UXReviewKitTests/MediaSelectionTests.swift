import Foundation
import Testing
@testable import UXReviewKit

/// The media strip's multiple selection (`HS2-0TQ6RP`, docs/06 §6.7.2): click, ⌘-click, ⇧-click,
/// the editor moving away from the selection, and captures removed or added underneath it.
struct MediaSelectionTests {
    /// Drives a selection the way the editor does: after each click the canvas shows the primary.
    struct Strip {
        var order: [String]
        var current: String?
        var selection = MediaSelection()

        init(_ order: [String], current: String? = nil) {
            self.order = order
            self.current = current ?? order.first
        }

        var selected: [String] { selection.selected(order: order, current: current) }

        mutating func click(_ id: String, _ click: MediaSelection.Click) {
            selection.click(id, click, order: order, current: current)
            if let primary = selection.primary, order.contains(primary) { current = primary }
        }

        /// A capture removed from the draft: the editor drops it and, when it was showing, shows
        /// the next remaining one (else the previous), as `AnnotationEditor.dropMedia` does.
        mutating func remove(_ ids: Set<String>) {
            let before = order
            order.removeAll(where: ids.contains)
            selection.prune(to: order)
            if let shown = current, ids.contains(shown) {
                let index = before.firstIndex(of: shown) ?? 0
                current = before[index...].first(where: order.contains) ?? before[..<index].last(where: order.contains)
            }
        }
    }

    /// One long walk through every click kind, including repeats, toggling off the shown capture,
    /// the last selected capture, ranges in both directions, and an unknown id.
    @Test func clickTransitionsWalk() {
        var strip = Strip(["a", "b", "c", "d", "e"])
        #expect(strip.selected == ["a"]) // nothing clicked yet: the shown capture
        // (click, id, selected afterwards, shown afterwards)
        let steps: [(MediaSelection.Click, String, [String], String)] = [
            (.plain, "c", ["c"], "c"),
            (.extend, "e", ["c", "d", "e"], "e"),
            // The anchor stays at c: a range the other way replaces the first.
            (.extend, "a", ["a", "b", "c"], "a"),
            (.toggle, "e", ["a", "b", "c", "e"], "e"),
            // ⌘-click the shown capture off: its nearest selected neighbor shows (none after e).
            (.toggle, "e", ["a", "b", "c"], "c"),
            // ⌘-click another one off: the shown one stays.
            (.toggle, "b", ["a", "c"], "c"),
            // The shown one off again: no selected capture after it, so the one before.
            (.toggle, "c", ["a"], "a"),
            // The last selected capture can't be ⌘-clicked away.
            (.toggle, "a", ["a"], "a"),
            (.extend, "d", ["a", "b", "c", "d"], "d"),
            // The same click again changes nothing.
            (.extend, "d", ["a", "b", "c", "d"], "d"),
            (.plain, "b", ["b"], "b"),
            (.plain, "b", ["b"], "b"),
            (.toggle, "d", ["b", "d"], "d"),
            // ⌘-clicking off a capture that isn't shown keeps the shown one.
            (.toggle, "b", ["d"], "d"),
            (.toggle, "a", ["a", "d"], "a"),
            // The shown one off, with a selected capture after it: that one shows.
            (.toggle, "a", ["d"], "d"),
        ]
        for (index, (click, id, selected, shown)) in steps.enumerated() {
            strip.click(id, click)
            #expect(strip.selected == selected, "step \(index + 1): \(click) \(id)")
            #expect(strip.current == shown, "step \(index + 1): \(click) \(id)")
        }
        let before = strip.selection
        strip.click("z", .plain)
        strip.click("z", .toggle)
        strip.click("z", .extend)
        #expect(strip.selection == before) // unknown ids change nothing
    }

    @Test func toggleOffTheShownCapturePrefersTheNextSelectedOne() {
        var strip = Strip(["a", "b", "c", "d"])
        strip.click("a", .plain)
        strip.click("c", .toggle)
        strip.click("b", .toggle) // [a, b, c], b shown
        strip.click("b", .toggle)
        #expect(strip.selected == ["a", "c"] && strip.current == "c")
        // ⇧-click after the shown capture was toggled off ranges from the new shown capture.
        strip.click("d", .extend)
        #expect(strip.selected == ["c", "d"] && strip.current == "d")
    }

    /// The editor moving away from the selection by any other means (undo, selecting an
    /// annotation on another capture, a script) collapses it to what is shown, and the next
    /// ⌘- or ⇧-click starts from there.
    @Test func movingAwayCollapsesTheSelection() {
        var strip = Strip(["a", "b", "c", "d", "e"])
        strip.click("a", .plain)
        strip.click("c", .toggle)
        #expect(strip.selected == ["a", "c"])
        strip.current = "b" // e.g. undo jumped back to b
        #expect(strip.selected == ["b"])
        strip.click("d", .toggle)
        #expect(strip.selected == ["b", "d"] && strip.current == "d")
        strip.current = "e"
        strip.click("c", .extend) // the anchor is the shown capture, not the stale d
        #expect(strip.selected == ["c", "d", "e"] && strip.current == "c")
        // Showing the selection's primary again by navigation shows the selection again.
        strip.current = "a"
        #expect(strip.selected == ["a"])
        strip.current = "c"
        #expect(strip.selected == ["c", "d", "e"])
    }

    /// Captures removed underneath the selection (⌘⌫, the review session, another window), then
    /// the draft emptied and refilled, reusing ids.
    @Test func removalsPruneTheSelection() {
        var strip = Strip(["a", "b", "c", "d", "e"])
        strip.click("a", .plain)
        strip.click("c", .toggle)
        strip.click("e", .toggle)
        #expect(strip.selected == ["a", "c", "e"] && strip.current == "e")
        // A selected capture that isn't shown goes: the rest stays selected.
        strip.remove(["c"])
        #expect(strip.selected == ["a", "e"])
        // An unselected one goes: nothing changes.
        strip.remove(["b"])
        #expect(strip.selected == ["a", "e"])
        // The shown one goes: the editor shows its neighbor, selected alone.
        strip.remove(["e"])
        #expect(strip.current == "d" && strip.selected == ["d"])
        // Every capture goes: nothing is selected or shown.
        strip.remove(["a", "d"])
        #expect(strip.current == nil && strip.selected.isEmpty)
        #expect(strip.selection.ids.isEmpty && strip.selection.primary == nil && strip.selection.anchor == nil)
        // Refilled with a reused id: it is shown (the editor shows the first capture) but no
        // stale selection comes back.
        strip.order = ["a", "c"]
        strip.current = "a"
        #expect(strip.selected == ["a"])
        strip.click("c", .extend)
        #expect(strip.selected == ["a", "c"])
    }

    @Test func removalTargetsFollowFinderRules() {
        var strip = Strip(["a", "b", "c", "d"])
        strip.click("a", .plain)
        strip.click("c", .extend)
        let order = strip.order
        let current = strip.current
        // A thumbnail in the selection: the whole selection. Outside it: just that one.
        #expect(strip.selection.removalTargets(for: "b", order: order, current: current) == ["a", "b", "c"])
        #expect(strip.selection.removalTargets(for: "d", order: order, current: current) == ["d"])
        // No thumbnail (the Edit menu, ⌘⌫): the selection. Unknown: nothing.
        #expect(strip.selection.removalTargets(for: nil, order: order, current: current) == ["a", "b", "c"])
        #expect(strip.selection.removalTargets(for: "z", order: order, current: current).isEmpty)
        // No media: nothing.
        #expect(MediaSelection().removalTargets(for: nil, order: [], current: nil).isEmpty)
    }

    @Test func emptyStripSelectsNothingUntilClicked() {
        var strip = Strip([])
        #expect(strip.selected.isEmpty)
        strip.order = ["a"]
        strip.click("a", .toggle)
        #expect(strip.selected == ["a"] && strip.current == "a")
    }

    @Test func removalPromptNamesOneOrCountsSeveral() {
        #expect(CaptureRemovalPrompt(filenames: ["capture-2.png"], annotations: 0) == CaptureRemovalPrompt(
            message: "Remove capture-2.png from this review?",
            detail: "The capture will be deleted from the draft. You can't undo this.",
            button: "Remove Capture"
        ))
        #expect(
            CaptureRemovalPrompt(filenames: ["capture-2.png"], annotations: 1).detail
                == "The capture and its annotation will be deleted from the draft. You can't undo this."
        )
        let several = CaptureRemovalPrompt(filenames: ["capture-1.png", "capture-3.png", "capture-4.png"], annotations: 5)
        #expect(several.message == "Remove 3 captures from this review?")
        #expect(several.detail == "The captures and their 5 annotations will be deleted from the draft. You can't undo this.")
        #expect(several.button == "Remove 3 Captures")
        #expect(
            CaptureRemovalPrompt(filenames: ["a.png", "b.png"], annotations: 1).detail
                == "The captures and their annotation will be deleted from the draft. You can't undo this."
        )
    }
}

extension CaptureRemovalPrompt {
    init(message: String, detail: String, button: String) {
        self.init(filenames: ["x"], annotations: 0)
        self.message = message
        self.detail = detail
        self.button = button
    }
}
