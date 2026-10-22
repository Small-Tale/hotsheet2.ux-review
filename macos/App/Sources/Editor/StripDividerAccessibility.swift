import AppKit
import SwiftUI
import UXReviewKit

/// The divider's semantic surface. It draws nothing and lets pointer events reach the
/// existing SwiftUI drag/reset target, while exposing an actual macOS slider value/actions.
struct StripDividerAccessibility: NSViewRepresentable {
    let width: CGFloat
    let set: (CGFloat) -> Void

    func makeNSView(context _: Context) -> StripDividerAccessibilityView {
        StripDividerAccessibilityView(width: width, set: set)
    }

    func updateNSView(_ view: StripDividerAccessibilityView, context _: Context) {
        view.setWidth = set
        if view.width != width {
            view.width = width
            NSAccessibility.post(element: view, notification: .valueChanged)
        }
    }
}

final class StripDividerAccessibilityView: NSView {
    var width: CGFloat
    var setWidth: (CGFloat) -> Void

    init(width: CGFloat, set: @escaping (CGFloat) -> Void) {
        self.width = width
        setWidth = set
        super.init(frame: .zero)
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) { nil }

    override func hitTest(_: NSPoint) -> NSView? { nil }
    override func isAccessibilityElement() -> Bool { true }
    override func isAccessibilityEnabled() -> Bool { true }
    override func accessibilityRole() -> NSAccessibility.Role? { .slider }
    override func accessibilityLabel() -> String? { "Capture sidebar width" }
    override func accessibilityIdentifier() -> String { "editor-strip-divider" }
    override func accessibilityValue() -> Any? { "\(Int(width)) points" }
    override func accessibilityValueDescription() -> String? { "\(Int(width)) points" }
    override func accessibilityMinValue() -> Any? { MediaStripWidth.minimum }
    override func accessibilityMaxValue() -> Any? { MediaStripWidth.maximum }

    override func accessibilityPerformIncrement() -> Bool {
        setWidth(MediaStripWidth.dragged(from: width, by: 16))
        return true
    }

    override func accessibilityPerformDecrement() -> Bool {
        setWidth(MediaStripWidth.dragged(from: width, by: -16))
        return true
    }
}
