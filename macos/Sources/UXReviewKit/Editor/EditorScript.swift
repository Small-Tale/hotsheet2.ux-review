import CoreGraphics
import Foundation

/// A scripted editing session for `UXReview --annotate`: the same editor operations the window
/// performs, as JSON, so end-to-end tests can drive the real editor and save path without UI.
/// Points are media pixels (top-left origin). Spec: docs/06-annotation-editor.md §6.9.
///
///     {"steps": [
///       {"op": "media", "media": "m1"},
///       {"op": "tool", "tool": "rect"},
///       {"op": "drag", "points": [[40, 40], [200, 120]]},
///       {"op": "note", "text": "Label is clipped"},
///       {"op": "intent", "intent": "bug"},
///       {"op": "heads", "start": "flat", "end": "flat"},
///       {"op": "undo"}, {"op": "redo"}, {"op": "save"}
///     ]}
public struct EditorScript: Decodable, Equatable, Sendable {
    public enum Step: Equatable, Sendable {
        case media(String)
        case tool(EditorTool)
        /// Press at the first point, move through the rest, release (a click with one point).
        case drag([CGPoint])
        /// Like `drag`, but Esc before releasing.
        case cancelDrag([CGPoint])
        /// Return with a drawing tool: a default-sized shape at the point (default the media center).
        case insert(CGPoint?)
        /// Select by annotation id, or by its number in the review (`"#2"`); nil deselects.
        case select(String?)
        case note(String)
        /// A click on the selection's intent chip: plain (`single`) or ⌘ / ⇧ (`toggle`) (docs/06 §6.5).
        case intent(Intent, IntentToggle.Click)
        case closed(Bool)
        /// An arrow's heads; a missing end keeps its current head (`HS2-HQV9R8`).
        case heads(start: ArrowHead?, end: ArrowHead?)
        case delete
        case duplicate
        case nudge(dx: Double, dy: Double)
        case crop(CGRect)
        case resetCrop
        /// Restore Original: the current image's crop or the current video's trim.
        case restoreOriginal
        /// Moves the playhead to `millis` into the current video, as the scrubber does.
        case time(Int)
        /// ← / → on the canvas (`shift`: ⇧): a frame step of the last-used timeline target, or a
        /// nudge of the selection (docs/06 §6.4).
        case arrowKey(forward: Bool, shift: Bool)
        /// Plays the current video in real time for `millis`, then pauses; the playhead is where
        /// playback stopped.
        case play(Int)
        /// Presses a timeline handle, drags it through the times (ms), then releases (or, with
        /// `cancel`, presses Esc).
        case timelineDrag(TimelineHandle, [Int], cancel: Bool)
        /// Sets the selection's time range (ms); nil means the whole clip.
        case range(TimeRange?)
        /// Keeps `startMs`…`endMs` of the current video.
        case trim(TimeRange)
        case resetTrim
        /// Removes a capture from the draft the way the review session does
        /// (`ReviewDraftStore.removeMedia`), then lets the open editor catch up (docs/06 §6.7).
        case removeMedia(String)
        /// Remove from Review in the editor: saves the editor first, then removes the capture
        /// (`EditorSession.removeCapture`, docs/06 §6.7).
        case removeCapture(String)
        /// A click on a media strip thumbnail: plain, ⌘ (`toggle`), or ⇧ (`extend`) (docs/06 §6.7.2).
        case clickMedia(String, MediaSelection.Click)
        /// ⌘⌫: removes every selected capture without asking (`EditorSession.removeCaptures`).
        case removeSelectedCaptures
        case undo
        case redo
        case save
    }

    public var steps: [Step]

    public init(steps: [Step]) {
        self.steps = steps
    }

    public static func parse(_ data: Data) throws -> EditorScript {
        try JSONDecoder().decode(EditorScript.self, from: data)
    }
}

public enum EditorScriptError: Error, Equatable, CustomStringConvertible {
    case failed(step: Int, String)

    public var description: String {
        switch self {
        case let .failed(step, reason): "Step \(step + 1): \(reason)"
        }
    }
}

extension EditorScript.Step: Decodable {
    private enum CodingKeys: String,
        CodingKey { case op, media, tool, points, point, id, text, intent, closed, dx, dy, rect, start, end, handle, key, shift,
                     modifier
        case millis = "ms"
    }

