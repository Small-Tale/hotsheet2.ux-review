import AppKit

/// The canvas's colors in one appearance (`HS2-JMCM6S`, docs/06 §6.1): a calm neutral around the
/// capture, light gray in light mode and near-black in dark mode, as in Preview; a shadow and
/// hairline that keep a white screenshot's edge visible on it; and the backing under transparent
/// pixels. (`underPageBackgroundColor` is near white in light mode, too close to the sidebar,
/// the inspector, and white screenshots.)
struct CanvasColors {
    let surround: CGColor
    let shadow: CGColor
    let mediaBorder: CGColor
    let mediaBacking: CGColor

    init(appearance: NSAppearance) {
        var colors: (CGColor, CGColor, CGColor, CGColor) = (.black, .black, .black, .black)
        appearance.performAsCurrentDrawingAppearance {
            let dark = appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
            colors = (
                CGColor(gray: dark ? 0.13 : 0.88, alpha: 1),
                CGColor(gray: 0, alpha: dark ? 0.5 : 0.22),
                NSColor.separatorColor.cgColor,
                NSColor.textBackgroundColor.cgColor
            )
        }
        (surround, shadow, mediaBorder, mediaBacking) = colors
    }
}

extension AnnotationCanvasView {
    /// Centered text on the empty canvas (no media, or a file that can't be read).
    func drawPlaceholder(_ text: String) {
        let paragraph = NSMutableParagraphStyle()
        paragraph.alignment = .center
        paragraph.lineSpacing = 4
        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 14),
            .foregroundColor: NSColor.secondaryLabelColor,
            .paragraphStyle: paragraph,
        ]
        let string = NSAttributedString(string: text, attributes: attributes)
        let size = string.size()
        string.draw(in: CGRect(x: bounds.midX - size.width / 2, y: bounds.midY - size.height / 2, width: size.width, height: size.height))
    }
}
