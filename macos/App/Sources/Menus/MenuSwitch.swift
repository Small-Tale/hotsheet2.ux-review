import AppKit

/// The on/off switch in a menu row (`HS2-FXZSA4`). An `NSSwitch` in a menu draws its "on" track
/// gray, because a menu's window is never key, so it looked off. This draws the system switch's
/// shape itself, with the accent color when on, like Control Center's switches. A click flips it
/// and sends `action`; VoiceOver gets a switch with its state.
final class MenuSwitch: NSControl {
    static let size = CGSize(width: 32, height: 18)

    var isOn: Bool {
        didSet {
            needsDisplay = true
            setAccessibilityValue(isOn ? 1 : 0)
        }
    }

    init(isOn: Bool) {
        self.isOn = isOn
        super.init(frame: CGRect(origin: .zero, size: Self.size))
        setAccessibilityElement(true)
        setAccessibilityRole(.checkBox)
        setAccessibilitySubrole(.switch)
        setAccessibilityValue(isOn ? 1 : 0)
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) { fatalError("not used") }

    override var intrinsicContentSize: NSSize { Self.size }

    /// The track's color: the accent color when on, a neutral gray when off.
    var trackColor: NSColor { isOn ? .controlAccentColor : .quaternaryLabelColor }

    override func draw(_: NSRect) {
        let track = bounds.insetBy(dx: 0.5, dy: 0.5)
        trackColor.setFill()
        NSBezierPath(roundedRect: track, xRadius: track.height / 2, yRadius: track.height / 2).fill()
        let inset: CGFloat = 2
        let diameter = track.height - inset * 2
        let x = isOn ? track.maxX - inset - diameter : track.minX + inset
        let knob = CGRect(x: x, y: track.minY + inset, width: diameter, height: diameter)
        NSGraphicsContext.saveGraphicsState()
        let shadow = NSShadow()
        shadow.shadowColor = NSColor.black.withAlphaComponent(0.25)
        shadow.shadowBlurRadius = 1.5
        shadow.shadowOffset = NSSize(width: 0, height: -0.5)
        shadow.set()
        NSColor.white.setFill()
        NSBezierPath(ovalIn: knob).fill()
        NSGraphicsContext.restoreGraphicsState()
    }

    override func mouseDown(with _: NSEvent) {}

    override func mouseUp(with event: NSEvent) {
        guard bounds.contains(convert(event.locationInWindow, from: nil)) else { return }
        flip()
    }

    /// Flips the switch and sends its action, as a click does.
    func flip() {
        isOn.toggle()
        if let action { NSApp.sendAction(action, to: target, from: self) }
    }

    override func accessibilityPerformPress() -> Bool {
        flip()
        return true
    }
}
