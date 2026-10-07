import Foundation
import Testing
@testable import UXReviewKit

struct HotkeyTests {
    @Test(arguments: [
        ("⌥⇧⌘U", "⌥⇧⌘U"),
        ("opt+shift+cmd+u", "⌥⇧⌘U"),
        ("Cmd-Shift-Opt-U", "⌥⇧⌘U"), // any order, any case, either separator
        ("ctrl+alt+5", "⌃⌥5"),
        ("⌘⌃F6", "⌃⌘F6"), // displayed in Apple's modifier order
        ("F12", "F12"),
        ("⌘Space", "⌘Space"),
        ("⌃⌘-", "⌃⌘-"),
        ("⌥=", "⌥="),
        ("  command + option + [ ", "⌥⌘["),
    ])
    func parsesAndDisplays(text: String, display: String) throws {
        let hotkey = try #require(Hotkey(text))
        #expect(hotkey.display == display)
        #expect(Hotkey(hotkey.display) == hotkey) // the display form round-trips
    }

    @Test(arguments: ["", "⌘", "cmd+", "hyper+u", "cmd+enter", "⌘⌥", "cmd+shift+uu"])
    func rejectsUnknownText(text: String) {
        #expect(Hotkey(text) == nil)
    }

    @Test func carbonValuesMatchTheHeaders() throws {
        let hotkey = Hotkey.defaultCapture
        #expect(hotkey.keyCode == 32) // kVK_ANSI_U
        #expect(hotkey.carbonModifiers == 0x0800 | 0x0200 | 0x0100) // optionKey | shiftKey | cmdKey
        #expect(try #require(Hotkey("⌃A")).carbonModifiers == 0x1000) // controlKey
        #expect(try #require(Hotkey("F1")).keyCode == 122) // kVK_F1
        #expect(try #require(Hotkey("Space")).keyCode == 49) // kVK_Space
    }

    @Test func everySupportedKeyRoundTrips() {
        for (code, _) in Hotkey.names {
            let hotkey = Hotkey(keyCode: code, modifiers: [.command, .option])
            #expect(Hotkey(hotkey.display) == hotkey, "key code \(code)")
        }
        #expect(Hotkey.names.count == 26 + 10 + 12 + 1 + 11)
    }

    @Test func validatesUsableCombinations() throws {
        #expect(Hotkey.defaultCapture.problem == nil)
        #expect(try #require(Hotkey("F6")).problem == nil) // function keys may stand alone
        #expect(try #require(Hotkey("⇧U")).problem?.contains("⌘, ⌃, or ⌥") == true)
        #expect(try #require(Hotkey("U")).problem != nil)
        #expect(Hotkey(keyCode: 999, modifiers: [.command]).problem == "That key can't be used in a shortcut.")
        #expect(Hotkey(keyCode: 999, modifiers: [.command]).display == "⌘#999")
    }

    @Test func codableUsesTheDisplayString() throws {
        let data = try JSONEncoder().encode(Hotkey.defaultCapture)
        #expect(String(data: data, encoding: .utf8) == #""⌥⇧⌘U""#)
        #expect(try JSONDecoder().decode(Hotkey.self, from: data) == .defaultCapture)
        #expect(throws: DecodingError.self) { try JSONDecoder().decode(Hotkey.self, from: Data(#""⌘?""#.utf8)) }
    }
}

final class MemoryStore: KeyValueStoring {
    var values: [String: Any] = [:]
    func data(forKey key: String) -> Data? { values[key] as? Data }
    func set(_ value: Any?, forKey key: String) { values[key] = value }
}

struct CaptureSettingsTests {
    @Test func defaultsWhenNothingIsSaved() {
        let settings = CaptureSettingsStore.load(from: MemoryStore())
        #expect(settings == CaptureSettings())
        #expect(settings.captureHotkey == .defaultCapture)
        #expect(settings.defaultRequest == CaptureRequest(kind: .screenshot, target: .region, delaySeconds: 0))
    }

    /// Save → load → change → save → load, plus disabling and re-enabling the hotkey.
    @Test func persistsChangesAcrossLoads() throws {
        let store = MemoryStore()
        var settings = CaptureSettings(defaultRequest: CaptureRequest(target: .window, delaySeconds: 5), captureHotkey: Hotkey("⌃⌥F6"))
        try CaptureSettingsStore.save(settings, to: store)
        #expect(CaptureSettingsStore.load(from: store) == settings)

        settings.captureHotkey = nil
        try CaptureSettingsStore.save(settings, to: store)
        #expect(CaptureSettingsStore.load(from: store).captureHotkey == nil) // disabled stays disabled

        settings.captureHotkey = .defaultCapture
        settings.defaultRequest.delaySeconds = 3
        try CaptureSettingsStore.save(settings, to: store)
        #expect(CaptureSettingsStore.load(from: store) == settings)
    }

