import Foundation

/// Contrast of the intent colors on the inspector's intent chips (`HS2-0CZ5RR`, docs/06 §6.5).
/// The colors stay the same everywhere (they mark annotations on the canvas), so a dot that is
/// too faint on a chip gets an outline ring instead of a new color.
public extension IntentPalette {
    /// The chip's appearance, with the gray levels (sRGB) its dot sits on and its ring uses.
    enum ChipAppearance: CaseIterable, Sendable {
        case light, dark

        /// An unselected chip: a faint primary tint over the window background.
        public var chipGray: Double { self == .light ? 0.95 : 0.20 }
        /// The ring drawn around a dot that is too faint on the chip.
        public var outlineGray: Double { self == .light ? 0.45 : 0.75 }
    }

    /// WCAG 2 non-text contrast minimum for a meaningful graphic.
    static let minimumGraphicContrast = 3.0

    /// WCAG 2 relative luminance of an sRGB color.
    static func relativeLuminance(red: Double, green: Double, blue: Double) -> Double {
        func linear(_ channel: Double) -> Double {
            channel <= 0.04045 ? channel / 12.92 : pow((channel + 0.055) / 1.055, 2.4)
        }
        return 0.2126 * linear(red) + 0.7152 * linear(green) + 0.0722 * linear(blue)
    }

    /// WCAG 2 contrast ratio between two luminances (1 to 21).
    static func contrastRatio(_ first: Double, _ second: Double) -> Double {
        (max(first, second) + 0.05) / (min(first, second) + 0.05)
    }

    /// The intent's color against a chip in `appearance`.
    static func chipContrast(_ intent: Intent, on appearance: ChipAppearance) -> Double {
        let rgb = rgb(intent)
        let gray = appearance.chipGray
        return contrastRatio(
            relativeLuminance(red: rgb.red, green: rgb.green, blue: rgb.blue),
            relativeLuminance(red: gray, green: gray, blue: gray)
        )
    }

    /// True when the intent's dot is below 3:1 on the chip and needs its outline ring.
    static func dotNeedsOutline(_ intent: Intent, on appearance: ChipAppearance) -> Bool {
        chipContrast(intent, on: appearance) < minimumGraphicContrast
    }

    /// The ring's own contrast against the chip.
    static func outlineContrast(on appearance: ChipAppearance) -> Double {
        let ring = appearance.outlineGray, chip = appearance.chipGray
        return contrastRatio(
            relativeLuminance(red: ring, green: ring, blue: ring),
            relativeLuminance(red: chip, green: chip, blue: chip)
        )
    }
}
