import AppKit
import CoreText
import SwiftUI
import UXReviewKit

/// Offscreen renders of the annotation editor for `--render-ui-previews` (visual QA without a
/// display session). Each state is built through the real `EditorSession` and `EditorScript`
/// on a throwaway draft whose captures are mock app screenshots. Spec: docs/06 §6.9.
@MainActor
enum EditorPreviews {
    static func render(to directory: URL) throws -> [URL] {
        let scratch = FileManager.default.temporaryDirectory.appendingPathComponent("uxreview-previews-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: scratch) }
        let store = ReviewDraftStore(root: scratch)
        for (index, size) in [(1600, 1000), (1200, 800)].enumerated() {
            let url = scratch.appendingPathComponent("mock-\(index).png")
            try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
            guard let image = MockScreenshot.settingsPage(width: size.0, height: size.1, variant: index) else { continue }
            try ImageFiles.writePNG(image, to: url)
            try store.add(DraftCapture(
                fileURL: url, kind: .image, pixelWidth: size.0, pixelHeight: size.1,
                capturedAt: Date(), context: CaptureContext(appName: "Acme Mail")
            ))
        }
        guard let draft = try store.current() else { throw CaptureFailure.failed("no preview draft") }

        var written: [URL] = []
        // Nothing is saved, so every state starts from the same empty draft.
        func capture(
            _ name: String, size: CGSize, script: [EditorScript.Step], cropDrag: Bool = false, viewport: CanvasViewport? = nil
        ) throws {
            let model = try EditorModel(session: EditorSession(store: store, directory: draft.directory))
            script.forEach { apply($0, to: model) }
            if let viewport { model.setViewport(viewport) }
            if cropDrag {
                model.mutate { editor in
                    editor.beginGesture(at: CGPoint(x: 220, y: 90))
                    editor.updateGesture(to: CGPoint(x: 1400, y: 650))
                }
            }
            written.append(try snapshot(EditorView(model: model), size: size, to: directory.appendingPathComponent("\(name).png")))
        }
        let wide = CGSize(width: 1240, height: 800)
        try capture("editor-empty", size: wide, script: [])
        try capture("editor-annotated", size: wide, script: annotations + [.select("#1")])
        try capture("editor-arrow-selected", size: wide, script: annotations + [.select("#3")])
        try capture("editor-narrow", size: CGSize(width: 900, height: 560), script: annotations + [.select("#2")])
        try capture("editor-crop-drag", size: wide, script: annotations + [.tool(.crop)], cropDrag: true)
        try capture("editor-cropped", size: wide, script: annotations + [.crop(CGRect(x: 220, y: 90, width: 1180, height: 560))])
        // 300 % (1.5 points per pixel) on the clipped-label box, panned so its corner is near the middle.
        try capture(
            "editor-zoomed", size: wide, script: annotations + [.select("#1")],
            viewport: CanvasViewport(zoom: 1.5, center: CGPoint(x: 560, y: 300))
        )
        return written
    }

    /// A realistic review of the mock settings page: one of each shape, notes, and intents.
    static let annotations: [EditorScript.Step] = [
        .tool(.rect), .drag([CGPoint(x: 330, y: 250), CGPoint(x: 820, y: 330)]),
        .note("Field label is clipped at 200 % text size."), .intent(.bug),
        .tool(.strike), .drag([CGPoint(x: 1184, y: 864), CGPoint(x: 1296, y: 928)]),
        .note("Remove the duplicate **Cancel** button."),
        .tool(.arrow), .drag([CGPoint(x: 1000, y: 470), CGPoint(x: 1300, y: 600)]),
        .note("Move the toggle next to its label."),
        .tool(.insertion), .drag([CGPoint(x: 560, y: 700)]),
        .note("Insert helper text: \"We never share your email.\""), .intent(.question),
        .tool(.freehand), .drag(ellipse(center: CGPoint(x: 160, y: 520), radius: CGSize(width: 110, height: 70))),
        .note("Sidebar icons are inconsistent sizes."), .intent(.change),
        .select(nil),
    ]

    static func ellipse(center: CGPoint, radius: CGSize) -> [CGPoint] {
        (0 ... 36).map { step in
            let angle = Double(step) / 36 * 2 * .pi
            return CGPoint(x: center.x + radius.width * cos(angle), y: center.y + radius.height * sin(angle))
        }
    }

    private static func apply(_ step: EditorScript.Step, to model: EditorModel) {
        model.mutate { editor in
            switch step {
            case let .tool(tool): editor.setTool(tool)
            case let .drag(points):
                editor.minimumSide = 4
                editor.beginGesture(at: points[0])
                points.dropFirst().forEach { editor.updateGesture(to: $0) }
                editor.endGesture()
            case let .note(text): if let id = editor.selection { editor.setNote(text, for: id) }
            case let .intent(intent): if let id = editor.selection { editor.toggleIntent(intent, for: id) }
            case let .select(reference):
                let id = reference.flatMap { Int($0.dropFirst()) }.flatMap { number in
                    editor.bundle.annotations.indices.contains(number - 1) ? editor.bundle.annotations[number - 1].id : nil
                }
                editor.select(id)
            case let .crop(rect): editor.crop(to: rect)
            default: break
            }
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

/// A plausible app screenshot (a settings page) so annotation previews look like real use.
/// Laid out on a 1600-wide grid and scaled to the requested width.
struct MockScreenshot {
    let context: CGContext
    let unit: CGFloat

    static func settingsPage(width: Int, height: Int, variant: Int) -> CGImage? {
        guard let space = CGColorSpace(name: CGColorSpace.sRGB),
              let context = CGContext(
                  data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0, space: space,
                  bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue
              )
        else { return nil }
        // Top-left coordinates for readability.
        context.translateBy(x: 0, y: CGFloat(height))
        context.scaleBy(x: 1, y: -1)
        let page = MockScreenshot(context: context, unit: CGFloat(width) / 1600)
        page.chrome(width: CGFloat(width), height: CGFloat(height), title: variant == 0 ? "Acme Mail — Settings" : "Acme Mail — Inbox")
        page.form(heading: variant == 0 ? "Accounts" : "Inbox")
        page.buttons()
        return context.makeImage()
    }

    func fill(_ rect: CGRect, _ color: CGColor, radius: CGFloat = 0) {
        let scaled = CGRect(x: rect.minX * unit, y: rect.minY * unit, width: rect.width * unit, height: rect.height * unit)
        context.setFillColor(color)
        context.addPath(CGPath(roundedRect: scaled, cornerWidth: radius * unit, cornerHeight: radius * unit, transform: nil))
        context.fillPath()
    }

    func fill(_ rect: CGRect, gray: CGFloat, radius: CGFloat = 0) { fill(rect, CGColor(gray: gray, alpha: 1), radius: radius) }

    func text(_ string: String, _ x: CGFloat, _ y: CGFloat, size: CGFloat, gray: CGFloat = 0.15, bold: Bool = false) {
        let font = NSFont.systemFont(ofSize: size * unit, weight: bold ? .semibold : .regular)
        let attributed = NSAttributedString(string: string, attributes: [.font: font, .foregroundColor: NSColor(white: gray, alpha: 1)])
        context.saveGState()
        context.textMatrix = CGAffineTransform(scaleX: 1, y: -1)
        context.textPosition = CGPoint(x: x * unit, y: y * unit)
        CTLineDraw(CTLineCreateWithAttributedString(attributed), context)
        context.restoreGState()
    }

    func chrome(width: CGFloat, height: CGFloat, title: String) {
        fill(CGRect(x: 0, y: 0, width: width / unit, height: height / unit), gray: 0.97)
        fill(CGRect(x: 0, y: 0, width: width / unit, height: 56), gray: 0.9)
        let lights: [(CGFloat, CGFloat, CGFloat)] = [(1, 0.37, 0.33), (1, 0.74, 0.2), (0.35, 0.8, 0.35)]
        for (index, light) in lights.enumerated() {
            fill(
                CGRect(x: 20 + CGFloat(index) * 26, y: 20, width: 16, height: 16),
                CGColor(srgbRed: light.0, green: light.1, blue: light.2, alpha: 1),
                radius: 8
            )
        }
        text(title, 640, 36, size: 18, gray: 0.3, bold: true)
        fill(CGRect(x: 0, y: 56, width: 300, height: height / unit - 56), gray: 0.93)
        for (index, item) in ["General", "Accounts", "Notifications", "Privacy", "Appearance", "Advanced"].enumerated() {
            let y = CGFloat(110 + index * 56)
            if index == 1 { fill(CGRect(x: 16, y: y - 30, width: 268, height: 44), gray: 0.84, radius: 8) }
            let icon = CGFloat(18 + index % 3 * 5) // deliberately inconsistent, for the review
            fill(CGRect(x: 36, y: y - 20, width: icon, height: icon), gray: 0.55, radius: 4)
            text(item, 76, y, size: 20)
        }
    }

    func form(heading: String) {
        text(heading, 340, 140, size: 40, bold: true)
        for (label, value, y) in [("Email address", "jordan@example.com", 260.0), ("Display name", "Jordan Lee", 400.0)] {
            text(label, 340, y - 30, size: 20, gray: 0.35)
            fill(CGRect(x: 340, y: y, width: 640, height: 56), gray: 1, radius: 8)
            text(value, 360, y + 37, size: 22)
        }
        text("Show unread count in the menu bar", 340, 540, size: 22)
        fill(CGRect(x: 1280, y: 515, width: 72, height: 40), CGColor(srgbRed: 0.2, green: 0.78, blue: 0.35, alpha: 1), radius: 20)
        fill(CGRect(x: 1314, y: 519, width: 34, height: 34), gray: 1, radius: 17)
        text("Signature", 340, 640, size: 20, gray: 0.35)
        fill(CGRect(x: 340, y: 660, width: 1060, height: 140), gray: 1, radius: 8)
        text("Sent from Acme Mail", 360, 700, size: 22, gray: 0.45)
    }

    func buttons() {
        fill(CGRect(x: 1000, y: 870, width: 160, height: 52), gray: 0.88, radius: 10)
        text("Cancel", 1044, 904, size: 20)
        fill(CGRect(x: 1190, y: 870, width: 100, height: 52), gray: 0.88, radius: 10) // the duplicate under review
        text("Cancel", 1205, 904, size: 20)
        fill(CGRect(x: 1310, y: 870, width: 120, height: 52), CGColor(srgbRed: 0.04, green: 0.52, blue: 1, alpha: 1), radius: 10)
        text("Save", 1346, 904, size: 20, gray: 1, bold: true)
    }
}
