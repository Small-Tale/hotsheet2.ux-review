import Carbon.HIToolbox
import UXReviewKit

/// Registers one system-wide hotkey with Carbon (`RegisterEventHotKey`), the API macOS still
/// uses for global shortcuts. Registration is exclusive, so a combination another app already
/// owns is reported as in use instead of silently doing nothing. Spec: docs/05 §5.2.
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

        var message: String {
            switch self {
            case .disabled: "No global shortcut."
            case let .registered(hotkey): "\(hotkey.display) starts a capture from any app."
            case let .inUse(hotkey): "\(hotkey.display) is already used by another app. Choose a different shortcut."
            case let .invalid(_, problem): problem
            case let .failed(hotkey, status): "\(hotkey.display) could not be registered (error \(status))."
            }
        }
    }

    /// 'UXRV'.
    private static let signature: OSType = 0x5558_5256

    var onPress: (@MainActor () -> Void)?
    private var hotKeyRef: EventHotKeyRef?
    private var handlerRef: EventHandlerRef?

    /// Replaces any current registration. Pass nil to disable.
    @discardableResult
    func register(_ hotkey: Hotkey?) -> Registration {
        unregister()
        guard let hotkey else { return .disabled }
        if let problem = hotkey.problem { return .invalid(hotkey, problem) }
        installHandlerIfNeeded()
        var ref: EventHotKeyRef?
        let status = RegisterEventHotKey(
            hotkey.keyCode, hotkey.carbonModifiers, EventHotKeyID(signature: Self.signature, id: 1),
            GetApplicationEventTarget(), OptionBits(kEventHotKeyExclusive), &ref
        )
        switch status {
        case noErr:
            hotKeyRef = ref
            return .registered(hotkey)
        case OSStatus(eventHotKeyExistsErr):
            return .inUse(hotkey)
        default:
            return .failed(hotkey, status)
        }
    }

    func unregister() {
        if let hotKeyRef { UnregisterEventHotKey(hotKeyRef) }
        hotKeyRef = nil
    }

    private func installHandlerIfNeeded() {
        guard handlerRef == nil else { return }
        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        InstallEventHandler(GetApplicationEventTarget(), { _, _, userData in
            guard let userData else { return OSStatus(eventNotHandledErr) }
            let center = Unmanaged<GlobalHotkeyCenter>.fromOpaque(userData).takeUnretainedValue()
            MainActor.assumeIsolated { center.onPress?() }
            return noErr
        }, 1, &spec, Unmanaged.passUnretained(self).toOpaque(), &handlerRef)
    }
}
