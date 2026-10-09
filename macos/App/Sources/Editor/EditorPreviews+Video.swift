import AppKit
import SwiftUI
import UXReviewKit

/// The video editor's preview states (docs/06 §6.10): the timeline, a narrow window, a trim,
/// crops, timeline drags, frame steps, and playback.
extension EditorPreviews {
    static func renderVideo(to directory: URL, scratch: URL) throws -> [URL] {
        let store = ReviewDraftStore(root: scratch.appendingPathComponent("video"))
        let movie = scratch.appendingPathComponent("mock-recording.mov")
        let duration = try MockScreenshot.writeRecording(to: movie, width: 1600, height: 1000, seconds: 3)
        let draft = try store.add(DraftCapture(
            fileURL: movie, kind: .video, pixelWidth: 1600, pixelHeight: 1000, durationMs: duration,
            capturedAt: Date(), context: CaptureContext(appName: "Acme Mail")
        )).draft
        let steps: [EditorScript.Step] = [
            .tool(.rect), .drag([CGPoint(x: 330, y: 250), CGPoint(x: 820, y: 330)]),
            .note("Label flickers while sending."), .intent(.bug, .toggle), .range(TimeRange(startMs: 1000, endMs: 2000)),
            .tool(.insertion), .drag([CGPoint(x: 560, y: 700)]),
            .note("Show a spinner here."), .range(TimeRange(startMs: 2500, endMs: 2500)),
            .tool(.arrow), .drag([CGPoint(x: 1000, y: 470), CGPoint(x: 1300, y: 600)]),
            .note("Move the toggle next to its label."),
            .select("#1"), .time(1500),
        ]
        var written: [URL] = []
        var layouts: [String: [String: Double]] = [:]
        for (name, size, strip, extra) in [
            ("editor-video-timeline", CGSize(width: 1240, height: 800), MediaStripWidth.standard, [EditorScript.Step]()),
            ("editor-video-narrow", CGSize(width: 900, height: 560), MediaStripWidth.standard, []),
            // HS2-RZVDEQ: the widest saved strip in the narrowest window gives way to the inspector.
            ("editor-video-narrow-wide-strip", CGSize(width: 900, height: 560), MediaStripWidth.maximum, []),
            (
                "editor-video-trimmed",
                CGSize(width: 1240, height: 800),
                MediaStripWidth.standard,
                [.trim(TimeRange(startMs: 500, endMs: duration)), .time(1000)]
            ),
            // A video crop (docs/06 §6.6): the whole frame under the Crop tool, then the cut frame.
            ("editor-video-crop-tool", CGSize(width: 1240, height: 800), MediaStripWidth.standard, [.tool(.crop), .crop(videoCrop)]),
            (
                "editor-video-cropped",
                CGSize(width: 1240, height: 800),
                MediaStripWidth.standard,
                [.tool(.crop), .crop(videoCrop), .tool(.select)]
            ),
        ] {
            let model = try EditorModel(session: EditorSession(store: store, directory: draft.directory))
            offerWindowButtons(model)
            (steps + extra).forEach { apply($0, to: model) }
            model.loadFilmstripNow(count: 16)
            let view = EditorView(model: model, stripWidthOverride: strip)
            written.append(try snapshot(view, size: size, to: directory.appendingPathComponent("\(name).png")) { canvas in
                let frame = canvas.convert(canvas.bounds, to: nil)
                layouts[name] = ["width": size.width, "canvasHeight": frame.height, "canvasLeft": frame.minX, "canvasRight": frame.maxX]
            })
        }
        // HS2-XSXV5E: the timeline bar keeps one height, so the canvas takes all of the narrow
        // window's lost height (the duration once wrapped a character per line, growing the bar).
        // HS2-RZVDEQ: the canvas's right edge plus the divider and inspector is the window's width.
        let layout = directory.appendingPathComponent("editor-video-layout.json")
        try JSONSerialization.data(withJSONObject: layouts, options: [.prettyPrinted, .sortedKeys]).write(to: layout)
        written.append(layout)
        written += try renderTimelineDrags(store: store, draft: draft, steps: steps, to: directory)
        written.append(try renderFrameStep(store: store, draft: draft, steps: steps, to: directory))
        written += try renderPlayheadTime(store: store, draft: draft, steps: steps, to: directory)
        // Last, because its autosave writes the scripted annotations into the shared draft.
        written.append(try renderPlaying(store: store, draft: draft, steps: steps, to: directory))
        return written
    }

    /// Timeline drags (HS2-MAH7NK), caught mid-drag: a range end; and Trim mode (HS2-ECE7WY) with
    /// its handles moved in to 0.5 s and 2.5 s.
    private static func renderTimelineDrags(
        store: ReviewDraftStore, draft: ReviewDraft, steps: [EditorScript.Step], to directory: URL
    ) throws -> [URL] {
        try [("editor-video-range-drag", true), ("editor-video-trim-mode", false)].map { name, rangeDrag in
            let dragging = try EditorModel(session: EditorSession(store: store, directory: draft.directory))
            offerWindowButtons(dragging)
            steps.forEach { apply($0, to: dragging) }
            dragging.loadFilmstripNow(count: 16)
            dragging.mutate { editor in
                if rangeDrag {
                    editor.beginTimelineDrag(.rangeEnd)
                    editor.updateTimelineDrag(toMs: 2600)
                } else {
                    editor.enterTrimMode()
                    editor.setTrimModeEnd(.trimStart, toMs: 500)
                    editor.setTrimModeEnd(.trimEnd, toMs: 2500)
                }
            }
            return try snapshot(
                EditorView(model: dragging),
                size: CGSize(width: 1240, height: 800),
                to: directory.appendingPathComponent("\(name).png")
            )
        }
    }

    /// HS2-8TRCJ6: the timeline bar with the playhead time as a label, and after a click as a field.
    private static func renderPlayheadTime(
        store: ReviewDraftStore, draft: ReviewDraft, steps: [EditorScript.Step], to directory: URL
    ) throws -> [URL] {
        let model = try EditorModel(session: EditorSession(store: store, directory: draft.directory))
        steps.forEach { apply($0, to: model) }
        model.loadFilmstripNow(count: 12)
        defer { model.cancelAutosave() }
        return try [("editor-video-time-label", false), ("editor-video-time-editing", true)].map { name, editing in
            try snapshot(
                TimelineBar(model: model, startsEditingTime: editing), size: CGSize(width: 900, height: 120),
                to: directory.appendingPathComponent("\(name).png")
            )
        }
    }

    /// Playing (K): the pause button shows and the playhead and canvas follow the player.
    private static func renderPlaying(
        store: ReviewDraftStore, draft: ReviewDraft, steps: [EditorScript.Step], to directory: URL
    ) throws -> URL {
        let model = try EditorModel(session: EditorSession(store: store, directory: draft.directory))
        offerWindowButtons(model)
        (steps + [.time(600)]).forEach { apply($0, to: model) }
        model.loadFilmstripNow(count: 16)
        model.togglePlayback()
        RunLoop.main.run(until: Date().addingTimeInterval(1.2))
        defer { model.pause() }
        return try snapshot(
            EditorView(model: model),
            size: CGSize(width: 1240, height: 800),
            to: directory.appendingPathComponent("editor-video-playing.png")
        )
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
}
