import Foundation
import Testing
@testable import UXReviewKit

struct TicketComposerTests {
    @Test func composesIntakeTicketForExample() throws {
        let composed = try TicketComposer.compose(TestSupport.exampleBundle())
        #expect(composed.ticket.title == "Settings window polish")
        #expect(composed.ticket.category == "task")
        #expect(composed.ticket.tags == ["ux-review"])
        #expect(composed.bundleFilename == "review.json")
        #expect(composed.mediaFilenames == ["capture-1.png", "capture-2.mov"])

        let details = composed.ticket.details
        #expect(details.hasPrefix("## Instructions for the AI processing this ticket"))
        #expect(details.contains("Create one ticket per distinct actionable change"))
        #expect(details.contains("`attachment:review.json`"))
        #expect(details.contains("(`attachment:capture-1.png`, `attachment:capture-2.mov`)"))
        #expect(details.contains("## Reviewer summary\n\nSettings window pass before the beta."))
        #expect(details.contains("- App: Hot Sheet (`com.smalltale.hotsheet2`)"))
        #expect(details.contains("- Window: Hot Sheet — ux-review"))
        #expect(details.contains("- `attachment:capture-1.png` (image, 2880×1800)\n"))
        #expect(
            details
                .contains("- `attachment:capture-2.mov` (video, 2880×1800, 0:08.000, with audio), from Hot Sheet “Hot Sheet — Settings”")
        )
        #expect(details.contains("\n\n" + TicketComposer.audioHint + "\n\n## Annotations"))
        #expect(details.contains("### #1 · change · `attachment:capture-1.png`"))
        #expect(details.contains("### #2 · move · `attachment:capture-1.png`"))
        #expect(details.contains("### #3 · remove · `attachment:capture-1.png`"))
        #expect(details.contains("### #4 · insert · `attachment:capture-1.png`"))
        #expect(details.contains("### #5 · bug · `attachment:capture-2.mov`"))
        #expect(details.contains("- Shape: arrow; region (0–10000): x 1200, y 600, w 3300, h 2400"))
        #expect(details.contains("- Time: 0:02.500–0:04.250"))
    }

    @Test func projectsEveryAnnotationOntoHotSheetRectanglesPerMedia() throws {
        let composed = try TicketComposer.compose(TestSupport.exampleBundle())
        #expect(composed.hotSheetAnnotations["m1"]?.map(\.id) == ["a1", "a2", "a3", "a4", "a6"])
        let clip = try #require(composed.hotSheetAnnotations["m2"]?.first)
        #expect(clip == HotSheetMediaAnnotation(
            id: "a5", x: 400, y: 900, width: 2800, height: 6300, startMs: 2500, endMs: 4250,
            text: "#5 [bug] The list flickers while the sidebar animates."
        ))
    }

    @Test func hotSheetAnnotationUsesSnakeCaseWireFormat() throws {
        let annotation = HotSheetMediaAnnotation(id: "a", x: 1, y: 2, width: 3, height: 4, startMs: 5, endMs: 6, text: "t")
        let object = try JSONSerialization.jsonObject(with: JSONEncoder().encode(annotation)) as? [String: Any]
        #expect(Set(object?.keys ?? [:].keys) == ["id", "x", "y", "width", "height", "start_ms", "end_ms", "text"])
    }

    @Test func minimalBundleOmitsOptionalSections() {
        let details = TicketComposer.compose(TestSupport.bundle()).ticket.details
        #expect(!details.contains("## Reviewer summary"))
        #expect(!details.contains("## Capture context"))
        #expect(details.contains("No annotations; see the reviewer summary and media."))
    }

    @Test(arguments: [
        (CaptureContext(appName: "Safari", windowTitle: "Settings"), "Safari “Settings”"),
        (CaptureContext(appName: "Safari"), "Safari"),
        (CaptureContext(windowTitle: "Settings"), "“Settings”"),
        (CaptureContext(osVersion: "macOS 27.0"), nil),
    ] as [(CaptureContext, String?)])
    func mediaSourceLabel(context: CaptureContext, expected: String?) {
        #expect(TicketComposer.sourceLabel(context) == expected)
        #expect(TicketComposer.sourceLabel(nil) == nil)
    }

    /// Without any audio track the media lines carry no "with audio" and the hint is left out.
    @Test func audioIsOnlyMentionedForVideosThatHaveIt() throws {
        var bundle = try TestSupport.exampleBundle()
        bundle.media[1].hasAudio = nil
        let details = TicketComposer.compose(bundle).ticket.details
        #expect(details.contains("(video, 2880×1800, 0:08.000), from"))
        #expect(!details.contains("with audio"))
        #expect(!details.contains(TicketComposer.audioHint))
    }

    @Test func emptyNotesAreMarked() {
        let bundle = TestSupport.bundle(annotations: [
            Annotation(id: "a", mediaId: "m1", shape: .insertion(NormPoint(x: 1, y: 1)), note: ""),
        ])
        #expect(TicketComposer.compose(bundle).ticket.details.contains("_No note._"))
    }

    @Test(arguments: [(0, "0:00.000"), (1, "0:00.001"), (61500, "1:01.500"), (3_600_000, "60:00.000")])
    func formatsTimes(milliseconds: Int, expected: String) {
        #expect(TicketComposer.formatTime(milliseconds) == expected)
    }
}

