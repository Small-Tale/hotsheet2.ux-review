import AppKit
import UXReviewKit

/// The Crop tool's preview states (docs/06 §6.6).
extension EditorPreviews {
    /// The Crop tool states: name, script steps after the annotations, and a press still held.
    static var cropStates: [(String, [EditorScript.Step], [CGPoint])] {
        let crop = CGRect(x: 220, y: 90, width: 1180, height: 560)
        return [
            ("editor-crop-drag", [.tool(.crop)], [CGPoint(x: 220, y: 90), CGPoint(x: 1400, y: 650)]),
            ("editor-crop-tool", [.tool(.crop), .crop(crop)], []),
            ("editor-crop-adjust", [.tool(.crop), .crop(crop)], [CGPoint(x: 1400, y: 370), CGPoint(x: 1530, y: 400)]),
            ("editor-cropped", [.tool(.crop), .crop(crop), .tool(.select)], []),
        ]
    }

    /// The part of the mock recording the video crop previews keep.
    static let videoCrop = CGRect(x: 200, y: 150, width: 1000, height: 600)

    /// A gesture still in progress: pressed at the first point, dragged through the rest.
    static func hold(_ points: [CGPoint], in model: EditorModel) {
        guard let first = points.first else { return }
        model.mutate { editor in
            editor.hitTolerance = 7
            editor.beginGesture(at: first)
            points.dropFirst().forEach { editor.updateGesture(to: $0) }
        }
    }
}
