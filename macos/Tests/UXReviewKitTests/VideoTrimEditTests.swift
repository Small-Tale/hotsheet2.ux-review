import Foundation
import Testing
@testable import UXReviewKit

/// docs/06 §6.10: trims shift ranges exactly and hide, never remove, the ones outside (HS2-71SSJG).
extension VideoTimeTests {
    /// HS2-71SSJG: a trim shifts every range exactly and hides, never removes, the ones outside;
    /// only what would be submitted is clamped and leaves them out.
    @Test func trimShiftsRangesExactlyHidesOutsidersAndSetsTheDuration() throws {
        var editor = Self.clipEditor(annotations: [
            Self.box("a1", nil),
            Self.box("a2", Self.range(500, 1500)), // straddles the start: -500…500 (submitted 0…500)
            Self.box("a3", Self.range(1200, 2200)), // inside: shifted to 200…1200
            Self.box("a4", Self.range(2800, 3500)), // straddles the end: 1800…2500 (submitted …2000)
            Self.box("a5", Self.range(100, 900)), // entirely before: hidden
            Self.box("a6", Self.range(3001, 3001)), // instant after the end: hidden
            Self.box("a7", Self.range(3000, 3000)), // instant at the end: shows at 2000
        ])
        editor.select("a5")
        editor.setCurrentTime(1500)
        let done8 = editor.trim(to: Self.range(1000, 3000))
        #expect(done8)
        #expect(editor.currentMedia?.durationMs == 2000)
        #expect(editor.document.trims["v1"] == Self.range(1000, 3000))
        let ranges = Dictionary(uniqueKeysWithValues: editor.bundle.annotations.map { ($0.id, $0.timeRange) })
        #expect(ranges.keys.sorted() == ["a1", "a2", "a3", "a4", "a5", "a6", "a7"])
        #expect(ranges["a1"] == .some(nil))
        #expect(ranges["a2"] == Self.range(-500, 500))
        #expect(ranges["a3"] == Self.range(200, 1200))
        #expect(ranges["a4"] == Self.range(1800, 2500))
        #expect(ranges["a5"] == Self.range(-900, -100))
        #expect(ranges["a6"] == Self.range(2001, 2001))
        #expect(ranges["a7"] == Self.range(2000, 2000))
        #expect(editor.bundle.annotations.filter(editor.isOutsideEdit).map(\.id) == ["a5", "a6"])
        #expect(editor.selection == nil, "the selection outside the trim is cleared")
        #expect(editor.currentTimeMs == 500, "the playhead stays on the same frame")
        #expect(
            editor.message == "Trimmed to 2.0 s. 2 annotations outside the trim are hidden."
        )
        let submitted = editor.submissionBundle
        let clamped = Dictionary(uniqueKeysWithValues: submitted.annotations.map { ($0.id, $0.timeRange) })
        #expect(clamped.keys.sorted() == ["a1", "a2", "a3", "a4", "a7"])
        #expect(clamped["a2"] == Self.range(0, 500) && clamped["a4"] == Self.range(1800, 2000))
        #expect(submitted.validate().isEmpty)

        editor.undo()
        #expect(editor.bundle.annotations.count == 7 && editor.currentMedia?.durationMs == 4000)
        #expect(editor.document.trims.isEmpty && editor.currentTimeMs == 1500)
        #expect(editor.annotation("a5")?.timeRange == Self.range(100, 900))
        editor.redo()
        #expect(editor.bundle.annotations.count == 7 && editor.currentTimeMs == 500)
    }
}
