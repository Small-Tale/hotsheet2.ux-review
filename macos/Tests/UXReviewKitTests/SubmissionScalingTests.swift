import CoreGraphics
import CoreMedia
import Foundation
import Testing
@testable import UXReviewKit

extension EncodingTests {
    /// HS2-PT8PM6 end to end through real files: `SubmissionStaging` scales filed images (after a
    /// crop) and movies (in one export with a trim) for AI, keeps the draft's files full size,
    /// files a capture that needs nothing as-is, and `DraftSubmitter` attaches the scaled files
    /// with a `review.json` whose sizes match them (annotation coordinates are normalized, so
    /// they stay as they are). Spec: docs/07 §7.5.1.
    @Suite(.timeLimit(.minutes(2)))
    struct SubmissionScalingTests {
        final class Fixture {
            let base: URL
            let store: ReviewDraftStore
            var draft: ReviewDraft

            /// A draft with one image of `width` × `height` (a test card) and a rect annotation on it.
            init(width: Int = 3000, height: Int = 2000) throws {
                base = try TestSupport.makeTempDirectory()
                store = ReviewDraftStore(root: base.appendingPathComponent("Drafts"))
                let file = base.appendingPathComponent("big.png")
                try ImageFiles.writePNG(#require(ImageFiles.testCard(width: width, height: height)), to: file)
                draft = try store.add(DraftCapture(
                    fileURL: file, kind: .image, pixelWidth: width, pixelHeight: height,
                    capturedAt: Date(timeIntervalSince1970: 0), context: CaptureContext()
                )).draft
                draft = try store.update(draft.directory) { bundle in
                    bundle.annotations = [Annotation(
                        id: "a1", mediaId: "m1", shape: .rect(NormRect(x: 6000, y: 2500, width: 3000, height: 5000)), note: "here"
                    )]
                }
            }

            deinit { try? FileManager.default.removeItem(at: base) }

            /// Adds a 160 × 90, 2 s movie (10 fps) as the next capture.
            func addMovie() async throws {
                let movie = base.appendingPathComponent("source.mov")
                let duration = try await VideoTrimSessionTests.Fixture.writeMovie(to: movie)
                draft = try store.add(DraftCapture(
                    fileURL: movie, kind: .video, pixelWidth: 160, pixelHeight: 90, durationMs: duration,
                    capturedAt: Date(timeIntervalSince1970: 0), context: CaptureContext()
                ), to: draft.directory).draft
            }

            func prepare(_ scale: MediaScaleTarget?) throws -> SubmissionStaging {
                try SubmissionStaging.prepare(store.load(draft.directory), scale: scale)
            }

            var imageURL: URL { draft.directory.appendingPathComponent("capture-1.png") }
        }

        @Test func scalesALargeImageAndKeepsTheDraftFullSize() throws {
            let fixture = try Fixture()
            let before = try Data(contentsOf: fixture.imageURL)
            let staged = try fixture.prepare(.codex)
            defer { staged.cleanUp() }
            #expect(staged.mediaDirectory.lastPathComponent == SubmissionStaging.folderName)
            let filed = staged.mediaDirectory.appendingPathComponent("capture-1.png")
            let size = try ImageFiles.pixelSize(of: filed)
            #expect(size.width == 2048 && size.height == 1365)
            #expect(staged.bundle.media[0].pixelWidth == 2048 && staged.bundle.media[0].pixelHeight == 1365)
            #expect(staged.scaledFrom == ["m1": PixelSize(width: 3000, height: 2000)])
            #expect(staged.bundle.annotations == fixture.draft.bundle.annotations, "normalized coordinates match the scaled file")
            #expect(staged.bundle.validate().isEmpty)
            // The draft is untouched.
            #expect(try Data(contentsOf: fixture.imageURL) == before)
            #expect(try fixture.store.load(fixture.draft.directory).bundle.media[0].pixelWidth == 3000)
        }

        @Test func scalesAfterTheCrop() throws {
            let fixture = try Fixture()
            try DraftEdits(crops: ["capture-1.png": PixelRect(x: 200, y: 400, width: 2800, height: 1400)]).save(to: fixture.draft.directory)
            let staged = try fixture.prepare(.claudeStandard)
            defer { staged.cleanUp() }
            let expected = MediaScaleTarget.claudeStandard.imageSize(for: PixelSize(width: 2800, height: 1400))
            let size = try ImageFiles.pixelSize(of: staged.mediaDirectory.appendingPathComponent("capture-1.png"))
            #expect(size.width == expected.width && size.height == expected.height)
            #expect(MediaScaleTarget.claudeTokens(expected) <= 1568)
            #expect(staged.scaledFrom["m1"] == PixelSize(width: 2800, height: 1400))
            #expect(staged.bundle.media[0].pixelWidth == expected.width)
            // The annotation is projected into the crop exactly as without scaling.
            let unscaled = try fixture.prepare(nil)
            defer { unscaled.cleanUp() }
            #expect(staged.bundle.annotations == unscaled.bundle.annotations)
            #expect(unscaled.bundle.media[0].pixelWidth == 2800 && unscaled.scaledFrom.isEmpty)
        }