    /// Ops that take no arguments.
    private static let bare: [String: EditorScript.Step] = [
        "delete": .delete, "duplicate": .duplicate, "reset-crop": .resetCrop, "restore-original": .restoreOriginal,
        "reset-trim": .resetTrim, "remove-selected-captures": .removeSelectedCaptures,
        "undo": .undo, "redo": .redo,
        "save": .save,
    ]

    /// The ops that name a `media` id.
    private static func mediaStep(_ op: String, in container: KeyedDecodingContainer<CodingKeys>) throws -> EditorScript.Step {
        let id = try container.decode(String.self, forKey: .media)
        switch op {
        case "media": return .media(id)
        case "remove-media": return .removeMedia(id)
        case "click-media": return try click(id, in: container)
        default: return .removeCapture(id)
        }
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let op = try container.decode(String.self, forKey: .op)
        if let step = Self.bare[op] {
            self = step
            return
        }
        func invalid(_ key: CodingKeys, _ reason: String) -> DecodingError {
            DecodingError.dataCorruptedError(forKey: key, in: container, debugDescription: reason)
        }
        switch op {
        case "media", "remove-media", "remove-capture", "click-media":
            self = try Self.mediaStep(op, in: container)
        case "tool":
            let name = try container.decode(String.self, forKey: .tool)
            guard let tool = EditorTool(rawValue: name) else { throw invalid(.tool, "Unknown tool \(name)") }
            self = .tool(tool)
        case "drag", "cancel-drag":
            let pairs = try container.decode([[Double]].self, forKey: .points)
            guard !pairs.isEmpty, pairs.allSatisfy({ $0.count == 2 }) else { throw invalid(.points, "points must be [[x, y], …]") }
            let points = pairs.map { CGPoint(x: $0[0], y: $0[1]) }
            self = op == "drag" ? .drag(points) : .cancelDrag(points)
        case "select": self = try .select(container.decodeIfPresent(String.self, forKey: .id))
        case "note": self = try .note(container.decode(String.self, forKey: .text))
        case "intent": self = try Self.intent(in: container)
        case "closed", "heads": self = try Self.outline(op, in: container)
        case "nudge": self = try .nudge(dx: container.decode(Double.self, forKey: .dx), dy: container.decode(Double.self, forKey: .dy))
        case "crop", "insert": self = try Self.geometry(op, in: container)
        case "time", "play", "timeline-drag", "cancel-timeline-drag", "arrow-key": self = try Self.playhead(op, in: container)
        case "range", "trim": self = try Self.timing(op, in: container)
        default:
            throw invalid(.op, "Unknown op \(op)")
        }
    }

    /// `click-media`: an optional `modifier` (`command` or `shift`) besides the `media` id.
    private static func click(_ id: String, in container: KeyedDecodingContainer<CodingKeys>) throws -> EditorScript.Step {
        switch try container.decodeIfPresent(String.self, forKey: .modifier) {
        case nil: return .clickMedia(id, .plain)
        case "command": return .clickMedia(id, .toggle)
        case "shift": return .clickMedia(id, .extend)
        case let other?:
            throw DecodingError.dataCorruptedError(
                forKey: .modifier,
                in: container,
                debugDescription: "Unknown modifier \(other) (command or shift)"
            )
        }
    }

    /// `intent`: an optional `modifier` (`command` or `shift`, both toggle) besides the `intent`.
    private static func intent(in container: KeyedDecodingContainer<CodingKeys>) throws -> EditorScript.Step {
        let intent = try container.decode(Intent.self, forKey: .intent)
        switch try container.decodeIfPresent(String.self, forKey: .modifier) {
        case nil: return .intent(intent, .single)
        case "command", "shift": return .intent(intent, .toggle)
        case let other?:
            throw DecodingError.dataCorruptedError(
                forKey: .modifier,
                in: container,
                debugDescription: "Unknown modifier \(other) (command or shift)"
            )
        }
    }

