import CoreGraphics
import Foundation
import Testing
@testable import UXReviewKit

/// The media strip's Show in Finder and Copy Path (`HS2-20VQ8Q`, docs/06 §6.7.3), through a real
/// draft: which captures they act on as the selection changes, and the files and text they use.
struct CaptureFileActionsTests {
    @Test func titlesCountTheCaptures() {
        #expect(CaptureFileActions.revealTitle == "Show in Finder")
        #expect(CaptureFileActions.copyTitle(count: 1) == "Copy Path")
        #expect(CaptureFileActions.copyTitle(count: 3) == "Copy 3 Paths")
    }

    @Test func severalPathsCopyOnePerLine() {
        let files = [URL(fileURLWithPath: "/a/capture-1.png"), URL(fileURLWithPath: "/a/b c/capture 2.mov")]
        #expect(CaptureFileActions.pasteboardText(files) == "/a/capture-1.png\n/a/b c/capture 2.mov")
        #expect(CaptureFileActions.pasteboardText([files[0]]) == "/a/capture-1.png")
        #expect(CaptureFileActions.pasteboardText([]) == "")
    }

    /// The files are the draft's own, they exist, and an unknown id is skipped.
    @Test func fileURLsAreTheDraftsCaptureFiles() throws {
        let fixture = try EditorSessionTests.Fixture()
        try fixture.store.add(fixture.capture())
        let session = try fixture.session()
        let files = session.fileURLs(["m2", "nope", "m1"])
        #expect(files.map(\.lastPathComponent) == ["capture-2.png", "capture-1.png"])
        #expect(files.allSatisfy { $0.deletingLastPathComponent().standardizedFileURL == fixture.draft.directory.standardizedFileURL })
        #expect(files.allSatisfy { FileManager.default.fileExists(atPath: $0.path) })
        #expect(session.fileURLs([]).isEmpty)
    }

    /// A crop leaves the file as captured, so the path still names the whole original.
    @Test func aCroppedCaptureStillPointsAtItsFile() throws {
        let fixture = try EditorSessionTests.Fixture()
        let session = try fixture.session()
        let cropped = session.editor.crop(to: CGRect(x: 10, y: 10, width: 100, height: 50))
        #expect(cropped)
        try session.save()
        let file = try #require(session.fileURLs(["m1"]).first)
        #expect(file.lastPathComponent == "capture-1.png")
        #expect(try fixture.fileSize("capture-1.png") == (400, 200))
    }

    /// The targets follow the selection like removal: a selected thumbnail acts on the whole
    /// selection, any other just on itself; deselecting, removing, and refilling are followed.
    @Test func targetsFollowTheSelection() throws {
        let fixture = try EditorSessionTests.Fixture()
        for _ in 0 ..< 3 {
            try fixture.store.add(fixture.capture())
        }
        let session = try fixture.session()
        func names(_ id: String) -> [String] {
            session.fileURLs(session.editor.mediaToRemove(from: id)).map(\.lastPathComponent)
        }
        #expect(names("m1") == ["capture-1.png"])
        #expect(names("m3") == ["capture-3.png"]) // not selected: just itself

        session.editor.clickMedia("m3", .toggle) // m1 + m3
        #expect(names("m1") == ["capture-1.png", "capture-3.png"])
        #expect(names("m3") == ["capture-1.png", "capture-3.png"])
        #expect(names("m2") == ["capture-2.png"])

        session.editor.clickMedia("m4", .extend) // the range from the anchor m3 to m4
        #expect(names("m4") == ["capture-3.png", "capture-4.png"])
        #expect(names("m1") == ["capture-1.png"])

        try session.removeCapture("m3") // removed from under the selection
        #expect(names("m4") == ["capture-4.png"])
        #expect(names("m3").isEmpty)

        try fixture.store.add(fixture.capture()) // refilled: a new capture is never preselected
        _ = try session.reload()
        let added = try #require(session.editor.bundle.media.last)
        #expect(names(added.id) == [added.filename])

        session.editor.clickMedia("m1", .plain) // back to one
        #expect(names("m1") == ["capture-1.png"])
        #expect(names("m4") == ["capture-4.png"])
    }
}
