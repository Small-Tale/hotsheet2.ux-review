import Foundation
import Testing
@testable import UXReviewKit

/// HS2-CWTNY2: `uxreview://capture?…` links. Spec: docs/04-capture.md §4.13.
struct CaptureLinkTests {
    private func link(_ text: String) throws -> CaptureLink {
        try CaptureLink.parse(#require(URL(string: text)))
    }

    private func error(_ text: String) -> CaptureLinkError? {
        do {
            _ = try link(text)
            return nil
        } catch let error as CaptureLinkError {
            return error
        } catch {
            return nil
        }
    }

    // MARK: Parsing

    @Test func aBareLinkCapturesARegionScreenshotIntoTheCurrentReview() throws {
        let bare = try link("uxreview://capture")
        #expect(bare == CaptureLink(request: CaptureRequest(kind: .screenshot, target: .region, delaySeconds: 0), review: .current))
        #expect(bare.launch == DraftLaunch())
        // The other spelling of the action, any case, and a trailing slash.
        #expect(try link("uxreview:capture") == bare)
        #expect(try link("UXReview://Capture/") == bare)
    }

    @Test func everyParameterAndItsSynonyms() throws {
        let full = try link(
            "uxreview://capture?kind=Video&target=screen&delay=5&narrate=on&project=/Users/me/kerf/&ticket=hs-1a2b3c"
                + "&title=%20Kerf%20demo%20&context=Step%203%0Aof%20the%20tour&review=current"
        )
        #expect(full.request == CaptureRequest(kind: .video, target: .display, delaySeconds: 5))
        #expect(full.narrate == true)
        #expect(full.project?.path == "/Users/me/kerf")
        #expect(full.ticket == "HS-1A2B3C")
        #expect(full.title == "Kerf demo")
        #expect(full.context == "Step 3\nof the tour")
        #expect(full.review == .current)
        #expect(full.launch == DraftLaunch(projectDirectory: "/Users/me/kerf", ticket: "HS-1A2B3C"))

        #expect(try link("uxreview://capture?kind=image").request.kind == .screenshot)
        #expect(try link("uxreview://capture?kind=recording").request.kind == .video)
        #expect(try link("uxreview://capture?target=display").request.target == .display)
        #expect(try link("uxreview://capture?target=window").request.target == .window)
        #expect(try link("uxreview://capture?kind=video&narrate=0").narrate == false)
        #expect(try link("uxreview://capture?delay=60").request.delaySeconds == 60)
        #expect(try link("uxreview://capture?project=file:///Users/me/kerf").project?.path == "/Users/me/kerf")
        // A ticket link or `ls` line holding a slug.
        #expect(try link("uxreview://capture?ticket=HS-ABCD12%3A%20Fix%20the%20form").ticket == "HS-ABCD12")
    }

    @Test func presetsStartANewReviewUnlessTheLinkSaysOtherwise() throws {
        #expect(try link("uxreview://capture?kind=video").review == .current)
        for preset in ["project=/p", "ticket=HS-ABCD12", "title=T", "context=C"] {
            #expect(try link("uxreview://capture?\(preset)").review == .new, "\(preset)")
            #expect(try link("uxreview://capture?\(preset)&review=current").review == .current, "\(preset)")
        }
        #expect(try link("uxreview://capture?review=new").review == .new)
    }

    @Test func badLinksAreRejectedWithTheReason() {
        #expect(error("https://example.com/capture") == .notALink)
        #expect(error("uxreview://record") == .unknownAction("record"))
        #expect(error("uxreview://") == .unknownAction(""))
        #expect(error("uxreview://capture?kidn=video") == .unknownParameter("kidn"))
        #expect(error("uxreview://capture?kind=video&kind=screenshot") == .repeatedParameter("kind"))
        #expect(error("uxreview://capture?kind=gif") == .invalidValue("kind", "gif"))
        #expect(error("uxreview://capture?target=tab") == .invalidValue("target", "tab"))
        #expect(error("uxreview://capture?delay=61") == .invalidValue("delay", "61"))
        #expect(error("uxreview://capture?delay=-1") == .invalidValue("delay", "-1"))
        #expect(error("uxreview://capture?delay=2.5") == .invalidValue("delay", "2.5"))
        #expect(error("uxreview://capture?kind=video&narrate=maybe") == .invalidValue("narrate", "maybe"))
        #expect(error("uxreview://capture?narrate=on") == .narrationNeedsVideo)
        #expect(error("uxreview://capture?project=kerf") == .invalidValue("project", "kerf"))
        #expect(error("uxreview://capture?project=https://example.com/kerf") == .invalidValue("project", "https://example.com/kerf"))
        #expect(error("uxreview://capture?ticket=the%20form") == .invalidValue("ticket", "the form"))
        #expect(error("uxreview://capture?title=%20%20") == .invalidValue("title", "  "))
        #expect(error("uxreview://capture?review=old") == .invalidValue("review", "old"))
        let long = String(repeating: "x", count: CaptureLink.maxContextLength + 1)
        #expect(error("uxreview://capture?context=\(long)") == .invalidValue("context", long))
        #expect(CaptureLinkError.unknownParameter("kidn").description.contains("kidn"))
    }

    @Test func onlyUXReviewSchemeURLsAreLinks() throws {
        #expect(try CaptureLink.isLink(#require(URL(string: "UXREVIEW://capture"))))
        #expect(try !CaptureLink.isLink(#require(URL(string: "file:///tmp/shot.png"))))
    }

    // MARK: Preparing the review

    private func store() throws -> ReviewDraftStore {
        try ReviewDraftStore(root: TestSupport.makeTempDirectory().appendingPathComponent("Drafts"))
    }

    private func capture(into store: ReviewDraftStore) throws {
        let file = store.root.deletingLastPathComponent().appendingPathComponent("shot-\(UUID().uuidString).png")
        try Data("png".utf8).write(to: file)
        try store.add(DraftCapture(
            fileURL: file, kind: .image, pixelWidth: 10, pixelHeight: 10, capturedAt: Date(), context: CaptureContext(appName: "Safari")
        ))
    }

    @Test func aPresetLinkStartsANewReviewWithItsTitleNotesAndDestination() throws {
        let store = try store()
        try capture(into: store)
        let earlier = try #require(try store.current())
        let prepared = try #require(try link(
            "uxreview://capture?project=/Users/me/kerf&ticket=HS-ABCD12&title=Kerf%20demo&context=Step%203"
        ).prepare(in: store))
        #expect(prepared.directory != earlier.directory)
        #expect(try store.current()?.directory == prepared.directory)
        #expect(prepared.bundle.title == "Kerf demo")
        #expect(prepared.bundle.summary == "Step 3")
        #expect(prepared.bundle.media.isEmpty)
        #expect(DraftLaunch.load(from: prepared.directory) == DraftLaunch(projectDirectory: "/Users/me/kerf", ticket: "HS-ABCD12"))
        // The review in progress is untouched, and the next capture goes into the new one.
        #expect(try store.load(earlier.directory).bundle.media.count == 1)
        #expect(DraftLaunch.load(from: earlier.directory) == DraftLaunch())
        try capture(into: store)
        #expect(try store.load(prepared.directory).bundle.media.count == 1)
        #expect(try store.load(prepared.directory).bundle.title == "Kerf demo")
    }

    @Test func aBareLinkLeavesTheCurrentReviewAlone() throws {
        let store = try store()
        #expect(try link("uxreview://capture").prepare(in: store) == nil)
        #expect(try store.current() == nil)
        try capture(into: store)
        let current = try #require(try store.current())
        #expect(try link("uxreview://capture?kind=video").prepare(in: store)?.directory == current.directory)
        #expect(try store.load(current.directory).bundle == current.bundle)
        #expect(!FileManager.default.fileExists(atPath: current.directory.appendingPathComponent(DraftLaunch.filename).path))
    }

    @Test func linksIntoTheCurrentReviewAddToItInTurn() throws {
        let store = try store()
        // No review yet: a preset creates one.
        let first = try #require(try link("uxreview://capture?context=First&review=current").prepare(in: store))
        #expect(first.bundle.summary == "First")
        // Context adds to the notes; a later title, project, or ticket replaces the earlier one,
        // and what a later link doesn't set is kept.
        try link("uxreview://capture?context=Second&ticket=HS-ABCD12&review=current").prepare(in: store)
        try link("uxreview://capture?title=Renamed&project=/p&review=current").prepare(in: store)
        try link("uxreview://capture?ticket=HS-EFGH34&review=current").prepare(in: store)
        let after = try store.load(first.directory)
        #expect(after.bundle.summary == "First\n\nSecond")
        #expect(after.bundle.title == "Renamed")
        #expect(DraftLaunch.load(from: first.directory) == DraftLaunch(projectDirectory: "/p", ticket: "HS-EFGH34"))
        // Two `new` links in a row: two reviews, the second current.
        let one = try #require(try link("uxreview://capture?review=new").prepare(in: store))
        let two = try #require(try link("uxreview://capture?review=new").prepare(in: store))
        #expect(one.directory != two.directory)
        #expect(try store.current()?.directory == two.directory)
    }

    // MARK: launch.json

    @Test func launchFilesRoundTripAndEmptyOnesAreRemoved() throws {
        let directory = try TestSupport.makeTempDirectory()
        #expect(DraftLaunch.load(from: directory) == DraftLaunch())
        let launch = DraftLaunch(projectDirectory: "/p", ticket: "HS-ABCD12")
        try launch.save(to: directory)
        #expect(DraftLaunch.load(from: directory) == launch)
        try DraftLaunch().save(to: directory)
        #expect(!FileManager.default.fileExists(atPath: directory.appendingPathComponent(DraftLaunch.filename).path))
        try DraftLaunch().save(to: directory) // nothing to remove is fine
        // A corrupt file reads as none.
        try Data("{".utf8).write(to: directory.appendingPathComponent(DraftLaunch.filename))
        #expect(DraftLaunch.load(from: directory) == DraftLaunch())
    }

    @Test func theProjectComesFromTheCommandLineThenTheLinkThenTheSetting() throws {
        let directory = try TestSupport.makeTempDirectory()
        let selected = URL(fileURLWithPath: "/selected", isDirectory: true)
        let explicit = URL(fileURLWithPath: "/explicit", isDirectory: true)
        #expect(DraftLaunch.project(explicit: nil, draft: directory, selected: selected) == selected)
        #expect(DraftLaunch.project(explicit: nil, draft: directory, selected: nil) == nil)
        try DraftLaunch(projectDirectory: "/linked").save(to: directory)
        #expect(DraftLaunch.project(explicit: nil, draft: directory, selected: selected)?.path == "/linked")
        #expect(DraftLaunch.project(explicit: explicit, draft: directory, selected: selected) == explicit)
    }
}