    @Test func storedJSONIsReadable() throws {
        let store = MemoryStore()
        try CaptureSettingsStore.save(CaptureSettings(), to: store)
        let json = try #require(store.data(forKey: CaptureSettingsStore.key).flatMap { String(data: $0, encoding: .utf8) })
        #expect(json == #"{"captureHotkey":"⌥⇧⌘U","defaultRequest":{"delaySeconds":0,"kind":"screenshot","target":"region"}}"#)
    }

    @Test(arguments: [
        ("{not json", CaptureSettings()),
        (#"{"captureHotkey":"⌘?"}"#, CaptureSettings()), // unreadable hotkey → all defaults
        ("{}", CaptureSettings()),
        (
            #"{"defaultRequest":{"target":"display","delaySeconds":99}}"#,
            CaptureSettings(defaultRequest: CaptureRequest(target: .display, delaySeconds: 60))
        ),
        (#"{"captureHotkey":null}"#, CaptureSettings(captureHotkey: nil)),
    ])
    func loadsPartialOrBrokenValues(json: String, expected: CaptureSettings) {
        let store = MemoryStore()
        store.set(Data(json.utf8), forKey: CaptureSettingsStore.key)
        #expect(CaptureSettingsStore.load(from: store) == expected)
    }

    @Test func worksWithRealUserDefaults() throws {
        let suite = "uxreview-tests-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let settings = CaptureSettings(defaultRequest: CaptureRequest(target: .display), captureHotkey: Hotkey("⌃⌘9"))
        try CaptureSettingsStore.save(settings, to: defaults)
        #expect(CaptureSettingsStore.load(from: try #require(UserDefaults(suiteName: suite))) == settings)
    }
}

struct HotkeyActionTests {
    let settings = CaptureSettings(defaultRequest: CaptureRequest(target: .window, delaySeconds: 3))

    @Test func actionForEveryPhase() {
        let request = CaptureRequest()
        let expected: [(CapturePhase, HotkeyAction)] = [
            (.idle, .start(settings.defaultRequest)),
            (.picking(request), .ignore),
            (.countingDown(request, remaining: 2), .cancelCountdown),
            (.capturing, .ignore),
            (.recording(startedAt: Date(timeIntervalSince1970: 0)), .stopRecording),
            (.finishing, .ignore),
        ]
        for (phase, action) in expected {
            #expect(HotkeyAction.decide(phase: phase, settings: settings) == action, "\(phase)")
        }
    }
}

struct SettingsCommandTests {
    @Test func absentWithoutTheFlag() throws {
        #expect(try SettingsCommand.parse(["--status"]) == nil)
        let readOnly = try #require(try SettingsCommand.parse(["--settings"]))
        #expect(!readOnly.changesSomething)
        #expect(readOnly.apply(to: CaptureSettings()) == CaptureSettings())
    }

    @Test func parsesAndAppliesChanges() throws {
        let command = try #require(try SettingsCommand.parse([
            "--settings",
            "--set-hotkey",
            "ctrl+opt+F6",
            "--set-target",
            "window",
            "--set-delay",
            "5",
        ]))
        #expect(command.changesSomething)
        let applied = command.apply(to: CaptureSettings())
        #expect(applied == CaptureSettings(defaultRequest: CaptureRequest(target: .window, delaySeconds: 5), captureHotkey: Hotkey("⌃⌥F6")))
    }

    @Test func noneDisablesTheHotkey() throws {
        let command = try #require(try SettingsCommand.parse(["--settings", "--set-hotkey", "none"]))
        #expect(command.apply(to: CaptureSettings()).captureHotkey == nil)
    }

    @Test(arguments: [
        (["--settings", "--set-hotkey", "cmd+enter"], CommandLineError.invalidValue("--set-hotkey", "cmd+enter")),
        (
            ["--settings", "--set-hotkey", "shift+u"],
            CommandLineError.invalidValue(
                "--set-hotkey",
                "shift+u: Use at least one of ⌘, ⌃, or ⌥ so the shortcut doesn't block normal typing."
            )
        ),
        (["--settings", "--set-target", "tab"], CommandLineError.invalidValue("--set-target", "tab")),
        (["--settings", "--set-delay", "61"], CommandLineError.invalidValue("--set-delay", "61")),
        (["--settings", "--set-hotkey"], CommandLineError.missingValue("--set-hotkey")),
    ])
    func rejectsBadValues(arguments: [String], expected: CommandLineError) {
        #expect(throws: expected) { try SettingsCommand.parse(arguments) }
    }
}
