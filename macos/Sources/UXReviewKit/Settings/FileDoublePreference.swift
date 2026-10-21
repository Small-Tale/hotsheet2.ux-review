import Combine
import Foundation

/// Live numeric preferences for a shared test plist. Native app preferences use AppStorage.
/// A common-mode timer observes atomic file replacement by other windows/processes even while
/// a menu or drag tracks. It is active only for an absolute-path preference override.
@MainActor
public final class FileDoublePreference: ObservableObject {
    @Published public private(set) var value: Double
    public let isEnabled: Bool
    private let store: FilePreferences?
    private let key: String
    private let defaultValue: Double
    private var observation: AnyCancellable?

    public init(key: String, defaultValue: Double, store: FilePreferences?) {
        self.key = key
        self.defaultValue = defaultValue
        self.store = store
        isEnabled = store != nil
        value = Self.read(key: key, defaultValue: defaultValue, store: store)
        if isEnabled {
            observation = Timer.publish(every: 0.25, on: .main, in: .common).autoconnect().sink { [weak self] _ in
                self?.refresh()
            }
        }
    }

    public func set(_ value: Double) {
        guard let store else { return }
        store.set(value, forKey: key)
        // A failed write keeps the last durable value, just as a subsequent refresh does.
        refresh()
    }

    public func refresh() {
        let next = Self.read(key: key, defaultValue: defaultValue, store: store)
        if value != next { value = next }
    }

    private static func read(key: String, defaultValue: Double, store: FilePreferences?) -> Double {
        guard let number = store?.double(forKey: key), number.isFinite else { return defaultValue }
        return number
    }
}
