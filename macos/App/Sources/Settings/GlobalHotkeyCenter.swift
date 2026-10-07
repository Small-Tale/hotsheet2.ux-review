import Carbon.HIToolbox
import UXReviewKit

/// Registers system-wide hotkeys with Carbon (`RegisterEventHotKey`), the API macOS still uses
/// for global shortcuts: one per `HotkeySlot`, told apart by `EventHotKeyID.id`. Registration is
/// exclusive, so a combination another app already owns is reported as in use instead of
/// silently doing nothing. Spec: docs/05 §5.2.
@MainActor
final class GlobalHotkeyCenter {
    enum Registration: Equatable {
        case disabled
        case registered(Hotkey)
        case inUse(Hotkey)
        case invalid(Hotkey, String)
        case failed(Hotkey, Int32)

        var code: String {
            switch self {
            case .disabled: "disabled"
            case .registered: "registered"
            case .inUse: "inUse"
            case .invalid: "invalid"
            case .failed: "failed"
            }
        }

        func message(for slot: HotkeySlot) -> String {
            switch self {
            case .disabled: "No global shortcut."
            case let .registered(hotkey):
                switch slot {
                case .capture: "\(hotkey.display) starts a capture from any app."
                case .record: "\(hotkey.display) records a video from any app."
                }
            case let .inUse(hotkey): "\(hotkey.display) is already used by another app. Choose a different shortcut."
            case let .invalid(_, problem): problem
            case let .failed(hotkey, status): "\(hotkey.display) could not be registered (error \(status))."
            }
        }
    }

    /// 'UXRV'.
    nonisolated static let signature: OSType = 0x5558_5256

    var onPress: (@MainActor (HotkeySlot) -> Void)?
    private var hotKeyRefs: [HotkeySlot: EventHotKeyRef] = [:]
    private var handlerRef: EventHandlerRef?

    /// Registers every slot from `settings`. A slot whose hotkey repeats an earlier slot's is
    /// reported invalid rather than registered twice.
    func register(_ settings: CaptureSettings) -> [HotkeySlot: Registration] {
        var result: [HotkeySlot: Registration] = [:]
        for slot in HotkeySlot.allCases {
            result[slot] = if let hotkey = settings[slot], settings.registrable(slot) == nil {
                .invalid(hotkey, settings.problem(with: hotkey, for: slot) ?? "Duplicate shortcut.")
            } else {
                register(settings[slot], for: slot)
            }
        }
        return result
    }

    /// Replaces the slot's current registration. Pass nil to disable it.
    @discardableResult
    func register(_ hotkey: Hotkey?, for slot: HotkeySlot) -> Registration {
        unregister(slot)
        guard let hotkey else { return .disabled }
        if let problem = hotkey.problem { return .invalid(hotkey, problem) }
        installHandlerIfNeeded()
        var ref: EventHotKeyRef?
        let status = RegisterEventHotKey(
            hotkey.keyCode, hotkey.carbonModifiers, EventHotKeyID(signature: Self.signature, id: slot.carbonID),
            GetApplicationEventTarget(), OptionBits(kEventHotKeyExclusive), &ref
        )
        switch status {
        case noErr:
            hotKeyRefs[slot] = ref
            return .registered(hotkey)
        case OSStatus(eventHotKeyExistsErr):
            return .inUse(hotkey)
        default:
            return .failed(hotkey, status)
        }
    }

    func unregister(_ slot: HotkeySlot) {
        if let ref = hotKeyRefs.removeValue(forKey: slot) { UnregisterEventHotKey(ref) }
    }

    func unregister() {
        HotkeySlot.allCases.forEach(unregister)
    }

    private func installHandlerIfNeeded() {
        guard handlerRef == nil else { return }
        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        InstallEventHandler(GetApplicationEventTarget(), { _, event, userData in
            guard let userData, let event else { return OSStatus(eventNotHandledErr) }
            var id = EventHotKeyID()
            let status = GetEventParameter(
                event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID), nil,
                MemoryLayout<EventHotKeyID>.size, nil, &id
            )
            guard status == noErr, id.signature == GlobalHotkeyCenter.signature, let slot = HotkeySlot(carbonID: id.id) else {
                return OSStatus(eventNotHandledErr)
            }
            let center = Unmanaged<GlobalHotkeyCenter>.fromOpaque(userData).takeUnretainedValue()
            MainActor.assumeIsolated { center.onPress?(slot) }
            return noErr
        }, 1, &spec, Unmanaged.passUnretained(self).toOpaque(), &handlerRef)
    }
}