    /// `time` (the playhead) and `play` (how long to play, at most a minute), both in `ms`;
    /// `timeline-drag` / `cancel-timeline-drag` (a `handle` and a list of times in `ms`); and
    /// `arrow-key` (`key` left or right, optional `shift`).
    private static func playhead(_ op: String, in container: KeyedDecodingContainer<CodingKeys>) throws -> EditorScript.Step {
        if op == "arrow-key" {
            let key = try container.decode(String.self, forKey: .key)
            guard key == "left" || key == "right" else {
                throw DecodingError.dataCorruptedError(forKey: .key, in: container, debugDescription: "key must be left or right")
            }
            return try .arrowKey(forward: key == "right", shift: container.decodeIfPresent(Bool.self, forKey: .shift) ?? false)
        }
        if op.hasSuffix("timeline-drag") {
            let name = try container.decode(String.self, forKey: .handle)
            guard let handle = TimelineHandle(rawValue: name) else {
                throw DecodingError.dataCorruptedError(forKey: .handle, in: container, debugDescription: "Unknown handle \(name)")
            }
            let times = try container.decode([Int].self, forKey: .millis)
            guard !times.isEmpty else {
                throw DecodingError.dataCorruptedError(forKey: .millis, in: container, debugDescription: "timeline-drag needs ms: [t, …]")
            }
            return .timelineDrag(handle, times, cancel: op.hasPrefix("cancel"))
        }
        let millis = try container.decode(Int.self, forKey: .millis)
        guard op == "play" else { return .time(millis) }
        guard (0 ... 60000).contains(millis) else {
            throw DecodingError.dataCorruptedError(forKey: .millis, in: container, debugDescription: "play needs 0…60000 ms")
        }
        return .play(millis)
    }

    /// `closed` (a freehand outline) and `heads` (an arrow's, `start`, `end`, or both).
    private static func outline(_ op: String, in container: KeyedDecodingContainer<CodingKeys>) throws -> EditorScript.Step {
        if op == "closed" { return try .closed(container.decode(Bool.self, forKey: .closed)) }
        let start = try container.decodeIfPresent(ArrowHead.self, forKey: .start)
        let end = try container.decodeIfPresent(ArrowHead.self, forKey: .end)
        guard start != nil || end != nil else {
            throw DecodingError.dataCorruptedError(forKey: .start, in: container, debugDescription: "heads needs start, end, or both")
        }
        return .heads(start: start, end: end)
    }

    /// `range` (optional `start`/`end`, both or neither) and `trim` (`start` and `end`).
    private static func timing(_ op: String, in container: KeyedDecodingContainer<CodingKeys>) throws -> EditorScript.Step {
        let start = try container.decodeIfPresent(Int.self, forKey: .start)
        let end = try container.decodeIfPresent(Int.self, forKey: .end)
        guard let start, let end else {
            if op == "range", start == nil, end == nil { return .range(nil) }
            throw DecodingError.dataCorruptedError(
                forKey: start == nil ? .start : .end, in: container, debugDescription: "\(op) needs both start and end (ms)"
            )
        }
        return op == "range" ? .range(TimeRange(startMs: start, endMs: end)) : .trim(TimeRange(startMs: start, endMs: end))
    }

    /// `crop` (a rect) and `insert` (an optional point).
    private static func geometry(_ op: String, in container: KeyedDecodingContainer<CodingKeys>) throws -> EditorScript.Step {
        func invalid(_ key: CodingKeys, _ reason: String) -> DecodingError {
            DecodingError.dataCorruptedError(forKey: key, in: container, debugDescription: reason)
        }
        if op == "crop" {
            let values = try container.decode([Double].self, forKey: .rect)
            guard values.count == 4 else { throw invalid(.rect, "rect must be [x, y, width, height]") }
            return .crop(CGRect(x: values[0], y: values[1], width: values[2], height: values[3]))
        }
        let pair = try container.decodeIfPresent([Double].self, forKey: .point)
        return try .insert(pair.map { pair in
            guard pair.count == 2 else { throw invalid(.point, "point must be [x, y]") }
            return CGPoint(x: pair[0], y: pair[1])
        })
    }
}

