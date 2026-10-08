import AppKit
import CoreMedia
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
            _ name: String, size: CGSize, script: [EditorScript.Step], pressed: [CGPoint] = [], viewport: CanvasViewport? = nil,
            stripWidth: CGFloat = MediaStripWidth.standard
        ) throws {
            let model = try EditorModel(session: EditorSession(store: store, directory: draft.directory))
            offerWindowButtons(model)
            script.forEach { apply($0, to: model) }
            if let viewport { model.setViewport(viewport) }
            hold(pressed, in: model)
            let view = EditorView(model: model, stripWidthOverride: stripWidth)
            written.append(try snapshot(view, size: size, to: directory.appendingPathComponent("\(name).png")))
            model.cancelAutosave()
        }
        let wide = CGSize(width: 1240, height: 800)
        try capture("editor-empty", size: wide, script: [])
        written.append(try renderNoMedia(to: directory, scratch: scratch, size: wide))
        try capture("editor-annotated", size: wide, script: annotations + [.select("#1")])
        // Both captures selected (⌘-click), the second one shown (docs/06 §6.7.2).
        try capture("editor-multi-select", size: wide, script: annotations + [.clickMedia("m2", .toggle)])
        try capture("editor-arrow-selected", size: wide, script: annotations + [.select("#3")])
        try capture("editor-narrow", size: CGSize(width: 900, height: 560), script: annotations + [.select("#2")])
        // HS2-AH6HW4: the capture sidebar dragged wider; its thumbnails grow with it.
        try capture("editor-wide-sidebar", size: wide, script: annotations + [.select("#1")], stripWidth: 240)
        // The Crop tool (docs/06 §6.6): a first crop being drawn on the original; the crop made,
        // shown on the original with its handles (the tool stays Crop); its right edge being
        // dragged; and the cropped capture once another tool is chosen.
        for (name, steps, pressed) in cropStates {
            try capture(name, size: wide, script: annotations + steps, pressed: pressed)
        }
        written += try renderKeyboardInsert(to: directory, store: store, draft: draft, size: wide)
        written += try renderWindowInteractions(to: directory, store: store, draft: draft)
        // 300 % (1.5 points per pixel) on the clipped-label box, panned so its corner is near the middle.
        try capture(
            "editor-zoomed", size: wide, script: annotations + [.select("#1")],
            viewport: CanvasViewport(zoom: 1.5, center: CGPoint(x: 560, y: 300))
        )
        written += try renderVideo(to: directory, scratch: scratch) + renderAutoScroll(to: directory, scratch: scratch)
        return written
    }

    /// The timeline (docs/06 §6.10) on a draft holding one mock screen recording: annotations with
    /// a range, an instant, and the whole clip, the playhead inside the first range.
    /// The editor window always offers capture removal.
    static func offerWindowButtons(_ model: EditorModel) {
        model.confirmRemoval = { _ in }
    }

    /// New Review (⌘N): a draft with no media yet.
    private static func renderNoMedia(to directory: URL, scratch: URL, size: CGSize) throws -> URL {
        let store = ReviewDraftStore(root: scratch.appendingPathComponent("new"))
        let draft = try store.createEmptyDraft()
        let model = try EditorModel(session: EditorSession(store: store, directory: draft.directory))
        offerWindowButtons(model)
        return try snapshot(EditorView(model: model), size: size, to: directory.appendingPathComponent("editor-no-media.png"))
    }

    private static func renderVideo(to directory: URL, scratch: URL) throws -> [URL] {
        let store = ReviewDraftStore(root: scratch.appendingPathComponent("video"))
        let movie = scratch.appendingPathComponent("mock-recording.mov")
        let duration = try MockScreenshot.writeRecording(to: movie, width: 1600, height: 1000, seconds: 3)
        let draft = try store.add(DraftCapture(
            fileURL: movie, kind: .video, pixelWidth: 1600, pixelHeight: 1000, durationMs: duration,
            capturedAt: Date(), context: CaptureContext(appName: "Acme Mail")
        )).draft
        let steps: [EditorScript.Step] = [
            .tool(.rect), .drag([CGPoint(x: 330, y: 250), CGPoint(x: 820, y: 330)]),
            .note("Label flickers while sending."), .intent(.bug), .range(TimeRange(startMs: 1000, endMs: 2000)),
            .tool(.insertion), .drag([CGPoint(x: 560, y: 700)]),
            .note("Show a spinner here."), .range(TimeRange(startMs: 2500, endMs: 2500)),
            .tool(.arrow), .drag([CGPoint(x: 1000, y: 470), CGPoint(x: 1300, y: 600)]),
            .note("Move the toggle next to its label."),
            .select("#1"), .time(1500),
        ]
        var written: [URL] = []
        for (name, size, extra) in [
            ("editor-video-timeline", CGSize(width: 1240, height: 800), [EditorScript.Step]()),
            ("editor-video-narrow", CGSize(width: 900, height: 560), []),
            ("editor-video-trimmed", CGSize(width: 1240, height: 800), [.trim(TimeRange(startMs: 500, endMs: duration)), .time(1000)]),
            // A video crop (docs/06 §6.6): the whole frame under the Crop tool, then the cut frame.
            ("editor-video-crop-tool", CGSize(width: 1240, height: 800), [.tool(.crop), .crop(videoCrop)]),
            ("editor-video-cropped", CGSize(width: 1240, height: 800), [.tool(.crop), .crop(videoCrop), .tool(.select)]),
        ] {
            let model = try EditorModel(session: EditorSession(store: store, directory: draft.directory))
            offerWindowButtons(model)
            (steps + extra).forEach { apply($0, to: model) }
            written.append(try snapshot(EditorView(model: model), size: size, to: directory.appendingPathComponent("\(name).png")))
        }
        // Timeline drags (HS2-MAH7NK), caught mid-drag: a range end, and a trim handle's preview.
        for (name, handle, millis) in [
            ("editor-video-range-drag", TimelineHandle.rangeEnd, 2600), ("editor-video-trim-drag", TimelineHandle.trimStart, 700),
        ] {
            let dragging = try EditorModel(session: EditorSession(store: store, directory: draft.directory))
            offerWindowButtons(dragging)
            steps.forEach { apply($0, to: dragging) }
            dragging.mutate { editor in
                editor.beginTimelineDrag(handle)
                editor.updateTimelineDrag(toMs: millis)
            }
            written.append(try snapshot(
                EditorView(model: dragging),
                size: CGSize(width: 1240, height: 800),
                to: directory.appendingPathComponent("\(name).png")
            ))
        }
        written.append(try renderFrameStep(store: store, draft: draft, steps: steps, to: directory))
        // Playing (K): the pause button shows and the playhead and canvas follow the player. Last,
        // because its autosave writes the scripted annotations into the shared draft.
        let model = try EditorModel(session: EditorSession(store: store, directory: draft.directory))
        offerWindowButtons(model)
        (steps + [.time(600)]).forEach { apply($0, to: model) }
        model.togglePlayback()
        RunLoop.main.run(until: Date().addingTimeInterval(1.2))
        written.append(try snapshot(
            EditorView(model: model),
            size: CGSize(width: 1240, height: 800),
            to: directory.appendingPathComponent("editor-video-playing.png")
        ))
        model.pause()
        return written
    }

    /// Frame steps (HS2-8FTZ09): the selected range's end grip pressed and released in place (so
    /// it is the last-used timeline target), then ⇧→ and ← as real key events through the canvas:
    /// 10 frames forward and 1 back at 10 fps, so the range ends at 2.9 s and the playhead follows.
    private static func renderFrameStep(
        store: ReviewDraftStore, draft: ReviewDraft, steps: [EditorScript.Step], to directory: URL
    ) throws -> URL {
        let stepping = try EditorModel(session: EditorSession(store: store, directory: draft.directory))
        offerWindowButtons(stepping)
        steps.forEach { apply($0, to: stepping) }
        stepping.mutate { editor in
            editor.beginTimelineDrag(.rangeEnd)
            editor.endTimelineDrag()
        }
        func stepFrames(_ canvas: AnnotationCanvasView) throws {
            for (key, code, flags) in [
                (NSRightArrowFunctionKey, UInt16(124), NSEvent.ModifierFlags.shift), (
                    NSLeftArrowFunctionKey,
                    UInt16(123),
                    NSEvent.ModifierFlags()
                ),
            ] {
                let characters = String(Character(UnicodeScalar(UInt32(key))!))
                guard let event = NSEvent.keyEvent(
                    with: .keyDown, location: .zero, modifierFlags: flags.union([.function, .numericPad]), timestamp: 0,
                    windowNumber: canvas.window?.windowNumber ?? 0, context: nil, characters: characters,
                    charactersIgnoringModifiers: characters, isARepeat: false, keyCode: code
                ) else { throw CaptureFailure.failed("no key event") }
                canvas.keyDown(with: event)
            }
        }
        return try snapshot(
            EditorView(model: stepping),
            size: CGSize(width: 1240, height: 800),
            to: directory.appendingPathComponent("editor-video-frame-step.png"),
            interact: stepFrames
        )
    }

    /// Auto-scroll (docs/06 §6.2.1): a rectangle drawn on a 5K capture at 400 %, the pointer parked
    /// at the canvas's right edge for 1.5 s of timer ticks, so the canvas has scrolled and the box
    /// kept growing past what was visible when the drag began. Driven through `autoScrollStep`, as
    /// the canvas timer drives it.
    private static func renderAutoScroll(to directory: URL, scratch: URL) throws -> [URL] {
        let store = ReviewDraftStore(root: scratch.appendingPathComponent("autoscroll"))
        let url = scratch.appendingPathComponent("mock-5k.png")
        guard let image = MockScreenshot.settingsPage(width: 5120, height: 2880, variant: 0)
        else { throw CaptureFailure.failed("no 5K mock") }
        try ImageFiles.writePNG(image, to: url)
        let draft = try store.add(DraftCapture(
            fileURL: url, kind: .image, pixelWidth: 5120, pixelHeight: 2880, capturedAt: Date(),
            context: CaptureContext(appName: "Acme Mail")
        )).draft
        let model = try EditorModel(session: EditorSession(store: store, directory: draft.directory))
        offerWindowButtons(model)
        model.setViewport(CanvasViewport(zoom: 1, center: CGPoint(x: 1300, y: 820)))
        func drag(_ canvas: AnnotationCanvasView) throws {
            guard let renderer = canvas.renderer() else { throw CaptureFailure.failed("no canvas layout") }
            let pointer = CGPoint(x: canvas.bounds.maxX - 4, y: canvas.bounds.midY + 60)
            model.mutate { editor in
                editor.setTool(.rect)
                editor.beginGesture(at: renderer.pixel(CGPoint(x: canvas.bounds.midX - 120, y: canvas.bounds.midY - 80)))
                editor.updateGesture(to: renderer.pixel(pointer))
            }
            for _ in 0 ..< 90 {
                model.autoScrollStep(pointer: pointer, elapsed: 1.0 / 60)
            }
        }
        let url2 = directory.appendingPathComponent("editor-autoscroll.png")
        return [try snapshot(EditorView(model: model), size: CGSize(width: 1240, height: 800), to: url2, interact: drag)]
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

    static func apply(_ step: EditorScript.Step, to model: EditorModel) {
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
            case let .range(range): if let id = editor.selection { editor.setTimeRange(range, for: id) }
            case let .time(millis): editor.setCurrentTime(millis)
            case let .trim(range): editor.trim(to: range)
            case let .clickMedia(id, click): editor.clickMedia(id, click)
            default: break
            }
        }
    }

    /// The canvas's accessibility element and its children, as VoiceOver sees them.
    static func writeAccessibility(of canvas: AnnotationCanvasView, to url: URL) throws -> URL {
        struct Element: Encodable {
            var label: String
            var role: String
            var selected: Bool
            var frame: [Double]
        }
        struct Tree: Encodable {
            var label: String
            var help: String
            var role: String
            var children: [Element]
        }
        let children = (canvas.accessibilityChildren() ?? []).compactMap { $0 as? AnnotationAccessibilityElement }.map { element in
            let frame = element.accessibilityFrameInParentSpace()
            return Element(
                label: element.accessibilityLabel() ?? "", role: element.accessibilityRoleDescription() ?? "",
                selected: element.isAccessibilitySelected(),
                frame: [frame.minX, frame.minY, frame.width, frame.height].map { Double($0.rounded()) }
            )
        }
        let tree = Tree(
            label: canvas.accessibilityLabel() ?? "", help: canvas.accessibilityHelp() ?? "",
            role: canvas.accessibilityRole()?.rawValue ?? "", children: children
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        try encoder.encode(tree).write(to: url)
        return url
    }

    static func snapshot(
        _ view: some View, size: CGSize, to url: URL, interact: ((AnnotationCanvasView) throws -> Void)? = nil
    ) throws -> URL {
        // cacheDisplay skips the window's own background, so paint it (else the tool bar's
        // text sits on transparent pixels).
        let host = NSHostingView(
            rootView: view.frame(width: size.width, height: size.height)
                .background(Color(nsColor: .windowBackgroundColor))
        )
        let window = NSWindow(contentRect: CGRect(origin: .zero, size: size), styleMask: [.titled], backing: .buffered, defer: false)
        window.contentView = host
        host.frame = CGRect(origin: .zero, size: size)
        host.layoutSubtreeIfNeeded()
        if let interact {
            guard let canvas = host.firstDescendant(AnnotationCanvasView.self) else { throw CaptureFailure.failed("no canvas") }
            try interact(canvas)
            host.layoutSubtreeIfNeeded()
        }
        guard let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds) else { throw CaptureFailure.failed("no bitmap") }
        host.cacheDisplay(in: host.bounds, to: rep)
        guard let image = rep.cgImage else { throw CaptureFailure.failed("render failed") }
        try ImageFiles.writePNG(image, to: url)
        return url
    }
}

