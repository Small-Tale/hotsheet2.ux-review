import AppKit
import SwiftUI
import UXReviewKit

/// Offscreen renders of the review session window for `--render-ui-previews`: ready, blocked
/// by issues, submitting, failed (ticket created, attach failed), submitted, empty, and with a
/// crop and a trim that leave annotations out (shown as filed, HS2-64P9DT). Each one
/// is the real `ReviewSessionView` on a throwaway draft of mock captures. Spec: docs/07 §7.2.
@MainActor
enum ReviewSessionPreviews {
    static let size = CGSize(width: 640, height: 720)
    static let ready = HotSheetStatus(
        cliPath: "/opt/homebrew/bin/hotsheet-cli",
        projectDirectory: "/Users/me/Code/acme-mail",
        storePath: "/Users/me/Code/acme-mail.hs2"
    )

    static func render(to directory: URL) throws -> [URL] {
        let scratch = FileManager.default.temporaryDirectory.appendingPathComponent("uxreview-session-previews-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: scratch) }
        try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
        let store = ReviewDraftStore(root: scratch.appendingPathComponent("Drafts"))
        let draft = try makeDraft(in: scratch, store: store)

        func model(_ draft: ReviewDraft, target: HotSheetStatus = ready) -> ReviewSessionModel {
            let model = ReviewSessionModel(draft: draft, store: store, target: target)
            model.statusProvider = { target }
            // Previews never run hotsheet-cli; they resolve lookups with previewLookup.
            model.ticketFinder = { _, _ in .success(nil) }
            return model
        }

        var written: [URL] = []
        func shoot(_ name: String, _ model: ReviewSessionModel, size: CGSize = size) throws {
            written.append(try snapshot(ReviewSessionView(model: model), size: size, to: directory.appendingPathComponent("\(name).png")))
        }

        try shoot("session-ready", model(draft))
        try shoot("session-narrow", model(draft), size: CGSize(width: 520, height: 560))
        try shoot("session-edited", edited(model(draft)))

        let submitting = model(draft)
        submitting.previewSubmitting(.attachingMedia)
        try shoot("session-submitting", submitting)

        let failed = model(draft)
        failed.previewSubmitting(.attachingMedia)
        failed.finish(.failure(SubmissionFailure(
            message: "HS-R58EY5 was created, but attaching the media failed: "
                + "hotsheet-cli attach failed (exit 1): the store is locked by another writer",
            createdTicket: "HS-R58EY5"
        )))
        try shoot("session-failed", failed)

        let submitted = model(draft)
        submitted.previewSubmitting(.attachingMedia)
        submitted.finish(.success(SubmittedReview(
            ticket: CreatedTicket(slug: "HS-R58EY5", file: "/Users/me/Code/acme-mail.hs2/tickets/X5/01M4.md"),
            title: draft.bundle.title, mediaCount: 3, annotationCount: 4,
            storePath: "/Users/me/Code/acme-mail.hs2", submittedAt: Date()
        )))
        try shoot("session-submitted", submitted)
        try renderExistingTicket(draft, model: { model($0) }, shoot: shoot)

        // Blocked: no title, a capture whose file is gone, an annotation outside its capture,
        // and no project chosen.
        let blockedDraft = try store.update(draft.directory) { bundle in
            bundle.title = ""
            bundle.annotations[1].shape = .rect(NormRect(x: 9000, y: 9000, width: 2000, height: 2000))
        }
        try FileManager.default.moveItem(
            at: blockedDraft.directory.appendingPathComponent("capture-2.png"),
            to: scratch.appendingPathComponent("moved.png")
        )
        let blocked = model(
            blockedDraft,
            target: HotSheetStatus(cliPath: "/opt/homebrew/bin/hotsheet-cli", problem: "No project selected.")
        )
        NSImage(contentsOf: scratch.appendingPathComponent("moved.png")).map { blocked.setThumbnail($0, for: "m2") }
        try shoot("session-issues", blocked)

        let emptyDraft = try store.update(draft.directory) { bundle in
            bundle.media = []
            bundle.annotations = []
            bundle.title = "UX review"
        }
        try shoot("session-empty", model(emptyDraft), size: CGSize(width: 640, height: 600))
        return written
    }

    static let existingTicket = HotSheetTicket(
        id: "01M4CCW6AW9EHFYT2QTZJ70H8D", slug: "HS-YCDZ2A", title: "Accounts settings page redesign", status: "started",
        file: "/Users/me/Code/acme-mail.hs2/tickets/8D/01M4CCW6AW9EHFYT2QTZJ70H8D.md"
    )

    /// Adding to an existing ticket (§7.2.1): looking it up, found, not found, a closed ticket,
    /// the note failing after the attach, and the result.
    /// As filed (HS2-64P9DT): capture-1 cropped to its lower right (a1 falls outside), the movie
    /// trimmed to its first second (a4, from 1.2 s, falls outside).
    private static func edited(_ model: ReviewSessionModel) -> ReviewSessionModel {
        model.previewEdits(DraftEdits(
            crops: ["capture-1.png": PixelRect(x: 640, y: 400, width: 960, height: 600)],
            trims: ["capture-3.mov": TimeRange(startMs: 0, endMs: 1000)]
        ))
        return model
    }

    private static func renderExistingTicket(
        _ draft: ReviewDraft,
        model: (ReviewDraft) -> ReviewSessionModel,
        shoot: (String, ReviewSessionModel, CGSize) throws -> Void
    ) throws {
        func existing(_ input: String, _ result: Result<HotSheetTicket?, SubmissionFailure>?) -> ReviewSessionModel {
            let session = model(draft)
            session.setDestination(.existingTicket)
            session.ticketInput = input
            if let result { session.previewLookup(result) }
            return session
        }
        // Tall enough to show the Ticket section under the captures and the project.
        let size = CGSize(width: 640, height: 940)
        try shoot("session-existing-looking", existing("hs-ycdz2a", nil), size)
        try shoot("session-existing-found", existing("HS-YCDZ2A", .success(existingTicket)), size)
        try shoot("session-existing-narrow", existing("HS-YCDZ2A", .success(existingTicket)), CGSize(width: 520, height: 880))
        try shoot("session-existing-not-found", existing("HS-NOPE00", .success(nil)), size)
        var deleted = existingTicket
        deleted.status = "deleted"
        try shoot("session-existing-closed", existing("HS-YCDZ2A", .success(deleted)), size)

        let failed = existing("HS-YCDZ2A", .success(existingTicket))
        failed.previewSubmitting(.addingNote)
        failed.finish(.failure(SubmissionFailure(
            message: "The media was attached to HS-YCDZ2A, but adding the review note failed: "
                + "hotsheet-cli edit failed (exit 1): the store is locked by another writer",
            attachedTo: "HS-YCDZ2A"
        )))
        try shoot("session-existing-failed", failed, size)

        let submitted = existing("HS-YCDZ2A", .success(existingTicket))
        submitted.previewSubmitting(.addingNote)
        submitted.finish(.success(SubmittedReview(
            ticket: existingTicket.createdTicket, title: draft.bundle.title, mediaCount: 3, annotationCount: 4,
            storePath: "/Users/me/Code/acme-mail.hs2", submittedAt: Date(),
            addedToExistingTicket: true, ticketTitle: existingTicket.title
        )))
        try shoot("session-existing-submitted", submitted, Self.size)
    }

    /// Two mock screenshots and a 2 s mock recording, titled, with an annotation or two on each.
    private static func makeDraft(in scratch: URL, store: ReviewDraftStore) throws -> ReviewDraft {
        let context = CaptureContext(appName: "Acme Mail", windowTitle: "Settings")
        for (index, size) in [(1600, 1000), (1200, 800)].enumerated() {
            let url = scratch.appendingPathComponent("mock-\(index).png")
            guard let image = MockScreenshot.settingsPage(width: size.0, height: size.1, variant: index) else { continue }
            try ImageFiles.writePNG(image, to: url)
            try store.add(DraftCapture(
                fileURL: url, kind: .image, pixelWidth: size.0, pixelHeight: size.1, capturedAt: Date(), context: context
            ))
        }
        let movie = scratch.appendingPathComponent("mock.mov")
        let duration = try MockScreenshot.writeRecording(to: movie, width: 1600, height: 1000, seconds: 2)
        try store.add(DraftCapture(
            fileURL: movie, kind: .video, pixelWidth: 1600, pixelHeight: 1000, durationMs: duration, capturedAt: Date(), context: context
        ))
        guard let current = try store.current() else { throw CaptureFailure.failed("no preview draft") }
        let rect = { (x: Int, y: Int) in Shape.rect(NormRect(x: x, y: y, width: 2400, height: 1200)) }
        return try store.update(current.directory) { bundle in
            bundle.title = "Acme Mail settings polish"
            bundle.summary = "Spacing and wording issues on the Accounts page; the progress bar stalls at the end."
            bundle.annotations = [
                Annotation(id: "a1", mediaId: "m1", shape: rect(800, 1500), intents: [.bug], note: "Label is clipped"),
                Annotation(id: "a2", mediaId: "m1", shape: rect(4000, 5000), intents: [.change], note: "Use sentence case"),
                Annotation(id: "a3", mediaId: "m2", shape: .insertion(NormPoint(x: 6000, y: 3000)), note: "Add a search field"),
                Annotation(
                    id: "a4", mediaId: "m3", shape: rect(2000, 300), intents: [.bug], note: "Stalls at 90 %",
                    timeRange: TimeRange(startMs: 1200, endMs: duration)
                ),
            ]
        }
    }

    private static func snapshot(_ view: some View, size: CGSize, to url: URL) throws -> URL {
        let host = NSHostingView(rootView: view.frame(width: size.width, height: size.height))
        let window = NSWindow(contentRect: CGRect(origin: .zero, size: size), styleMask: [.titled], backing: .buffered, defer: false)
        window.contentView = host
        host.frame = CGRect(origin: .zero, size: size)
        host.layoutSubtreeIfNeeded()
        guard let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds) else { throw CaptureFailure.failed("no bitmap") }
        host.cacheDisplay(in: host.bounds, to: rep)
        guard let image = rep.cgImage else { throw CaptureFailure.failed("render failed") }
        try ImageFiles.writePNG(image, to: url)
        return url
    }
}