public extension EditorScript {
    /// Runs every step on `session`, then saves. Steps that need something missing (an unknown
    /// media id, no selection) fail with the step number. Returns the editor's status messages.
    @discardableResult
    func run(on session: EditorSession) throws -> [String] {
        var messages: [String] = []
        for (index, step) in steps.enumerated() {
            do {
                try Self.apply(step, to: session)
            } catch let StepFailure.reason(reason) {
                throw EditorScriptError.failed(step: index, reason)
            }
            if let message = session.editor.message, messages.last != message { messages.append(message) }
        }
        try session.save()
        return messages
    }

    private enum StepFailure: Error { case reason(String) }

    private static func apply(_ step: Step, to session: EditorSession) throws {
        switch step {
        case .media, .removeMedia, .removeCapture, .clickMedia, .removeSelectedCaptures:
            try applyMediaStep(step, in: session)
        case let .tool(tool):
            session.editor.setTool(tool)
        case .drag, .cancelDrag, .insert:
            try draw(step, in: session)
        case let .select(reference):
            guard let reference else { return session.editor.select(nil) }
            guard let id = resolve(reference, in: session.editor) else { throw StepFailure.reason("unknown annotation \(reference)") }
            session.editor.select(id)
        case .note, .intent, .closed, .heads, .delete, .duplicate, .nudge, .range:
            try applyToSelection(step, in: session)
        case let .crop(rect): session.editor.crop(to: rect)
        case .resetCrop, .restoreOriginal, .time, .play, .timelineDrag, .trim, .resetTrim, .arrowKey:
            try applyToMedia(step, in: session)
        case .undo: session.editor.undo()
        case .redo: session.editor.redo()
        case .save: try session.save()
        }
    }

    /// Showing a capture, or removing one (as the review session does, or from the editor).
    private static func applyMediaStep(_ step: Step, in session: EditorSession) throws {
        switch step {
        case let .media(id), let .removeMedia(id), let .removeCapture(id):
            guard session.editor.media(id) != nil else { throw StepFailure.reason("unknown media \(id)") }
            switch step {
            case .removeMedia:
                try session.store.removeMedia(id, from: session.directory)
                try session.reload()
            case .removeCapture: try session.removeCapture(id)
            default: session.editor.show(mediaId: id)
            }
        case let .clickMedia(id, click):
            guard session.editor.media(id) != nil else { throw StepFailure.reason("unknown media \(id)") }
            session.editor.clickMedia(id, click)
        case .removeSelectedCaptures:
            let ids = session.editor.mediaToRemove()
            guard !ids.isEmpty else { throw StepFailure.reason("no capture to remove") }
            try session.removeCaptures(ids)
        default: return
        }
    }

    /// How long a `play` step waits for the player to start moving before it gives up waiting.
    static let playStartTimeoutSeconds = 5.0

    /// Crop/trim resets, video time, and ← / → on the current media.
    private static func applyToMedia(_ step: Step, in session: EditorSession) throws {
        switch step {
        case .resetCrop: session.editor.resetCrop()
        case .restoreOriginal: session.editor.restoreOriginal()
        case let .time(millis):
            guard session.editor.currentDurationMs != nil else { throw StepFailure.reason("the current media is not a video") }
            session.editor.movePlayhead(to: millis)
        case let .timelineDrag(handle, times, cancel):
            guard session.editor.currentDurationMs != nil else { throw StepFailure.reason("the current media is not a video") }
            guard session.editor.beginTimelineDrag(handle) else { throw StepFailure.reason("no selected time range to drag") }
            times.forEach { session.editor.updateTimelineDrag(toMs: $0) }
            if cancel { session.editor.cancelTimelineDrag() } else { session.editor.endTimelineDrag() }
        case let .play(millis): try play(for: millis, in: session)
        case let .trim(range): session.editor.trim(to: range)
        case .resetTrim: session.editor.resetTrim()
        case let .arrowKey(forward, shift):
            // Like the key itself: a press that changes nothing (at a clip edge, on an image) is fine.
            session.editor.arrowKey(forward: forward, large: shift)
        default: break
        }
    }

