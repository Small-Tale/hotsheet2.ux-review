import Foundation
import Testing
@testable import UXReviewKit

/// The menu bar menu and the app's Capture menu across every capture phase, plus the Dock
/// presence rule. Spec: docs/05-start-and-settings.md §5.1.
struct AppMenusTests {
    static let start = Date(timeIntervalSince1970: 1000)

    func submenu(_ title: String, in entries: [MenuEntry]) -> [MenuEntry]? {
        for entry in entries {
            if case let .submenu(name, children) = entry, name == title { return children }
        }
        return nil
    }

    @Test func idleStatusMenuMatchesTheRequestedLayout() {
        let entries = AppMenus.statusMenu(MenuState(version: "1.2"))
        #expect(entries.map(\.title) == [
            "UX Review 1.2", nil, "Capture Image", "Capture Video", nil, "Settings…", "Open UX Review", nil, "Quit UX Review",
        ])
        #expect(entries.first == .label("UX Review 1.2"))
        #expect(entries.contains(.action("Settings…", .openSettings, shortcut: MenuShortcut(","))))
        #expect(entries.contains(.action("Quit UX Review", .quit, shortcut: MenuShortcut("q"))))
    }

    @Test func captureSubmenusOfferImmediateAndThreeOrTenSecondDelaysForTheDefaultTarget() throws {
        let settings = CaptureSettings(defaultRequest: CaptureRequest(kind: .screenshot, target: .window, delaySeconds: 5))
        let entries = AppMenus.statusMenu(MenuState(settings: settings))
        let image = try #require(submenu("Capture Image", in: entries))
        #expect(image == [
            .label("Image of Window"),
            .action("Immediate", .capture(CaptureRequest(kind: .screenshot, target: .window))),
            .choices("Delayed", [
                MenuChoice(
                    "3 s",
                    .capture(CaptureRequest(kind: .screenshot, target: .window, delaySeconds: 3)),
                    accessibilityLabel: "Image of Window after 3 seconds"
                ),
                MenuChoice(
                    "10 s",
                    .capture(CaptureRequest(kind: .screenshot, target: .window, delaySeconds: 10)),
                    accessibilityLabel: "Image of Window after 10 seconds"
                ),
            ]),
        ])
        let video = try #require(submenu("Capture Video", in: entries))
        #expect(video.first == .label("Video of Window"))
        #expect(video.contains(.action("Immediate", .capture(CaptureRequest(kind: .video, target: .window)))))
        // Video keeps the one-recording narration checkbox (docs/04 §4.9).
        #expect(video.last == .toggle("Narrate Next Recording with Microphone", isOn: false, .toggleNarration))
        #expect(!image.contains { $0.title == "Narrate Next Recording with Microphone" })
    }

    @Test func immediateItemsShowTheHotkeyThatStartsExactlyThatCapture() throws {
        let hotkeys: [HotkeySlot: Hotkey] = [.capture: .defaultCapture, .record: .defaultRecord]
        // Default: screenshot of region, no delay. Both hotkeys match an Immediate item.
        var state = MenuState(hotkeys: hotkeys)
        var entries = AppMenus.statusMenu(state)
        let image = try #require(submenu("Capture Image", in: entries))
        let video = try #require(submenu("Capture Video", in: entries))
        #expect(image[1] == .action(
            "Immediate",
            .capture(CaptureRequest(kind: .screenshot, target: .region)),
            shortcut: MenuShortcut("u", [.option, .shift, .command])
        ))
        #expect(video[1] == .action(
            "Immediate",
            .capture(CaptureRequest(kind: .video, target: .region)),
            shortcut: MenuShortcut("v", [.option, .shift, .command])
        ))
        // A default delay means the hotkeys start a delayed capture, which the menu bar menu
        // doesn't list as an item (5 s is not a status-menu delay), so no shortcut shows.
        state.settings.defaultRequest.delaySeconds = 5
        entries = AppMenus.statusMenu(state)
        #expect(try #require(submenu("Capture Image", in: entries))[1] == .action(
            "Immediate",
            .capture(CaptureRequest(kind: .screenshot, target: .region))
        ))
        // A hotkey the menu can't render (F6) shows nothing but still exists.
        state.settings.defaultRequest.delaySeconds = 0
        state.hotkeys[.capture] = Hotkey("⌃F6")
        entries = AppMenus.statusMenu(state)
        #expect(try #require(submenu("Capture Image", in: entries))[1] == .action(
            "Immediate",
            .capture(CaptureRequest(kind: .screenshot, target: .region))
        ))
    }

    @Test func openUXReviewShowsItsGlobalShortcut() {
        let entries = AppMenus.statusMenu(MenuState(hotkeys: [.openReview: .defaultOpenReview]))
        #expect(entries.contains(.action(
            "Open UX Review",
            .openUXReview,
            shortcut: MenuShortcut("e", [.option, .shift, .command])
        )))
        #expect(AppMenus.statusMenu(MenuState()).contains(.action("Open UX Review", .openUXReview)))
    }

    @Test func narrationCheckboxFollowsTheNextRecordingChoice() throws {
        let entries = AppMenus.statusMenu(MenuState(narratesNextRecording: true))
        #expect(try #require(submenu("Capture Video", in: entries)).last == .toggle(
            "Narrate Next Recording with Microphone",
            isOn: true,
            .toggleNarration
        ))
    }

    /// Every phase: the capture submenus give way to what stops or explains the capture, and
    /// the rest of the menu stays put.
    @Test func runningCapturesReplaceTheCaptureSubmenus() {
        let request = CaptureRequest()
        let cases: [(CapturePhase, Bool, [MenuEntry])] = [
            (.picking(request), false, [.label("Choosing what to capture… (Esc cancels)")]),
            (.countingDown(request, remaining: 3), false, [.action("Cancel Capture (3 s)", .cancelCapture)]),
            (.capturing, false, [.label("Capturing…")]),
            (.recording(startedAt: Self.start), false, [.action("Stop Recording (1:05)", .stopRecording)]),
            (.recording(startedAt: Self.start), true, [
                .action("Stop Recording (1:05)", .stopRecording),
                .label("Recording microphone narration"),
            ]),
            (.finishing, false, [.label("Saving recording…")]),
        ]
        for (phase, narrating, middle) in cases {
            let state = MenuState(phase: phase, recordingNarration: narrating, now: Self.start.addingTimeInterval(65.4))
            let entries = AppMenus.statusMenu(state)
            #expect(Array(entries[2 ..< 2 + middle.count]) == middle, "\(phase)")
            #expect(entries.suffix(5).map(\.title) == [nil, "Settings…", "Open UX Review", nil, "Quit UX Review"])
            #expect(AppMenus.captureMenu(state) == middle)
        }
    }

    @Test func appCaptureMenuOffersEveryTargetAndDelay() throws {
        let hotkeys: [HotkeySlot: Hotkey] = [.capture: .defaultCapture, .record: .defaultRecord]
        let entries = AppMenus.captureMenu(MenuState(hotkeys: hotkeys))
        #expect(entries.map(\.title) == [
            "Screenshot of Screen", "Screenshot of Window", "Screenshot of Region", "Screenshot After Delay", nil,
            "Record Video of Screen", "Record Video of Window", "Record Video of Region", "Record Video After Delay",
            nil, "Narrate Next Recording with Microphone",
        ])
        #expect(entries[2] == .action(
            "Screenshot of Region",
            .capture(CaptureRequest(target: .region)),
            shortcut: MenuShortcut("u", [.option, .shift, .command])
        ))
        let delayed = try #require(submenu("Record Video After Delay", in: entries))
        #expect(delayed.count == (CaptureRequest.delayPresets.count - 1) * CaptureTarget.allCases.count)
        #expect(delayed.first == .action(
            "Screen after 3 s",
            .capture(CaptureRequest(kind: .video, target: .display, delaySeconds: 3))
        ))
    }

    @Test func shortcutsRenderLettersDigitsAndSpaceOnly() {
        #expect(MenuShortcut(Hotkey("⌥⇧⌘U")) == MenuShortcut("u", [.option, .shift, .command]))
        #expect(MenuShortcut(Hotkey("⌃⌥⌘8")) == MenuShortcut("8", [.control, .option, .command]))
        #expect(MenuShortcut(Hotkey("⌃⌥Space")) == MenuShortcut(" ", [.control, .option]))
        #expect(MenuShortcut(Hotkey("⌃F6")) == nil)
        #expect(MenuShortcut(Hotkey("⌃⌥;")) == nil)
        #expect(MenuShortcut(nil) == nil)
        #expect(MenuShortcut("u", [.option, .shift, .command]).display == "⌥⇧⌘U")
        #expect(MenuShortcut(" ", [.control]).display == "⌃Space")
    }

    @Test func clockFormatsMinutesAndSeconds() {
        #expect(AppMenus.clock(0) == "0:00")
        #expect(AppMenus.clock(65400) == "1:05")
        #expect(AppMenus.clock(3_600_000) == "60:00")
        #expect(AppMenus.clock(-5) == "0:00")
    }

    // MARK: Dock presence

    @Test func dockIconShowsWhileAnyWindowIsOpen() {
        var presence = WindowPresence()
        #expect(presence.policy == .accessory)
        // Each step: (open or close, window id, whether the policy changes, policy after).
        let steps: [(Bool, String, Bool, WindowPresence.Policy)] = [
            (true, "editor:a", true, .regular),
            // More windows, or the same one again, don't change the policy.
            (true, "session:a", false, .regular),
            (true, "editor:a", false, .regular),
            (false, "editor:a", false, .regular),
            // Closing an unknown or already-closed window changes nothing.
            (false, "editor:a", false, .regular),
            (false, "drafts", false, .regular),
            (false, "session:a", true, .accessory),
            (false, "session:a", false, .accessory),
            // Empty, then refilled.
            (true, "settings", true, .regular),
        ]
        for (open, id, changes, policy) in steps {
            let changed = open ? presence.opened(id) : presence.closed(id)
            #expect(changed == changes, "\(open ? "open" : "close") \(id)")
            #expect(presence.policy == policy, "\(open ? "open" : "close") \(id)")
        }
        #expect(presence.open == ["settings"])
    }
}
