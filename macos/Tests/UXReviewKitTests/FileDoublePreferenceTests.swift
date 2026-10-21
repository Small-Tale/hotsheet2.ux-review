import Foundation
import Testing
@testable import UXReviewKit

@MainActor
struct FileDoublePreferenceTests {
    @Test func editsExternalChangesResetAndRefillPreserveOtherKeys() throws {
        let root = try TestSupport.makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("defaults.plist")
        let store = FilePreferences(url: file)
        store.set("project", forKey: "projectDirectory")
        let first = FileDoublePreference(key: "width", defaultValue: 112, store: store)
        let second = FileDoublePreference(key: "width", defaultValue: 112, store: FilePreferences(url: file))
        #expect(first.isEnabled && first.value == 112)
        first.set(192)
        second.refresh()
        #expect(second.value == 192 && store.double(forKey: "width") == 192)
        second.set(256)
        first.refresh()
        #expect(first.value == 256)
        store.set(nil, forKey: "width")
        first.refresh()
        #expect(first.value == 112)
        store.set("224.5", forKey: "width")
        first.refresh()
        #expect(first.value == 224.5)
        first.set(112)
        first.set(160)
        #expect(FileDoublePreference(key: "width", defaultValue: 112, store: store).value == 160)
        #expect(store.string(forKey: "projectDirectory") == "project")
    }

    @Test func badValuesAndFailedWritesRetainDurableState() throws {
        let root = try TestSupport.makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("defaults.plist")
        let store = FilePreferences(url: file)
        let preference = FileDoublePreference(key: "width", defaultValue: 112, store: store)
        for value: Any in ["broken", Data([1]), Double.nan, Double.infinity] {
            store.set(value, forKey: "width")
            preference.refresh()
            #expect(preference.value == 112)
        }
        try Data("malformed".utf8).write(to: file)
        preference.refresh()
        #expect(preference.value == 112)
        preference.set(240)
        #expect(preference.value == 240)
        try FileManager.default.removeItem(at: file)
        try FileManager.default.createDirectory(at: file, withIntermediateDirectories: true)
        preference.set(180)
        #expect(preference.value == 112)
        let native = FileDoublePreference(key: "width", defaultValue: 112, store: nil)
        native.set(300)
        native.refresh()
        #expect(!native.isEnabled && native.value == 112)
    }
}