    /// Plays the current video for `millis` of real time, then pauses there.
    private static func play(for millis: Int, in session: EditorSession) throws {
        guard let id = session.editor.currentMediaId, let playback = session.playback(id) else {
            throw StepFailure.reason("the current media is not a video")
        }
        playback.play(fromMs: session.editor.currentTimeMs)
        // Count the step's time from when the player actually starts moving, not from the
        // call: under heavy load the seek and first frames can eat most of a short step
        // (HS2-5J2SGB). A player that never starts falls through and leaves the playhead put.
        let startBy = Date().addingTimeInterval(playStartTimeoutSeconds)
        while Date() < startBy, playback.isPlaying, !playback.isAdvancing {
            RunLoop.current.run(until: min(startBy, Date().addingTimeInterval(0.01)))
        }
        let deadline = Date().addingTimeInterval(Double(millis) / 1000)
        while Date() < deadline, playback.isPlaying {
            RunLoop.current.run(until: min(deadline, Date().addingTimeInterval(0.01)))
        }
        session.editor.setCurrentTime(playback.pause())
    }

    /// Pointer drags and keyboard inserts.
    private static func draw(_ step: Step, in session: EditorSession) throws {
        guard session.editor.currentMedia != nil else { throw StepFailure.reason("no media to draw on") }
        switch step {
        case let .drag(points), let .cancelDrag(points):
            session.editor.beginGesture(at: points[0])
            points.dropFirst().forEach { session.editor.updateGesture(to: $0) }
            if case .cancelDrag = step { session.editor.cancelGesture() } else { session.editor.endGesture() }
        case let .insert(point):
            guard session.editor.insertDefaultShape(at: point) else { throw StepFailure.reason("choose a drawing tool before insert") }
        default:
            break
        }
    }

    /// Steps that act on the selected annotation.
    private static func applyToSelection(_ step: Step, in session: EditorSession) throws {
        guard let id = session.editor.selection else { throw StepFailure.reason("nothing selected") }
        switch step {
        case let .note(text): session.editor.setNote(text, for: id)
        case let .intent(intent, click): session.editor.clickIntent(intent, click, for: id)
        case let .closed(closed): session.editor.setClosed(closed, for: id)
        case let .heads(start, end):
            guard case let .arrow(_, current)? = session.editor.annotation(id)?.shape else {
                throw StepFailure.reason("heads apply to arrows")
            }
            session.editor.setArrowHeads(ArrowHeads(start: start ?? current.start, end: end ?? current.end), for: id)
        case .delete: session.editor.deleteSelection()
        case .duplicate: session.editor.duplicateSelection()
        case let .nudge(dx, dy): session.editor.nudgeSelection(dx: dx, dy: dy)
        case let .range(range):
            guard session.editor.media(session.editor.annotation(id)?.mediaId ?? "")?.kind == .video else {
                throw StepFailure.reason("time ranges apply to annotations on videos")
            }
            session.editor.setTimeRange(range, for: id)
        default: break
        }
    }

    private static func resolve(_ reference: String, in editor: AnnotationEditor) -> String? {
        if reference.hasPrefix("#"), let number = Int(reference.dropFirst()), editor.bundle.annotations.indices.contains(number - 1) {
            return editor.bundle.annotations[number - 1].id
        }
        return editor.annotation(reference)?.id
    }
}

/// `UXReview --annotate SCRIPT.json [--drafts-dir DIR] [--draft NAME] [--render-dir DIR]`:
/// runs an `EditorScript` on a draft (the current one unless `--draft` names a draft
/// directory) and optionally writes each media item with its annotations drawn on as PNGs.
public struct AnnotateCommand: Equatable, Sendable {
    public var script: URL
    public var draftsDirectory: URL?
    public var draft: String?
    public var renderDirectory: URL?

    public static func parse(_ arguments: [String]) throws -> AnnotateCommand? {
        guard let index = arguments.firstIndex(of: "--annotate") else { return nil }
        let values = ArgumentValues(arguments)
        let script = try URL(fileURLWithPath: values.value(after: index, flag: "--annotate"))
        let draft = try values.optional("--draft")
        if let draft, draft.isEmpty || draft.contains("/") || draft.hasPrefix(".") {
            throw CommandLineError.invalidValue("--draft", draft)
        }
        return try AnnotateCommand(
            script: script,
            draftsDirectory: values.optional("--drafts-dir").map { URL(fileURLWithPath: $0, isDirectory: true) },
            draft: draft,
            renderDirectory: values.optional("--render-dir").map { URL(fileURLWithPath: $0, isDirectory: true) }
        )
    }
}
