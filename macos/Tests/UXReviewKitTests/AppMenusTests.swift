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
            "UX Review 1.2", nil, "Capture", "Delay", "Capture Image", "Capture Video",
            "Narrate Next Recording with Microphone", nil, "Settings…", "Open UX Review", nil, "Quit UX Review",
        ])
        #expect(entries.first == .label("UX Review 1.2"))
        #expect(entries.contains(.action("Settings…", .openSettings, shortcut: MenuShortcut(","))))
        #expect(entries.contains(.action("Quit UX Review", .quit, shortcut: MenuShortcut("q"))))
        // HS2-WC6JSH: no submenus; Capture Image/Video capture the default request when chosen.
        #expect(!entries.contains { if case .submenu = $0 { true } else { false } })
        #expect(entries[4] == .action("Capture Image", .captureDefault(.screenshot)))
        #expect(entries[5] == .action("Capture Video", .captureDefault(.video)))
        #expect(entries[6] == .toggle("Narrate Next Recording with Microphone", isOn: false, .toggleNarration))
    }

    /// HS2-W62GWS: "Capture [Screen | Window | Region]" heads the capture rows, shows the default
    /// target, and choosing a segment sets it.
    @Test func targetPickerShowsAndSetsTheDefaultTarget() throws {
        let entries = AppMenus.statusMenu(MenuState())
        #expect(entries[2] == .picker("Capture", [
            MenuChoice("Screen", .setCaptureTarget(.display), accessibilityLabel: "Capture Screen"),
            MenuChoice("Window", .setCaptureTarget(.window), accessibilityLabel: "Capture Window"),
            MenuChoice("Region", .setCaptureTarget(.region), accessibilityLabel: "Capture Region"),
        ], selected: 2))
    }

    /// HS2-WC6JSH: "Delay [None | 3 s | 10 s]" shows the default delay, and choosing a segment sets it.
    @Test func delayPickerShowsAndSetsTheDefaultDelay() throws {
        let entries = AppMenus.statusMenu(MenuState())
        #expect(entries[3] == .picker("Delay", [
            MenuChoice("None", .setCaptureDelay(0), accessibilityLabel: "No delay"),
            MenuChoice("3 s", .setCaptureDelay(3), accessibilityLabel: "Delay 3 seconds"),
            MenuChoice("10 s", .setCaptureDelay(10), accessibilityLabel: "Delay 10 seconds"),
        ], selected: 0))
    }

    /// A default delay the row doesn't offer (5 s from Settings) shows as its own selected
    /// segment, in order, and goes away once a listed delay is chosen.
    @Test func delayPickerShowsADefaultItDoesNotOffer() throws {
        var state = MenuState()
        for (delay, titles, selected) in [
            (5, ["None", "3 s", "5 s", "10 s"], 2),
            (10, ["None", "3 s", "10 s"], 2),
            (60, ["None", "3 s", "10 s", "60 s"], 3),
            (0, ["None", "3 s", "10 s"], 0),
        ] {
            state.settings.defaultRequest.delaySeconds = delay
            guard case let .picker(_, choices, index) = AppMenus.statusMenu(state)[3] else {
                Issue.record("no Delay picker for \(delay)")
                continue
            }
            #expect(choices.map(\.title) == titles, "\(delay)")
            #expect(index == selected, "\(delay)")
            #expect(choices[try #require(index)].command == .setCaptureDelay(delay))
        }
    }

    /// Target and delay changes, interleaved and repeated (what the app does with
    /// `.setCaptureTarget` / `.setCaptureDelay`): both pickers always follow the settings, the
    /// kind stays put, and the capture items and their shortcuts track the default request.
    @Test func pickersFollowEveryTargetAndDelayChange() throws {
        let hotkeys: [HotkeySlot: Hotkey] = [.capture: .defaultCapture, .record: .defaultRecord]
        var state = MenuState(
            settings: CaptureSettings(defaultRequest: CaptureRequest(kind: .video, target: .region, delaySeconds: 5)),
            hotkeys: hotkeys
        )
        let steps: [MenuCommand] = [
            .setCaptureTarget(.display), .setCaptureDelay(3), .setCaptureDelay(3), .setCaptureTarget(.window),
            .setCaptureDelay(10), .setCaptureTarget(.window), .setCaptureDelay(0), .setCaptureTarget(.region),
        ]
        for command in steps {
            switch command {
            case let .setCaptureTarget(target): state.settings.defaultRequest.target = target
            case let .setCaptureDelay(seconds): state.settings.defaultRequest.delaySeconds = seconds
            default: break
            }
            let request = state.settings.defaultRequest
            let entries = AppMenus.statusMenu(state)
            guard case let .picker(_, targets, target) = entries[2], case let .picker(_, delays, delay) = entries[3] else {
                Issue.record("no pickers after \(command)")
                continue
            }
            #expect(targets[try #require(target)].command == .setCaptureTarget(request.target), "\(command)")
            #expect(delays[try #require(delay)].command == .setCaptureDelay(request.delaySeconds), "\(command)")
            // The Settings-only 5 s shows until a listed delay replaces it.
            let offered = request.delaySeconds == 5 ? ["None", "3 s", "5 s", "10 s"] : ["None", "3 s", "10 s"]
            #expect(delays.map(\.title) == offered, "\(command)")
            #expect(request.kind == .video)
            // An item shows the hotkey that starts exactly its capture. The default kind here is
            // video, so both hotkeys record and Capture Video shows the first (Capture, ⌥⇧⌘U).
            #expect(entries[4] == .action("Capture Image", .captureDefault(.screenshot)))
            #expect(entries[5] == .action(
                "Capture Video",
                .captureDefault(.video),
                shortcut: MenuShortcut("u", [.option, .shift, .command])
            ))
        }
    }

    /// The pickers only show while idle: during a capture, they go with the capture items.
    @Test func targetPickerIsHiddenWhileACaptureRuns() {
        for phase in [
            CapturePhase.picking(CaptureRequest()),
            .countingDown(CaptureRequest(), remaining: 2),
            .capturing,
            .recording(startedAt: Self.start),
            .finishing,
        ] {
            #expect(!AppMenus.statusMenu(MenuState(phase: phase)).contains { if case .picker = $0 { true } else { false } }, "\(phase)")
        }
    }

    @Test func captureItemsShowTheirHotkeysWhenTheMenuCanRenderThem() throws {
        var state = MenuState(hotkeys: [.capture: .defaultCapture, .record: .defaultRecord])
        // Every default delay: the hotkeys start the default request, which the items capture.
        for delay in [0, 3, 5, 10] {
            state.settings.defaultRequest.delaySeconds = delay
            let entries = AppMenus.statusMenu(state)
            #expect(entries[4] == .action(
                "Capture Image",
                .captureDefault(.screenshot),
                shortcut: MenuShortcut("u", [.option, .shift, .command])
            ))
            #expect(entries[5] == .action(
                "Capture Video",
                .captureDefault(.video),
                shortcut: MenuShortcut("v", [.option, .shift, .command])
            ))
        }
        // A hotkey the menu can't render (F6) shows nothing but still exists; an unset one too.
        state.hotkeys[.capture] = Hotkey("⌃F6")
        state.hotkeys[.record] = nil
        let entries = AppMenus.statusMenu(state)
        #expect(entries[4] == .action("Capture Image", .captureDefault(.screenshot)))
        #expect(entries[5] == .action("Capture Video", .captureDefault(.video)))
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
        #expect(entries[6] == .toggle(
            "Narrate Next Recording with Microphone",
            isOn: true,
            .toggleNarration
        ))
    }

    /// Every phase: the capture rows give way to what stops or explains the capture, and
    /// the rest of the menu stays put.
    @Test func runningCapturesReplaceTheCaptureRows() {
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
            #expect(entries.count == 2 + middle.count + 5, "\(phase)")
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

    /// HS2-T4RS7M: picker rows put their titles where AppKit puts item titles: 16 pt in, or 30 pt
    /// when an item at the same level is checked. Walks narration off → on → off, a running
    /// capture (no toggle), and the app Capture menu, whose toggle is at its top level.
    @Test func pickerTitlesFollowTheCheckmarkColumn() {
        var state = MenuState()
        for (narrating, inset) in [(false, 16.0), (true, 30.0), (true, 30.0), (false, 16.0)] {
            state.narratesNextRecording = narrating
            let entries = AppMenus.statusMenu(state)
            #expect(MenuMetrics.showsCheckmarkColumn(entries) == narrating)
            #expect(MenuMetrics.titleInset(among: entries) == inset, "narrating \(narrating)")
        }
        state.phase = .recording(startedAt: Self.start)
        #expect(MenuMetrics.titleInset(among: AppMenus.statusMenu(state)) == 16)
        state.phase = .idle
        #expect(MenuMetrics.titleInset(among: AppMenus.captureMenu(state)) == 16)
        state.narratesNextRecording = true
        #expect(MenuMetrics.titleInset(among: AppMenus.captureMenu(state)) == 30)
        // A checked item in a submenu doesn't move the parent level's titles.
        #expect(MenuMetrics.titleInset(among: [.submenu("More", [.toggle("On", isOn: true, .toggleNarration)])]) == 16)
        #expect(MenuMetrics.titleInset(among: []) == 16)
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
