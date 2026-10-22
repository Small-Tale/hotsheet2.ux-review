import AppKit
import UXReviewKit

extension EditorPreviews {
    /// Isolated native accessibility contract checks, without desktop events or AX permission.
    static func sidebarAccessibility(to directory: URL) throws -> URL {
        var requested: CGFloat = MediaStripWidth.standard
        let view = StripDividerAccessibilityView(width: requested) { requested = $0 }
        view.frame = NSRect(x: 0, y: 0, width: 9, height: 600)
        let initial = view.accessibilityValue() as? String ?? ""
        var values: [String] = []
        var requests: [Double] = []
        var performed: [Bool] = []
        func action(increment: Bool) {
            performed.append(increment ? view.accessibilityPerformIncrement() : view.accessibilityPerformDecrement())
            view.width = requested // The same update delivered by the SwiftUI bridge.
            requests.append(Double(requested))
            values.append(view.accessibilityValue() as? String ?? "")
        }
        action(increment: true)
        action(increment: false)
        view.width = 96
        action(increment: false)
        view.width = 320
        action(increment: true)
        view.width = 178
        action(increment: false)
        view.width = 112
        action(increment: true)
        let report: [String: Any] = [
            "role": view.accessibilityRole()?.rawValue ?? "",
            "enabled": view.isAccessibilityEnabled(),
            "label": view.accessibilityLabel() ?? "",
            "identifier": view.accessibilityIdentifier(),
            "minimum": view.accessibilityMinValue() as? CGFloat ?? -1,
            "maximum": view.accessibilityMaxValue() as? CGFloat ?? -1,
            "initial": initial, "requests": requests, "values": values, "performed": performed,
            "pointerPassesThrough": view.hitTest(NSPoint(x: 4, y: 300)) == nil,
        ]
        let url = directory.appendingPathComponent("editor-sidebar-accessibility.json")
        try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys]).write(to: url)
        return url
    }
}
