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
        let url = directory.appendingPathComponent("editor-strip-clicks.json")
        try JSONSerialization.data(
            withJSONObject: ["media": ids, "probes": probes], options: [.prettyPrinted, .sortedKeys]
        ).write(to: url)
        let menu = try renderStripMenu(model, clicker, centers: bandCenters(probes, x: Double(MediaStripWidth.standard / 2)), to: directory)
        model.cancelAutosave()
        return [png, url, menu]
    }

    /// The middle of each capture's band of clicks down one column: where to click a thumbnail.
    private static func bandCenters(_ probes: [[String: Any]], x: Double) -> [String: CGPoint] {
        var heights: [String: [Int]] = [:]
        for probe in probes where probe["x"] as? Double == x {
            if let shown = probe["shown"] as? String, shown != "none", let y = probe["y"] as? Int { heights[shown, default: []].append(y) }
        }
        return heights.mapValues { CGPoint(x: x, y: Double($0[$0.count / 2])) }
    }

    /// HS2-20VQ8Q: real right-clicks on the media strip open its context menu; Show in Finder and
    /// Copy Path run from that menu on one capture, on a selection, and on a capture outside the
    /// selection (`editor-strip-menu.json`). Copy Path writes to a private pasteboard and Show in
    /// Finder is recorded, so the run never touches the clipboard or opens Finder.
    private static func renderStripMenu(
        _ model: EditorModel, _ clicker: ClickableEditor, centers: [String: CGPoint], to directory: URL
    ) throws -> URL {
        let pasteboard = NSPasteboard.withUniqueName()
        defer { pasteboard.releaseGlobally() }
        var revealed: [URL] = []
        model.pasteboard = pasteboard
        model.reveal = { revealed = $0 }
        let draft = model.session.directory.standardizedFileURL
        let names = { (files: [URL]) in files.map(\.lastPathComponent) }
        let inDraft = { (files: [URL]) in files.allSatisfy { $0.deletingLastPathComponent().standardizedFileURL == draft } }
        func open(_ id: String) -> [String: Any] {
            guard let point = centers[id], let menu = clicker.contextMenu(at: point) else { return ["clicked": id, "titles": []] }
            let titles = menu.items.map { $0.isSeparatorItem ? "-" : $0.title }
            pasteboard.clearContents()
            revealed = []
            for title in [CaptureFileActions.revealTitle, titles.first { $0.hasPrefix("Copy ") } ?? ""] {
                if let index = menu.items.firstIndex(where: { $0.title == title }) { menu.performActionForItem(at: index) }
            }
            clicker.settle()
            let copied = (pasteboard.string(forType: .string) ?? "").split(separator: "\n").map { URL(fileURLWithPath: String($0)) }
            return [
                "clicked": id, "titles": titles,
                "copied": names(copied),
                "copiedInDraft": inDraft(copied) && copied.allSatisfy { FileManager.default.fileExists(atPath: $0.path) },
                "revealed": names(revealed), "revealedInDraft": inDraft(revealed),
            ]
        }
        let ids = model.editor.bundle.media.map(\.id)
        model.mutate { $0.clickMedia(ids[0], .plain) }
        clicker.settle()
        let single = open(ids[0])
        model.mutate { $0.clickMedia(ids[2], .toggle) }
        clicker.settle()
        let selection = open(ids[2])
        let outside = open(ids[1])
        model.pasteboard = .general
        let url = directory.appendingPathComponent("editor-strip-menu.json")
        try JSONSerialization.data(
            withJSONObject: ["single": single, "selection": selection, "outside": outside], options: [.prettyPrinted, .sortedKeys]
        ).write(to: url)
        return url
    }

    /// HS2-WTPT8X: the shown thumbnail's ✕ appears only under the pointer, so it is drawn with
    /// the hover on (`editor-strip-hover.png`); every other render shows the strip at rest.
    static func renderStripHover(to directory: URL, store: ReviewDraftStore, draft: ReviewDraft, size: CGSize) throws -> URL {
        let model = try EditorModel(session: EditorSession(store: store, directory: draft.directory))
        offerWindowButtons(model)
        defer { model.cancelAutosave() }
        return try snapshot(
            EditorView(model: model, stripWidthOverride: MediaStripWidth.standard, stripHoverOverride: true),
            size: size, to: directory.appendingPathComponent("editor-strip-hover.png")
        )
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

    /// The context menu a right-click at `point` (top-down in the view) opens, as AppKit asks the
    /// view under the pointer for it, without popping it up (that would block until dismissed).
    func contextMenu(at point: CGPoint) -> NSMenu? {
        let location = CGPoint(x: point.x, y: size.height - point.y)
        guard let event = NSEvent.mouseEvent(
            with: .rightMouseDown, location: location, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
            windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1
        ) else { return nil }
        var view = window.contentView?.hitTest(location)
        while let current = view {
            if let menu = current.menu(for: event) {
                menu.update()
                return menu
            }
            view = current.superview
        }
        return nil
    }

    /// A key equivalent such as ⌘[ through the window, as a key press reaches SwiftUI's shortcuts.
    func pressKeyEquivalent(_ characters: String, keyCode: UInt16, modifiers: NSEvent.ModifierFlags) -> Bool {
        guard let event = NSEvent.keyEvent(
            with: .keyDown, location: .zero, modifierFlags: modifiers, timestamp: ProcessInfo.processInfo.systemUptime,
            windowNumber: window.windowNumber, context: nil, characters: characters, charactersIgnoringModifiers: characters,
            isARepeat: false, keyCode: keyCode
        ) else { return false }
        let handled = window.performKeyEquivalent(with: event)
        settle()
        return handled
    }

    /// True when a text view (the note field) has keyboard focus.
    var textHasFocus: Bool { window.firstResponder is NSTextView }

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
