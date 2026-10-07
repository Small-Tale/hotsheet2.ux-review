import Foundation
import Testing
@testable import UXReviewKit

struct ReviewSubmitterTests {
    @Test func writesBundleCreatesTicketAndAttachesEverythingInOneBatch() throws {
        let dir = try TestSupport.makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        try Data("png".utf8).write(to: dir.appendingPathComponent("shot.png"))

        let client = FakeHotSheetClient()
        let bundle = TestSupport.bundle()
        let slug = try ReviewSubmitter(client: client).submit(bundle, mediaDirectory: dir)

        #expect(slug == "HS-TEST01")
        #expect(client.created == [TicketComposer.compose(bundle).ticket])
        #expect(client.attached.count == 1)
        let batch = try #require(client.attached.first)
        #expect(batch.files.map(\.lastPathComponent) == ["shot.png", "review.json"])
        #expect(batch.slug == "HS-TEST01")
        #expect(batch.label == "UX review capture")
        #expect(batch.purpose == "problem_evidence")

        let written = try ReviewBundle.makeDecoder().decode(
            ReviewBundle.self, from: Data(contentsOf: dir.appendingPathComponent("review.json"))
        )
        #expect(written == bundle)
    }

    @Test func invalidBundleIsRejectedBeforeAnyWrite() throws {
        let client = FakeHotSheetClient()
        let dir = try TestSupport.makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        #expect(throws: ReviewSubmissionError.invalidBundle([.noMedia])) {
            try ReviewSubmitter(client: client).submit(TestSupport.bundle(media: []), mediaDirectory: dir)
        }
        #expect(client.created.isEmpty)
        #expect(!FileManager.default.fileExists(atPath: dir.appendingPathComponent("review.json").path))
    }

    @Test func missingMediaFileIsRejectedBeforeTicketCreation() throws {
        let client = FakeHotSheetClient()
        let dir = try TestSupport.makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        #expect(throws: ReviewSubmissionError.missingMedia("shot.png")) {
            try ReviewSubmitter(client: client).submit(TestSupport.bundle(), mediaDirectory: dir)
        }
        #expect(client.created.isEmpty)
    }

    @Test func createFailureMeansNoAttachAttempt() throws {
        let dir = try TestSupport.makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        try Data("png".utf8).write(to: dir.appendingPathComponent("shot.png"))
        let client = FakeHotSheetClient()
        client.createError = HotSheetError.cliNotFound
        #expect(throws: HotSheetError.cliNotFound) {
            try ReviewSubmitter(client: client).submit(TestSupport.bundle(), mediaDirectory: dir)
        }
        #expect(client.attached.isEmpty)
    }
}
