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

    @Test func reportsStepsInOrderAndResumesAnExistingTicketWithoutCreating() throws {
        let dir = try TestSupport.makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        try Data("png".utf8).write(to: dir.appendingPathComponent("shot.png"))
        let client = FakeHotSheetClient()
        var steps: [SubmitStep] = []
        let fresh = try ReviewSubmitter(client: client).file(TestSupport.bundle(), mediaDirectory: dir) { steps.append($0) }
        #expect(fresh == CreatedTicket(slug: "HS-TEST01"))
        #expect(steps == [.creatingTicket, .attachingMedia])

        steps = []
        let existing = CreatedTicket(slug: "HS-OLD001", file: "/store/tickets/x.md")
        let resumed = try ReviewSubmitter(client: client).file(
            TestSupport.bundle(), mediaDirectory: dir, existingTicket: existing
        ) { steps.append($0) }
        #expect(resumed == existing)
        #expect(steps == [.attachingMedia])
        #expect(client.created.count == 1)
        #expect(client.attached.map(\.slug) == ["HS-TEST01", "HS-OLD001"])
    }

    @Test func attachFailureAfterCreateCarriesTheCreatedTicket() throws {
        let dir = try TestSupport.makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        try Data("png".utf8).write(to: dir.appendingPathComponent("shot.png"))
        let client = FakeHotSheetClient()
        client.attachErrors = [HotSheetError.commandFailed(command: "attach", exitCode: 1, stderr: "disk full\n")]
        #expect(throws: ReviewSubmissionError.attachFailed(
            ticket: CreatedTicket(slug: "HS-TEST01"),
            reason: "hotsheet-cli attach failed (exit 1): disk full"
        )) {
            try ReviewSubmitter(client: client).submit(TestSupport.bundle(), mediaDirectory: dir)
        }
    }

    @Test func describesErrorsInOneLine() {
        #expect(ReviewSubmitter.describe(HotSheetError.cliNotFound) == "hotsheet-cli was not found.")
        #expect(
            ReviewSubmitter.describe(HotSheetError.commandFailed(command: "new", exitCode: 2, stderr: "")) ==
                "hotsheet-cli new failed (exit 2)."
        )
        #expect(
            ReviewSubmitter.describe(HotSheetError.unexpectedOutput(command: "new", stdout: "?")) ==
                "hotsheet-cli new printed something unexpected."
        )
        #expect(ReviewSubmitter.describe(HotSheetError.storeNotFound(URL(fileURLWithPath: "/p"))) == "No Hot Sheet store was found for /p.")
        #expect(ReviewSubmitter.describe(ReviewSubmissionError.missingMedia("a.png")) == "a.png is missing from the review.")
        #expect(ReviewSubmitter.describe(ReviewSubmissionError.invalidBundle([])) == "The review has problems to fix first.")
        #expect(ReviewSubmitter.describe(ReviewDraftError.unknownMedia("m9")) == "The review has no capture m9.")
    }
}