extension MockScreenshot {
    /// A mock screen recording: the settings page with a progress bar filling over `seconds` at
    /// 10 fps. Returns the duration in millis. Blocks until the movie is written.
    static func writeRecording(to url: URL, width: Int, height: Int, seconds: Int) throws -> Int {
        guard let page = settingsPage(width: width, height: height, variant: 0) else { throw CaptureFailure.failed("no mock page") }
        let writer = try VideoFileWriter(url: url, width: width, height: height, framesPerSecond: 10)
        for index in 0 ..< seconds * 10 {
            guard let context = CGContext(
                data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue
            ) else { throw CaptureFailure.failed("no frame context") }
            context.draw(page, in: CGRect(x: 0, y: 0, width: width, height: height))
            let progress = CGFloat(index + 1) / CGFloat(seconds * 10)
            context.setFillColor(CGColor(gray: 0.85, alpha: 1))
            context.fill(CGRect(x: 330, y: 40, width: 940, height: 14))
            context.setFillColor(CGColor(srgbRed: 0.04, green: 0.52, blue: 1, alpha: 1))
            context.fill(CGRect(x: 330, y: 40, width: 940 * progress, height: 14))
            guard let frame = context.makeImage(),
                  let buffer = VideoFileWriter.pixelBuffer(from: frame, width: width, height: height)
            else { throw CaptureFailure.failed("no frame") }
            let time = CMTime(value: CMTimeValue(index * 60), timescale: 600)
            var attempts = 0
            while !writer.append(buffer, at: time) {
                attempts += 1
                guard attempts < 2000 else { throw CaptureFailure.failed("encoder never became ready") }
                Thread.sleep(forTimeInterval: 0.005)
            }
        }
        let result = ResultBox()
        let done = DispatchSemaphore(value: 0)
        Task.detached {
            do {
                result.value = try await .success(writer.finish(at: CMTime(value: CMTimeValue(seconds * 600), timescale: 600)))
            } catch {
                result.value = .failure(error)
            }
            done.signal()
        }
        done.wait()
        guard let value = result.value else { throw CaptureFailure.failed("recording not finished") }
        return try value.get()
    }

    private final class ResultBox: @unchecked Sendable {
        var value: Result<Int, Error>?
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
