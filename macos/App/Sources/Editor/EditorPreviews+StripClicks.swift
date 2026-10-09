import AppKit
import SwiftUI
import UXReviewKit

/// Clicks on the media strip through real mouse events (`HS2-QXJZJ9`): a draft mixing landscape
/// and tall portrait captures, a column of clicks swept down the strip, and which capture each
/// click showed (`editor-strip-clicks.json`). Every click must land on the thumbnail under the
/// pointer, never on a neighbor and never on nothing.
extension EditorPreviews {
    static func renderStripClicks(to directory: URL, scratch: URL) throws -> [URL] {
        let model = try stripClickModel(scratch: scratch)
        let ids = model.editor.bundle.media.map(\.id)
        guard let parking = ids.last else { throw CaptureFailure.failed("no media") }
        let clicker = ClickableEditor(EditorView(model: model, stripWidthOverride: MediaStripWidth.standard))
        defer { clicker.close() }
        // Two columns: the strip's middle, and near the thumbnails' left edge (beside a short
        // filename). Every 3 points from the top of the first capture to the end of the third.
        // The parking capture is selected before every click, so a click that hits nothing
        // shows up as "none".
        var probes: [[String: Any]] = []
        for x in [MediaStripWidth.standard / 2, 14] {
            for y in stride(from: 4, through: 300, by: 3) {
                model.mutate { $0.clickMedia(parking, .plain) }
                clicker.settle()
                clicker.click(CGPoint(x: x, y: CGFloat(y)))
                let shown = model.editor.currentMediaId
                probes.append(["x": Double(x), "y": y, "shown": shown == parking ? "none" : shown ?? "none"])
            }
        }
        model.mutate { $0.clickMedia(ids[1], .plain) }
        clicker.settle()
        let png = try clicker.snapshot(to: directory.appendingPathComponent("editor-strip-portrait.png"))
        model.cancelAutosave()
        let url = directory.appendingPathComponent("editor-strip-clicks.json")
        try JSONSerialization.data(
            withJSONObject: ["media": ids, "probes": probes], options: [.prettyPrinted, .sortedKeys]
        ).write(to: url)
        return [png, url]
    }

    /// Landscape, tall portrait (a phone-sized window), landscape, then the parking capture.
    private static func stripClickModel(scratch: URL) throws -> EditorModel {
        let store = ReviewDraftStore(root: scratch.appendingPathComponent("strip-clicks"))
        var draft: ReviewDraft?
        for (index, size) in [(1600, 1000), (600, 1600), (1200, 800), (1400, 900)].enumerated() {
            let url = scratch.appendingPathComponent("strip-\(index).png")
            guard let image = MockScreenshot.settingsPage(width: size.0, height: size.1, variant: index % 2)
            else { throw CaptureFailure.failed("no strip mock") }
            try ImageFiles.writePNG(image, to: url)
            draft = try store.add(DraftCapture(
                fileURL: url, kind: .image, pixelWidth: size.0, pixelHeight: size.1,
                capturedAt: Date(), context: CaptureContext(appName: "Acme Mail")
            )).draft
        }
        guard let draft else { throw CaptureFailure.failed("no strip draft") }
        let model = try EditorModel(session: EditorSession(store: store, directory: draft.directory))
        offerWindowButtons(model)
        return model
    }
}

/// A SwiftUI view in a real window that takes real mouse events. SwiftUI's buttons only take
/// clicks in a key window that is ordered in, so the window is shown, far off every screen.
@MainActor
final class ClickableEditor {
    let size = CGSize(width: 1240, height: 800)
    private let host: NSView
    private let window: NSWindow

    init(_ view: some View) {
        host = NSHostingView(
            rootView: view.frame(width: size.width, height: size.height).background(Color(nsColor: .windowBackgroundColor))
        )
        window = KeyablePanel(contentRect: CGRect(origin: .zero, size: size), styleMask: [.borderless], backing: .buffered, defer: false)
        window.contentView = host
        host.frame = CGRect(origin: .zero, size: size)
        window.setFrameOrigin(CGPoint(x: -30000, y: -30000))
        window.orderFrontRegardless()
        window.makeKey()
        settle()
    }

    func settle() {
        RunLoop.main.run(until: Date().addingTimeInterval(0.02))
        host.layoutSubtreeIfNeeded()
    }

    /// A mouse down and up at `point`, top-down in the view (window coordinates are bottom-up).
    func click(_ point: CGPoint) {
        let location = CGPoint(x: point.x, y: size.height - point.y)
        for type in [NSEvent.EventType.leftMouseDown, .leftMouseUp] {
            guard let event = NSEvent.mouseEvent(
                with: type, location: location, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: type == .leftMouseDown ? 1 : 0
            ) else { continue }
            window.sendEvent(event)
            settle()
        }
    }

    func snapshot(to url: URL) throws -> URL {
        guard let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds) else { throw CaptureFailure.failed("no bitmap") }
        host.cacheDisplay(in: host.bounds, to: rep)
        guard let image = rep.cgImage else { throw CaptureFailure.failed("render failed") }
        try ImageFiles.writePNG(image, to: url)
        return url
    }

    func close() {
        window.orderOut(nil)
    }
}

/// A borderless window that can become key, so real mouse events reach SwiftUI's controls.
private final class KeyablePanel: NSWindow {
    override var canBecomeKey: Bool { true }
}