/// HS2-KMB528: a capture downscaled for AI carries its size before scaling in review.json and
/// in the ticket's media line, so a reader knows detail was lost.
struct ScaledFromTests {
    @Test func scaledFromRoundTripsAndIsOmittedWhenUnscaled() throws {
        var item = TestSupport.image()
        let plain = try #require(String(bytes: ReviewBundle.makeEncoder().encode(item), encoding: .utf8))
        #expect(!plain.contains("scaledFrom"))
        item.scaledFrom = MediaPixelSize(pixelWidth: 3840, pixelHeight: 2160)
        let data = try ReviewBundle.makeEncoder().encode(item)
        let object = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        let written = object?["scaledFrom"] as? [String: Int]
        #expect(written == ["pixelWidth": 3840, "pixelHeight": 2160])
        #expect(try ReviewBundle.makeDecoder().decode(MediaItem.self, from: data) == item)
    }

    @Test func theMediaLineAndHintNameTheSizeBeforeScaling() {
        var image = TestSupport.image("m1", filename: "capture-1.png")
        image.pixelWidth = 2576
        image.pixelHeight = 1449
        image.scaledFrom = MediaPixelSize(pixelWidth: 3840, pixelHeight: 2160)
        var video = TestSupport.video("m2", filename: "capture-2.mov", durationMs: 2000)
        video.scaledFrom = MediaPixelSize(pixelWidth: 2880, pixelHeight: 1800)
        let scaled = TicketComposer.mediaSection(TestSupport.bundle(media: [image, video]))
        #expect(scaled.contains("- `attachment:capture-1.png` (image, 2576×1449, scaled from 3840×2160)\n"))
        #expect(scaled.contains(", scaled from 2880×1800, 0:02.000)"))
        #expect(scaled.hasSuffix("\n\n" + TicketComposer.scaledHint))

        let plain = TicketComposer.mediaSection(TestSupport.bundle())
        #expect(!plain.contains("scaled from") && !plain.contains(TicketComposer.scaledHint))
    }

    @Test func aNonPositiveScaledFromSizeIsInvalid() {
        var item = TestSupport.image()
        item.scaledFrom = MediaPixelSize(pixelWidth: 0, pixelHeight: 10)
        #expect(TestSupport.bundle(media: [item]).validate() == [.invalidMediaSize(mediaId: item.id)])
        item.scaledFrom = MediaPixelSize(pixelWidth: 10, pixelHeight: 10)
        #expect(TestSupport.bundle(media: [item]).validate().isEmpty)
    }
}
