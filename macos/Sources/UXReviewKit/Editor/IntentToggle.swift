import Foundation

/// Intent chip clicks (`HS2-JMPDDW`). The editor shows an annotation's *effective* intents (an
/// empty list means the shape's default), so clicks work on that set:
/// - a plain click (`single`) makes the clicked intent the only one;
/// - a ⌘- or ⇧-click (`toggle`) adds or removes the intent from the effective set;
/// - a result equal to just the default intent, or an empty result, is stored as `[]`, so the
///   last intent can't be removed (it falls back to the default) and clicking the only one again
///   changes nothing;
/// - otherwise intents are stored in canonical `Intent.allCases` order.
/// Spec: docs/06 §6.5.
public enum IntentToggle {
    /// How an intent chip was clicked.
    public enum Click: String, CaseIterable, Equatable, Sendable {
        /// A plain click (also Space on a focused chip, or VoiceOver's press): just this intent.
        case single
        /// ⌘- or ⇧-click: add it to the selection, or take it out.
        case toggle

        /// The click for the modifier keys held: ⌘ or ⇧ toggles, anything else selects one.
        public init(command: Bool, shift: Bool) {
            self = command || shift ? .toggle : .single
        }
    }

    public static func clicked(_ intents: [Intent], _ intent: Intent, _ click: Click, shape: Shape) -> [Intent] {
        switch click {
        case .single: intent == shape.defaultIntent ? [] : [intent]
        case .toggle: toggled(intents, intent, shape: shape)
        }
    }

    public static func toggled(_ intents: [Intent], _ intent: Intent, shape: Shape) -> [Intent] {
        var effective = Set(intents.isEmpty ? [shape.defaultIntent] : intents)
        if effective.contains(intent) { effective.remove(intent) } else { effective.insert(intent) }
        if effective.isEmpty || effective == [shape.defaultIntent] { return [] }
        return Intent.allCases.filter(effective.contains)
    }
}
