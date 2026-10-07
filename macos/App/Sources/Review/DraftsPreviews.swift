import AppKit
import SwiftUI
import UXReviewKit

/// Offscreen renders of the Draft Reviews window for `--render-ui-previews`: several drafts
/// (the current one, older ones, one with a created ticket, an unreadable one), a narrow window,
/// and no drafts. Each is the real `DraftsView` over a throwaway drafts folder. Spec: docs/07 §7.9.
@MainActor
enum DraftsPreviews {
    static let size = CGSize(width: 640, height: 400)

    static func render(to directory: URL) throws -> [URL] {
        let scratch = FileManager.default.temporaryDirectory.appendingPathComponent("uxreview-drafts-previews-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: scratch) }
        try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
        let store = ReviewDraftStore(root: scratch.appendingPathComponent("Drafts"))
        try makeDrafts(in: scratch, store: store)

        var written: [URL] = []
        let model = DraftsModel(store: store)
        written.append(try snapshot(DraftsView(model: model), size: size, to: directory.appendingPathComponent("drafts-list.png")))
        written.append(try snapshot(
            DraftsView(model: model),
            size: CGSize(width: DraftsView.minimumSize.width, height: 400),
            to: directory.appendingPathComponent("drafts-narrow.png")
        ))
        let empty = DraftsModel(store: ReviewDraftStore(root: scratch.appendingPathComponent("Empty")))
        written.append(try snapshot(
            DraftsView(model: empty),
            size: CGSize(width: 640, height: 360),
            to: directory.appendingPathComponent("drafts-empty.png")
        ))
        return written
    }

    /// Four drafts, each with review.json dated so the order is stable.
    private static func makeDrafts(in scratch: URL, store: ReviewDraftStore) throws {
        let reference = Date(timeIntervalSince1970: 1_791_000_000) // October 2026
        let drafts: [(title: String, captures: Int, annotations: Int, hoursAgo: Double)] = [
            ("Acme Mail onboarding — first run, empty inbox, and the long welcome sheet", 3, 5, 30),
            ("Checkout polish", 2, 3, 2),
            ("Safari review", 1, 0, 0.2),
        ]
        for (index, spec) in drafts.enumerated() {
            if index > 0 { try store.startNew() }
            var draft: ReviewDraft?
            for number in 0 ..< spec.captures {
                let file = scratch.appendingPathComponent("mock-\(index)-\(number).png")
                try Data("mock".utf8).write(to: file)
                draft = try store.add(DraftCapture(
                    fileURL: file, kind: .image, pixelWidth: 1600, pixelHeight: 1000, capturedAt: reference,
                    context: CaptureContext(appName: "Acme Mail")
                )).draft
            }
            guard let draft else { continue }
            let updated = try store.update(draft.directory) { bundle in
                bundle.title = spec.title
                bundle.annotations = (0 ..< spec.annotations).map {
                    Annotation(id: "a\($0)", mediaId: "m1", shape: .insertion(NormPoint(x: 5000, y: 5000)), note: "")
                }
            }
            if index == 1 {
                try store.savePendingSubmission(
                    PendingSubmission(storePath: "/s.hs2", ticket: CreatedTicket(slug: "HS-R58EY5"), createdAt: reference),
                    in: draft.directory
                )
            }
            try setDate(reference.addingTimeInterval(-spec.hoursAgo * 3600), of: updated.bundleURL)
        }
        // A draft folder whose review.json is gone (an interrupted first capture).
        let broken = store.root.appendingPathComponent("20261005-101500-9C2B1F", isDirectory: true)
        try FileManager.default.createDirectory(at: broken, withIntermediateDirectories: true)
        try setDate(reference.addingTimeInterval(-50 * 3600), of: broken)
    }

    private static func setDate(_ date: Date, of url: URL) throws {
        try FileManager.default.setAttributes([.modificationDate: date], ofItemAtPath: url.path)
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
