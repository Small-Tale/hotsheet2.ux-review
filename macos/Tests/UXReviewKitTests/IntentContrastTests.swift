import Foundation
import Testing
@testable import UXReviewKit

/// HS2-0CZ5RR: intent chip dots meet 3:1 against the chip, with an outline ring where the color
/// alone doesn't.
struct IntentContrastTests {
    @Test func luminanceAndContrastFollowWCAG() {
        #expect(IntentPalette.relativeLuminance(red: 1, green: 1, blue: 1) == 1)
        #expect(IntentPalette.relativeLuminance(red: 0, green: 0, blue: 0) == 0)
        #expect(abs(IntentPalette.contrastRatio(1, 0) - 21) < 0.0001)
        #expect(IntentPalette.contrastRatio(0.4, 0.4) == 1)
        // Order doesn't matter.
        #expect(IntentPalette.contrastRatio(0.1, 0.6) == IntentPalette.contrastRatio(0.6, 0.1))
    }

    @Test func lightIntentsGetARingOnLightChips() {
        let ringed = Intent.allCases.filter { IntentPalette.dotNeedsOutline($0, on: .light) }
        #expect(Set(ringed) == [.change, .insert, .move, .question])
        // The yellow question dot is the faintest.
        #expect(IntentPalette.chipContrast(.question, on: .light) < 1.5)
    }

    @Test func everyDotStandsOutOnDarkChips() {
        for intent in Intent.allCases {
            #expect(!IntentPalette.dotNeedsOutline(intent, on: .dark), "\(intent)")
        }
    }

    @Test func everyDotOrItsRingMeetsThreeToOne() {
        for appearance in IntentPalette.ChipAppearance.allCases {
            #expect(IntentPalette.outlineContrast(on: appearance) >= IntentPalette.minimumGraphicContrast)
            for intent in Intent.allCases {
                let visible = IntentPalette.dotNeedsOutline(intent, on: appearance)
                    ? IntentPalette.outlineContrast(on: appearance)
                    : IntentPalette.chipContrast(intent, on: appearance)
                #expect(visible >= IntentPalette.minimumGraphicContrast, "\(intent) on \(appearance)")
            }
        }
    }
}
