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
        /// Select by annotation id, or by its number in the review (`"#2"`); nil deselects.
        case select(String?)
        case note(String)
        case intent(Intent)
        case closed(Bool)
        case delete
        case duplicate
        case nudge(dx: Double, dy: Double)
        case crop(CGRect)
        case resetCrop
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
    private enum CodingKeys: String, CodingKey { case op, media, tool, points, id, text, intent, closed, dx, dy, rect }

    /// Ops that take no arguments.
    private static let bare: [String: EditorScript.Step] = [
        "delete": .delete, "duplicate": .duplicate, "reset-crop": .resetCrop, "undo": .undo, "redo": .redo, "save": .save,
    ]

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
        case "media": self = try .media(container.decode(String.self, forKey: .media))
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
        case "intent": self = try .intent(container.decode(Intent.self, forKey: .intent))
        case "closed": self = try .closed(container.decode(Bool.self, forKey: .closed))
        case "nudge": self = try .nudge(dx: container.decode(Double.self, forKey: .dx), dy: container.decode(Double.self, forKey: .dy))
        case "crop":
            let values = try container.decode([Double].self, forKey: .rect)
            guard values.count == 4 else { throw invalid(.rect, "rect must be [x, y, width, height]") }
            self = .crop(CGRect(x: values[0], y: values[1], width: values[2], height: values[3]))
        default:
            throw invalid(.op, "Unknown op \(op)")
        }
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
        case let .media(id):
            guard session.editor.media(id) != nil else { throw StepFailure.reason("unknown media \(id)") }
            session.editor.show(mediaId: id)
        case let .tool(tool):
            session.editor.setTool(tool)
        case let .drag(points), let .cancelDrag(points):
            guard session.editor.currentMedia != nil else { throw StepFailure.reason("no media to draw on") }
            session.editor.beginGesture(at: points[0])
            points.dropFirst().forEach { session.editor.updateGesture(to: $0) }
            if case .cancelDrag = step { session.editor.cancelGesture() } else { session.editor.endGesture() }
        case let .select(reference):
            guard let reference else { return session.editor.select(nil) }
            guard let id = resolve(reference, in: session.editor) else { throw StepFailure.reason("unknown annotation \(reference)") }
            session.editor.select(id)
        case .note, .intent, .closed, .delete, .duplicate, .nudge:
            try applyToSelection(step, in: session)
        case let .crop(rect): session.editor.crop(to: rect)
        case .resetCrop: session.editor.resetCrop()
        case .undo: session.editor.undo()
        case .redo: session.editor.redo()
        case .save: try session.save()
        }
    }

    /// Steps that act on the selected annotation.
    private static func applyToSelection(_ step: Step, in session: EditorSession) throws {
        guard let id = session.editor.selection else { throw StepFailure.reason("nothing selected") }
        switch step {
        case let .note(text): session.editor.setNote(text, for: id)
        case let .intent(intent): session.editor.toggleIntent(intent, for: id)
        case let .closed(closed): session.editor.setClosed(closed, for: id)
        case .delete: session.editor.deleteSelection()
        case .duplicate: session.editor.duplicateSelection()
        case let .nudge(dx, dy): session.editor.nudgeSelection(dx: dx, dy: dy)
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
