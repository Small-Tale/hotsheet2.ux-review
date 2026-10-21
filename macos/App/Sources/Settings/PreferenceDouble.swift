import SwiftUI
import UXReviewKit

/// Preserves native AppStorage behavior while making isolated file overrides observable.
@MainActor
@propertyWrapper
struct PreferenceDouble: DynamicProperty {
    @AppStorage private var nativeValue: Double
    @StateObject private var fileValue: FileDoublePreference

    init(_ key: String, defaultValue: Double) {
        _nativeValue = AppStorage(wrappedValue: defaultValue, key, store: AppSettings.nativeDefaults)
        _fileValue = StateObject(wrappedValue: FileDoublePreference(
            key: key,
            defaultValue: defaultValue,
            store: AppSettings.isolatedDefaults
        ))
    }

    var wrappedValue: Double {
        get { fileValue.isEnabled ? fileValue.value : nativeValue }
        nonmutating set {
            if fileValue.isEnabled { fileValue.set(newValue) } else { nativeValue = newValue }
        }
    }
}
