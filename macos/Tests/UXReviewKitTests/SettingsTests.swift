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
        #expect(settings.recordHotkey == .defaultRecord)
        #expect(Hotkey.defaultRecord.display == "⌥⇧⌘V")
        #expect(settings.defaultRequest == CaptureRequest(kind: .screenshot, target: .region, delaySeconds: 0))
        #expect(!settings.narration) // narration is opt-in
    }

    /// Off → on → off, each surviving a save and reload alongside the other fields.
    @Test func persistsNarration() throws {
        let store = MemoryStore()
        var settings = CaptureSettings(defaultRequest: CaptureRequest(kind: .video, target: .display), narration: true)
        try CaptureSettingsStore.save(settings, to: store)
        #expect(CaptureSettingsStore.load(from: store) == settings)
        #expect(CaptureSettingsStore.load(from: store).narration)
        settings.narration = false
        try CaptureSettingsStore.save(settings, to: store)
        #expect(CaptureSettingsStore.load(from: store) == settings)
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
        #expect(
            json == #"{"captureHotkey":"⌥⇧⌘U","defaultRequest":{"delaySeconds":0,"kind":"screenshot","target":"region"},"#
                + #""narration":false,"recordHotkey":"⌥⇧⌘V"}"#
        )
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
        // Settings saved before the record hotkey existed get its default.
        (#"{"captureHotkey":"⌃⌘9"}"#, CaptureSettings(captureHotkey: Hotkey("⌃⌘9"), recordHotkey: .defaultRecord)),
        (#"{"recordHotkey":null}"#, CaptureSettings(recordHotkey: nil)),
        (#"{"recordHotkey":"⌘?"}"#, CaptureSettings()),
        // Settings saved before narration existed record without it.
        (#"{"captureHotkey":"⌥⇧⌘U"}"#, CaptureSettings(narration: false)),
        (#"{"narration":true}"#, CaptureSettings(narration: true)),
        (#"{"narration":"yes"}"#, CaptureSettings()), // wrong type → all defaults
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

struct HotkeySlotTests {
    @Test func subscriptReadsAndWritesEachSlot() {
        var settings = CaptureSettings()
        #expect(settings[.capture] == .defaultCapture)
        #expect(settings[.record] == .defaultRecord)
        settings[.record] = nil
        settings[.capture] = Hotkey("F6")
        #expect(settings.recordHotkey == nil)
        #expect(settings.captureHotkey == Hotkey("F6"))
    }

    @Test func duplicateRules() throws {
        let settings = CaptureSettings()
        // Each slot's own combination is fine; the other slot's is not.
        #expect(settings.problem(with: .defaultCapture, for: .capture) == nil)
        #expect(settings.problem(with: .defaultRecord, for: .capture) == "⌥⇧⌘V is already the record video shortcut.")
        #expect(settings.problem(with: .defaultCapture, for: .record) == "⌥⇧⌘U is already the capture shortcut.")
        #expect(settings.problem(with: try #require(Hotkey("⌃⌥F6")), for: .record) == nil)
        // An unusable combination reports its own problem first.
        #expect(settings.problem(with: try #require(Hotkey("⇧U")), for: .record)?.contains("⌘, ⌃, or ⌥") == true)
        // A disabled slot blocks nothing.
        let oneOff = CaptureSettings(captureHotkey: nil)
        #expect(oneOff.problem(with: .defaultCapture, for: .record) == nil)
    }

    @Test func registrableSkipsDisabledAndDuplicateSlots() {
        #expect(CaptureSettings().registrable(.capture) == .defaultCapture)
        #expect(CaptureSettings().registrable(.record) == .defaultRecord)
        #expect(CaptureSettings(recordHotkey: nil).registrable(.record) == nil)
        // Hand-edited duplicates: the earlier slot keeps the combination.
        let duplicate = CaptureSettings(captureHotkey: .defaultRecord, recordHotkey: .defaultRecord)
        #expect(duplicate.registrable(.capture) == .defaultRecord)
        #expect(duplicate.registrable(.record) == nil)
    }

    @Test func carbonIDsAreDistinctAndRoundTrip() {
        let ids = HotkeySlot.allCases.map(\.carbonID)
        #expect(Set(ids).count == ids.count)
        #expect(!ids.contains(0))
        for slot in HotkeySlot.allCases {
            #expect(HotkeySlot(carbonID: slot.carbonID) == slot)
        }
        #expect(HotkeySlot(carbonID: 99) == nil)
    }

    @Test func recordSlotAlwaysRecordsTheDefaultTargetAndDelay() {
        let screenshot = CaptureSettings(defaultRequest: CaptureRequest(kind: .screenshot, target: .window, delaySeconds: 5))
        #expect(HotkeySlot.capture.request(in: screenshot) == screenshot.defaultRequest)
        #expect(HotkeySlot.record.request(in: screenshot) == CaptureRequest(kind: .video, target: .window, delaySeconds: 5))
        let video = CaptureSettings(defaultRequest: CaptureRequest(kind: .video, target: .display))
        #expect(HotkeySlot.record.request(in: video) == video.defaultRequest)
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

    /// Either slot ends what the other started: same cancel/stop/ignore rules, different start.
    @Test func recordSlotForEveryPhase() {
        let request = CaptureRequest()
        let expected: [(CapturePhase, HotkeyAction)] = [
            (.idle, .start(CaptureRequest(kind: .video, target: .window, delaySeconds: 3))),
            (.picking(request), .ignore),
            (.countingDown(request, remaining: 2), .cancelCountdown),
            (.capturing, .ignore),
            (.recording(startedAt: Date(timeIntervalSince1970: 0)), .stopRecording),
            (.finishing, .ignore),
        ]
        for (phase, action) in expected {
            #expect(HotkeyAction.decide(phase: phase, settings: settings, slot: .record) == action, "\(phase)")
        }
    }
}

struct SettingsCommandTests {
    @Test func absentWithoutTheFlag() throws {
        #expect(try SettingsCommand.parse(["--status"]) == nil)
        let readOnly = try #require(try SettingsCommand.parse(["--settings"]))
        #expect(!readOnly.changesSomething)
        #expect(try readOnly.apply(to: CaptureSettings()) == CaptureSettings())
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
        let applied = try command.apply(to: CaptureSettings())
        #expect(applied == CaptureSettings(defaultRequest: CaptureRequest(target: .window, delaySeconds: 5), captureHotkey: Hotkey("⌃⌥F6")))
    }

    @Test func noneDisablesTheHotkey() throws {
        let command = try #require(try SettingsCommand.parse(["--settings", "--set-hotkey", "none"]))
        #expect(try command.apply(to: CaptureSettings()).captureHotkey == nil)
        let record = try #require(try SettingsCommand.parse(["--settings", "--set-record-hotkey", "NONE"]))
        #expect(record.changesSomething)
        #expect(try record.apply(to: CaptureSettings()) == CaptureSettings(recordHotkey: nil))
    }

    @Test func setsNarrationOnAndOff() throws {
        let turnOn = try #require(try SettingsCommand.parse(["--settings", "--set-narration", "on"]))
        #expect(turnOn.changesSomething)
        #expect(try turnOn.apply(to: CaptureSettings()) == CaptureSettings(narration: true))
        let off = try #require(try SettingsCommand.parse(["--settings", "--set-narration", "OFF"]))
        #expect(try off.apply(to: CaptureSettings(narration: true)) == CaptureSettings())
        // Absent: unchanged either way.
        let none = try #require(try SettingsCommand.parse(["--settings", "--set-delay", "3"]))
        #expect(none.narration == nil)
        #expect(try none.apply(to: CaptureSettings(narration: true)).narration)
    }

    @Test func setsTheRecordHotkey() throws {
        let command = try #require(try SettingsCommand.parse(["--settings", "--set-record-hotkey", "ctrl+opt+cmd+F7"]))
        #expect(try command.apply(to: CaptureSettings()).recordHotkey == Hotkey("⌃⌥⌘F7"))
    }

    @Test func rejectsADuplicateOfTheOtherSlot() throws {
        let toRecord = try #require(try SettingsCommand.parse(["--settings", "--set-record-hotkey", "opt+shift+cmd+u"]))
        #expect(throws: CommandLineError.invalidValue("--set-record-hotkey", "⌥⇧⌘U: ⌥⇧⌘U is already the capture shortcut.")) {
            try toRecord.apply(to: CaptureSettings())
        }
        let toCapture = try #require(try SettingsCommand.parse(["--settings", "--set-hotkey", "opt+shift+cmd+v"]))
        #expect(throws: CommandLineError.invalidValue("--set-hotkey", "⌥⇧⌘V: ⌥⇧⌘V is already the record video shortcut.")) {
            try toCapture.apply(to: CaptureSettings())
        }
        // Allowed once the other slot is disabled, and when both swap in one command.
        #expect(try toRecord.apply(to: CaptureSettings(captureHotkey: nil)).recordHotkey == .defaultCapture)
        let swap = try #require(try SettingsCommand.parse([
            "--settings", "--set-hotkey", "opt+shift+cmd+v", "--set-record-hotkey", "opt+shift+cmd+u",
        ]))
        #expect(try swap.apply(to: CaptureSettings()) == CaptureSettings(captureHotkey: .defaultRecord, recordHotkey: .defaultCapture))
        // Changing only the target never trips over an already-duplicated (hand-edited) pair.
        let target = try #require(try SettingsCommand.parse(["--settings", "--set-target", "display"]))
        let duplicated = CaptureSettings(captureHotkey: .defaultRecord, recordHotkey: .defaultRecord)
        #expect(try target.apply(to: duplicated).defaultRequest.target == .display)
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
        (["--settings", "--set-record-hotkey", "cmd+enter"], CommandLineError.invalidValue("--set-record-hotkey", "cmd+enter")),
        (["--settings", "--set-record-hotkey"], CommandLineError.missingValue("--set-record-hotkey")),
        (["--settings", "--set-narration", "yes"], CommandLineError.invalidValue("--set-narration", "yes")),
        (["--settings", "--set-narration"], CommandLineError.missingValue("--set-narration")),
    ])
    func rejectsBadValues(arguments: [String], expected: CommandLineError) {
        #expect(throws: expected) { try SettingsCommand.parse(arguments) }
    }
}
