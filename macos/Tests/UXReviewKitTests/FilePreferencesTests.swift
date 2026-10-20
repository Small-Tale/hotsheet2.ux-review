import Foundation
import Testing
@testable import UXReviewKit

struct FilePreferencesTests {
    @Test func sequentialInstancesPreserveKeysDeleteAndRefill() throws {
        let root = try TestSupport.makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("nested/defaults.plist")
        let first = FilePreferences(url: url)
        let second = FilePreferences(url: url)
        #expect(first.data(forKey: "settings") == nil && first.string(forKey: "project") == nil)
        first.set(Data([1, 2, 3]), forKey: "settings")
        second.set("first", forKey: "project")
        #expect(first.string(forKey: "project") == "first")
        #expect(second.data(forKey: "settings") == Data([1, 2, 3]))
        #expect(first.data(forKey: "project") == nil && first.string(forKey: "settings") == nil)
        first.set("second", forKey: "project")
        #expect(second.string(forKey: "project") == "second")
        second.set(nil, forKey: "project")
        #expect(first.string(forKey: "project") == nil)
        first.set(nil, forKey: "settings")
        second.set(Data([4]), forKey: "settings")
        #expect(first.data(forKey: "settings") == Data([4]))
        first.set("refilled", forKey: "project")
        #expect(second.string(forKey: "project") == "refilled")
        let before = try Data(contentsOf: url)
        second.set(NSObject(), forKey: "invalid")
        #expect(try Data(contentsOf: url) == before)
    }

    @Test func malformedAndNonDictionaryFilesRecoverAndFailedWritesStayEmpty() throws {
        let root = try TestSupport.makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("defaults.plist")
        let preferences = FilePreferences(url: url)
        for data in [Data("broken".utf8), try PropertyListSerialization.data(fromPropertyList: ["array"], format: .binary, options: 0)] {
            try data.write(to: url)
            #expect(preferences.string(forKey: "project") == nil)
            preferences.set("recovered", forKey: "project")
            #expect(FilePreferences(url: url).string(forKey: "project") == "recovered")
        }
        let blocked = FilePreferences(url: url.appendingPathComponent("child.plist"))
        blocked.set("cannot write under a file", forKey: "project")
        #expect(blocked.string(forKey: "project") == nil)
        #expect(preferences.string(forKey: "project") == "recovered")
    }

    @Test func anotherProcessCanUpdateTheSamePreferenceFile() throws {
        let root = try TestSupport.makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("defaults.plist")
        let preferences = FilePreferences(url: url)
        preferences.set("original", forKey: "projectDirectory")
        preferences.set(Data([1, 2]), forKey: "captureSettings")
        let result = try SystemProcessRunner().run(
            executable: URL(fileURLWithPath: "/usr/bin/plutil"),
            arguments: ["-replace", "projectDirectory", "-string", "chosen", url.path],
            environment: ProcessInfo.processInfo.environment, currentDirectory: nil
        )
        #expect(result.exitCode == 0, "\(result.stderr)")
        #expect(preferences.string(forKey: "projectDirectory") == "chosen")
        #expect(preferences.data(forKey: "captureSettings") == Data([1, 2]))
        preferences.set("next", forKey: "projectDirectory")
        #expect(FilePreferences(url: url).string(forKey: "projectDirectory") == "next")
    }
}
