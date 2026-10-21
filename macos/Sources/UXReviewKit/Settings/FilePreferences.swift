import Foundation

/// Preferences that also store the selected project's path.
public protocol PreferencesStoring: KeyValueStoring {
    func string(forKey key: String) -> String?
}

extension UserDefaults: PreferencesStoring {}

/// A shared, temporary plist for test processes. Absolute-path UserDefaults suites can be
/// treated as managed/read-only by another process; this adapter writes the file directly.
/// Re-read before each operation so sequential writers preserve each other's keys.
public final class FilePreferences: PreferencesStoring {
    public let url: URL

    public init(url: URL) { self.url = url }

    public func data(forKey key: String) -> Data? { values()[key] as? Data }
    public func string(forKey key: String) -> String? { values()[key] as? String }
    public func double(forKey key: String) -> Double? {
        let value = values()[key]
        if let number = value as? NSNumber { return number.doubleValue }
        return (value as? String).flatMap(Double.init)
    }

    /// Matches UserDefaults' nonthrowing interface. Unreadable/missing files start empty;
    /// unsupported plist values or failed writes leave the previous file intact.
    public func set(_ value: Any?, forKey key: String) {
        var values = values()
        values[key] = value
        guard PropertyListSerialization.propertyList(values, isValidFor: .binary),
              let data = try? PropertyListSerialization.data(fromPropertyList: values, format: .binary, options: 0)
        else { return }
        do {
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try data.write(to: url, options: .atomic)
        } catch {
            // The caller's next read observes the last successful write.
        }
    }

    private func values() -> [String: Any] {
        guard let data = try? Data(contentsOf: url),
              let plist = try? PropertyListSerialization.propertyList(from: data, options: [], format: nil)
        else { return [:] }
        return plist as? [String: Any] ?? [:]
    }
}
