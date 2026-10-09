import AppKit
import UXReviewKit

extension EditorPreviews {
    /// HS2-JMCM6S: the canvas surround as rendered, sampled below the capture in
    /// `editor-annotated` (light) and `editor-annotated-dark`: RGB 0–255 (`editor-canvas-colors.json`).
    static func canvasColors(in directory: URL) throws -> URL {
        var result: [String: [Int]] = [:]
        for (key, name) in [("light", "editor-annotated"), ("dark", "editor-annotated-dark")] {
            let data = try Data(contentsOf: directory.appendingPathComponent("\(name).png"))
            guard let rep = NSBitmapImageRep(data: data), let color = rep.colorAt(x: 1120, y: 1520)?.usingColorSpace(.sRGB)
            else { throw CaptureFailure.failed("no pixel in \(name)") }
            result[key] = [color.redComponent, color.greenComponent, color.blueComponent].map { Int(($0 * 255).rounded()) }
        }
        let url = directory.appendingPathComponent("editor-canvas-colors.json")
        try JSONSerialization.data(withJSONObject: result, options: [.prettyPrinted, .sortedKeys]).write(to: url)
        return url
    }
}