        @Test func aCaptureThatFitsIsFiledAsIs() throws {
            let fixture = try Fixture(width: 800, height: 600)
            let staged = try fixture.prepare(.claudeStandard)
            #expect(staged.mediaDirectory == fixture.draft.directory, "nothing to scale: the draft itself is filed")
            #expect(staged.scaledFrom.isEmpty && staged.bundle == fixture.draft.bundle)
            let off = try Fixture()
            let full = try off.prepare(nil)
            #expect(full.mediaDirectory == off.draft.directory && full.bundle.media[0].pixelWidth == 3000)
        }

        @Test func scalesAMovieInTheTrimExportWithEvenSides() async throws {
            let fixture = try Fixture(width: 64, height: 48)
            try await fixture.addMovie()
            let duration = try #require(fixture.draft.bundle.media[1].durationMs)
            try DraftEdits(trims: ["capture-2.mov": TimeRange(startMs: 1000, endMs: duration)]).save(to: fixture.draft.directory)
            let tiny = MediaScaleTarget(rule: .longestEdge(100), audience: "AI")
            let staged = try fixture.prepare(tiny)
            defer { staged.cleanUp() }
            let movie = staged.mediaDirectory.appendingPathComponent("capture-2.mov")
            let filed = try await VideoFileWriter.inspect(movie)
            #expect(filed.width == 100 && filed.height == 56, "90 × 100/160 = 56.25 → 56, even")
            #expect(abs(filed.durationMs - (duration - 1000)) <= 110, "trimmed within a frame")
            #expect(staged.bundle.media[1].pixelWidth == 100 && staged.bundle.media[1].pixelHeight == 56)
            #expect(staged.scaledFrom == ["m2": PixelSize(width: 160, height: 90)], "the 64 × 48 image fits")
            #expect(try VideoTrimSessionTests.color(VideoFrames(url: movie).frame(atMs: 100)) == "blue", "the trimmed part")
            // Scale alone (no trim) is one export too, the whole length.
            try DraftEdits().save(to: fixture.draft.directory)
            let untrimmed = try fixture.prepare(tiny)
            defer { untrimmed.cleanUp() }
            let whole = try await VideoFileWriter.inspect(untrimmed.mediaDirectory.appendingPathComponent("capture-2.mov"))
            #expect(whole.width == 100 && whole.height == 56 && abs(whole.durationMs - duration) <= 110)
        }

        @Test func theSubmitterAttachesScaledFilesWithMatchingSizes() throws {
            let fixture = try Fixture()
            let client = FakeHotSheetClient()
            var attachedSize: (width: Int, height: Int)?
            var attachedBundle: ReviewBundle?
            client.inspectAttached = { files in
                attachedSize = try files.first { $0.pathExtension == "png" }.map(ImageFiles.pixelSize(of:))
                attachedBundle = try files.first { $0.lastPathComponent == "review.json" }
                    .map { try ReviewBundle.makeDecoder().decode(ReviewBundle.self, from: Data(contentsOf: $0)) }
            }
            let submitter = DraftSubmitter(
                store: fixture.store, client: client, storePath: URL(fileURLWithPath: "/stores/a.hs2"), scale: .claudeHighResolution
            )
            let result = try submitter.submit(fixture.draft.directory, title: "Big")
            let expected = MediaScaleTarget.claudeHighResolution.imageSize(for: PixelSize(width: 3000, height: 2000))
            #expect(attachedSize?.width == expected.width && attachedSize?.height == expected.height)
            #expect(attachedBundle?.media.first?.pixelWidth == expected.width)
            #expect(attachedBundle?.media.first?.pixelHeight == expected.height)
            #expect(attachedBundle?.annotations.first?.shape == .rect(NormRect(x: 6000, y: 2500, width: 3000, height: 5000)))
            #expect(result.scaledCaptures == ["capture-1.png"] && result.scaledFor == "Claude")
        }

        @Test func withoutAScaleTheSubmitterFilesFullSize() throws {
            let fixture = try Fixture()
            let client = FakeHotSheetClient()
            var attachedSize: (width: Int, height: Int)?
            client.inspectAttached = { files in
                attachedSize = try files.first { $0.pathExtension == "png" }.map(ImageFiles.pixelSize(of:))
            }
            let result = try DraftSubmitter(store: fixture.store, client: client, storePath: URL(fileURLWithPath: "/stores/a.hs2"))
                .submit(fixture.draft.directory, title: "Big")
            #expect(attachedSize?.width == 3000 && attachedSize?.height == 2000)
            #expect(result.scaledCaptures == nil && result.scaledFor == nil)
        }
    }
}
