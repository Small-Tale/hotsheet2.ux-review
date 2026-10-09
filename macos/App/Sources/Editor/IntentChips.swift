import AppKit
import SwiftUI
import UXReviewKit

/// An intent chip's mark (`HS2-0CZ5RR`): a dot in the intent's color when off, a filled check
/// circle when on, so the state never rests on color alone. Both take the same space, so choosing
/// an intent doesn't reflow the chips. A dot too faint on the chip (below 3:1, such as yellow on
/// a light chip) gets an outline ring.
struct IntentMark: View {
    let intent: Intent
    let isOn: Bool
    let appearance: IntentPalette.ChipAppearance

    var body: some View {
        let color = Color(cgColor: IntentPalette.color(intent))
        Group {
            if isOn {
                Image(systemName: "checkmark.circle.fill")
                    .resizable()
                    .symbolRenderingMode(.palette)
                    .foregroundStyle(IntentPalette.usesDarkText(intent) ? Color.black : Color.white, color)
            } else {
                Circle()
                    .fill(color)
                    .overlay(
                        Circle().strokeBorder(
                            Color(white: appearance.outlineGray),
                            lineWidth: IntentPalette.dotNeedsOutline(intent, on: appearance) ? 1 : 0
                        )
                    )
                    .padding(2)
            }
        }
        .frame(width: 13, height: 13)
        .accessibilityHidden(true)
    }
}

/// One chip per intent. Effective intents are on; when the list is empty the shape's default
/// shows as on with a "default" hint. A click selects just that intent; ⌘- or ⇧-click toggles it
/// into a multiple selection (`IntentToggle.Click`, docs/06 §6.5). VoiceOver gets the toggle as a
/// named action, since it can't hold a modifier.
struct IntentChips: View {
    let annotation: Annotation
    let click: (Intent, IntentToggle.Click) -> Void
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        let effective = Set(annotation.effectiveIntents)
        FlowLayout(spacing: 6) {
            ForEach(Intent.allCases, id: \.self) { intent in
                let isOn = effective.contains(intent)
                Button { click(intent, Self.click(NSEvent.modifierFlags)) } label: {
                    HStack(spacing: 4) {
                        IntentMark(intent: intent, isOn: isOn, appearance: scheme == .dark ? .dark : .light)
                        Text(intent.rawValue)
                        if isOn, annotation.intents.isEmpty {
                            Text("default").font(.caption2).foregroundStyle(.secondary)
                        }
                    }
                    .font(.callout)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 3)
                    // Circular, not continuous: a continuous capsule this short draws flat ticks
                    // past its ends.
                    .background(
                        Capsule(style: .circular)
                            .fill(isOn ? Color(cgColor: IntentPalette.color(intent, alpha: 0.22)) : Color.primary.opacity(0.05))
                    )
                    .overlay(
                        Capsule(style: .circular).strokeBorder(
                            isOn ? Color(cgColor: IntentPalette.color(intent)) : Color.primary.opacity(0.15), lineWidth: isOn ? 1.5 : 1
                        )
                    )
                }
                .buttonStyle(.plain)
                .help("\(intent.help). ⌘-click to add or remove it alongside other intents.")
                .accessibilityAddTraits(isOn ? .isSelected : [])
                .accessibilityAction(named: isOn ? "Remove from intents" : "Add to intents") { click(intent, .toggle) }
            }
        }
    }

    /// ⌘ or ⇧ held: toggle into a multiple selection; otherwise select just this intent.
    static func click(_ flags: NSEvent.ModifierFlags) -> IntentToggle.Click {
        IntentToggle.Click(command: flags.contains(.command), shift: flags.contains(.shift))
    }
}
