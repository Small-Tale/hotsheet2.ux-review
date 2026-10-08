import AppKit
import SwiftUI
import UXReviewKit

/// `UXReview --render-ui-previews <dir>`: renders UX Review's capture UI offscreen to PNGs for
/// visual QA without Screen Recording permission. Views are drawn over a test card standing in
/// for the reviewed app. Spec: docs/04-capture.md §4.11.
@MainActor
enum UIPreviews {
    final class FixedOverlayState: OverlayState {
        let mode: CaptureTarget
        let selection: CGRect?
        let hovered: WindowSnapshot?
        let hoveredFrame: CGRect?

        init(mode: CaptureTarget, selection: CGRect? = nil, hovered: WindowSnapshot? = nil, hoveredFrame: CGRect? = nil) {
            self.mode = mode
            self.selection = selection
            self.hovered = hovered
            self.hoveredFrame = hoveredFrame
        }
    }

    static func render(to directory: URL) throws -> [URL] {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let size = CGSize(width: 1280, height: 800)
        guard let screen = NSScreen.main else { throw CaptureFailure.targetUnavailable("A display") }
        let display = DisplayDirectory.Display(
            id: 1,
            screen: screen,
            geometry: ScreenGeometry(frame: CGRect(origin: .zero, size: size), scale: 2)
        )
        let window = WindowSnapshot(
            windowID: 1, ownerPID: 1, ownerName: "Safari", title: "Settings — Accounts", layer: 0,
            frame: CGRect(x: 240, y: 140, width: 760, height: 480)
        )
        let overlays: [(String, FixedOverlayState)] = [
            ("overlay-region-hint", FixedOverlayState(mode: .region)),
            ("overlay-window-hint", FixedOverlayState(mode: .window)),
            ("overlay-region-selection", FixedOverlayState(mode: .region, selection: CGRect(x: 320, y: 260, width: 420, height: 230))),
            (
                "overlay-region-selection-bottom-edge",
                FixedOverlayState(mode: .region, selection: CGRect(x: 40, y: 0, width: 300, height: 120))
            ),
            ("overlay-window-hover", FixedOverlayState(
                mode: .window, hovered: window, hoveredFrame: WindowSelection.appKitRect(
                    fromWindowServer: window.frame,
                    primaryHeight: size.height
                )
            )),
        ]
        var written = try [renderRecordingDim(size: size, to: directory)]
        for (name, state) in overlays {
            let view = OverlayView(display: display, session: nil, state: state)
            view.frame = CGRect(origin: .zero, size: size)
            written.append(try write(composite(view, size: size), to: directory.appendingPathComponent("\(name).png")))
        }
        written += try renderHUDs(to: directory)
        written += try renderSettings(to: directory)
        written += try renderStatusBarIcon(to: directory)
        written += try renderMenus(to: directory)
        written += try EditorPreviews.render(to: directory)
        written += try ReviewSessionPreviews.render(to: directory)
        written += try DraftsPreviews.render(to: directory)
        return written
    }

    private static func renderHUDs(to directory: URL) throws -> [URL] {
        let huds: [(String, HUDContent)] = [
            ("hud-countdown", HUDContent(title: "3", subtitle: "Capturing in…", large: true)),
            ("hud-saved", HUDContent(title: "Saved capture-2.png", subtitle: "2 captures in this review", large: false)),
            ("hud-recording-countdown", HUDContent(title: "5", subtitle: "Recording in…", large: true)),
            ("hud-recording", HUDContent(title: "Recording", subtitle: "Stop from the menu bar or press ⌥⇧⌘U", large: false)),
            ("hud-saved-video", HUDContent(title: "Saved capture-3.mov", subtitle: "0:12 · 3 captures in this review", large: false)),
            (
                "hud-recording-narration",
                HUDContent(title: "Recording", subtitle: "Microphone on. Stop from the menu bar or press ⌥⇧⌘V", large: false)
            ),
            (
                "hud-saved-narrated",
                HUDContent(title: "Saved capture-3.mov", subtitle: "0:12 · narrated · 3 captures in this review", large: false)
            ),
        ]
        var written: [URL] = []
        for (name, content) in huds {
            let renderer = ImageRenderer(content: content.padding(40).background(Color.clear))
            renderer.scale = 2
            guard let image = renderer.cgImage,
                  let card = ImageFiles.testCard(width: image.width, height: image.height, label: 5) else { continue }
            written.append(try write(overlay(image, on: card), to: directory.appendingPathComponent("\(name).png")))
        }
        return written
    }

    /// HS2-122ZFZ: the dim around a region while it is recorded (display-local, top-left).
    private static func renderRecordingDim(size: CGSize, to directory: URL) throws -> URL {
        let recorded = DisplayRegion(sourceRect: CGRect(x: 320, y: 220, width: 560, height: 320), pixelWidth: 1120, pixelHeight: 640)
        guard let layout = RecordingDim.layout(region: recorded, displaySize: size) else {
            throw CaptureFailure.failed("recording dim layout failed")
        }
        let view = RecordingDimView(frame: CGRect(origin: .zero, size: size), layout: layout)
        return try write(composite(view, size: size), to: directory.appendingPathComponent("recording-dim-region.png"))
    }

    final class MemoryStore: KeyValueStoring {
        var values: [String: Any] = [:]
        func data(forKey key: String) -> Data? { values[key] as? Data }
        func set(_ value: Any?, forKey key: String) { values[key] = value }
    }

    /// The Settings window twice: with its shortcuts registered, and with the same shortcuts
    /// already taken (the first model still holds them, so the second sees a real conflict).
    private static func renderSettings(to directory: URL) throws -> [URL] {
        let store = MemoryStore()
        try CaptureSettingsStore.save(
            CaptureSettings(
                defaultRequest: CaptureRequest(target: .region, delaySeconds: 3),
                captureHotkey: Hotkey("⌃⌥⌘8"),
                recordHotkey: Hotkey("⌃⌥⌘9")
            ),
            to: store
        )
        let owner = SettingsModel(store: store)
        let conflicted = SettingsModel(store: store)
        defer {
            owner.hotkeys.unregister()
            conflicted.hotkeys.unregister()
        }
        var written: [URL] = []
        for (name, model) in [("settings-registered", owner), ("settings-in-use", conflicted)] {
            let host = NSHostingView(rootView: SettingsView(model: model))
            let window = NSWindow(
                contentRect: CGRect(origin: .zero, size: host.fittingSize),
                styleMask: [.titled],
                backing: .buffered,
                defer: false
            )
            window.contentView = host
            host.layoutSubtreeIfNeeded()
            guard let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds) else { continue }
            host.cacheDisplay(in: host.bounds, to: rep)
            if let image = rep.cgImage {
                written.append(try write(image, to: directory.appendingPathComponent("\(name).png")))
            }
        }
        return written
    }

    /// The menu bar icon (idle and recording) on light and dark menu bar strips, at 4x so the
    /// template's detail can be inspected.
    private static func renderStatusBarIcon(to directory: URL) throws -> [URL] {
        guard let idle = StatusBarIcon.image(isRecording: false), let recording = StatusBarIcon.image(isRecording: true) else {
            throw CaptureFailure.failed("asset \(StatusBarIcon.assetName) missing from the app bundle")
        }
        var written: [URL] = []
        for (name, scheme) in [("status-bar-icon-light", ColorScheme.light), ("status-bar-icon-dark", .dark)] {
            let strip = HStack(spacing: 16) {
                Image(nsImage: idle).renderingMode(.template)
                Image(nsImage: recording).renderingMode(.template)
                Image(systemName: "wifi")
                Text("Wed 9:41").font(.system(size: 13))
            }
            .foregroundStyle(scheme == .dark ? Color.white : Color.black)
            .frame(height: 24)
            .padding(.horizontal, 12)
            .background(scheme == .dark ? Color(white: 0.16) : Color(white: 0.93))
            .environment(\.colorScheme, scheme)
            let renderer = ImageRenderer(content: strip)
            renderer.scale = 4
            if let image = renderer.cgImage {
                written.append(try write(image, to: directory.appendingPathComponent("\(name).png")))
            }
        }
        return written
    }

    /// The menus as JSON (`menus.json`: the menu bar menu idle and recording, and the app menu
    /// bar exactly as installed), plus the "Delayed [3 s | 10 s]" row drawn in light and dark.
    private static func renderMenus(to directory: URL) throws -> [URL] {
        let hotkeys: [HotkeySlot: Hotkey] = [.capture: .defaultCapture, .record: .defaultRecord]
        let idle = MenuState(hotkeys: hotkeys, version: AppSettings.version)
        let recording = MenuState(
            phase: .recording(startedAt: Date(timeIntervalSince1970: 0)),
            recordingNarration: true,
            hotkeys: hotkeys,
            version: AppSettings.version,
            now: Date(timeIntervalSince1970: 72)
        )
        func menu(_ entries: [MenuEntry]) -> NSMenu {
            let menu = NSMenu()
            MenuRendering.items(entries, perform: { _ in }).forEach(menu.addItem)
            return menu
        }
        MainMenu.install(captureEntries: { AppMenus.captureMenu(idle) }, perform: { _ in })
        let dump: [String: Any] = [
            "statusMenuIdle": MenuDump.describe(menu(AppMenus.statusMenu(idle))),
            "statusMenuRecording": MenuDump.describe(menu(AppMenus.statusMenu(recording))),
            "mainMenu": NSApp.mainMenu.map(MenuDump.describe) ?? [],
        ]
        let json = directory.appendingPathComponent("menus.json")
        try JSONSerialization.data(withJSONObject: dump, options: [.prettyPrinted, .sortedKeys]).write(to: json)
        var written = [json]
        guard case let .choices(title, choices)? = AppMenus.statusMenu(idle).compactMap({ entry -> [MenuEntry]? in
            if case let .submenu("Capture Image", children) = entry { return children }
            return nil
        }).first?.first(where: { if case .choices = $0 { true } else { false } }) else { return written }
        for (name, appearance) in [("menu-delayed-row-light", NSAppearance.Name.aqua), ("menu-delayed-row-dark", .darkAqua)] {
            let row = MenuChoicesView(title: title, choices: choices, perform: { _ in })
            let background = NSVisualEffectView(frame: CGRect(x: 0, y: 0, width: 240, height: 28))
            background.material = .menu
            background.state = .active
            background.appearance = NSAppearance(named: appearance)
            row.frame = background.bounds
            background.addSubview(row)
            background.layoutSubtreeIfNeeded()
            guard let rep = background.bitmapImageRepForCachingDisplay(in: background.bounds) else { continue }
            background.cacheDisplay(in: background.bounds, to: rep)
            if let image = rep.cgImage {
                written.append(try write(image, to: directory.appendingPathComponent("\(name).png")))
            }
        }
        return written
    }

    private static func composite(_ view: NSView, size _: CGSize) throws -> CGImage {
        guard let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { throw CaptureFailure.failed("no bitmap") }
        view.cacheDisplay(in: view.bounds, to: rep)
        guard let drawn = rep.cgImage, let card = ImageFiles.testCard(width: drawn.width, height: drawn.height, label: 2) else {
            throw CaptureFailure.failed("render failed")
        }
        return overlay(drawn, on: card)
    }

    private static func overlay(_ top: CGImage, on bottom: CGImage) -> CGImage {
        let rect = CGRect(x: 0, y: 0, width: bottom.width, height: bottom.height)
        guard let context = CGContext(
            data: nil, width: bottom.width, height: bottom.height, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue
        ) else { return bottom }
        context.draw(bottom, in: rect)
        context.draw(top, in: rect)
        return context.makeImage() ?? bottom
    }

    private static func write(_ image: CGImage, to url: URL) throws -> URL {
        try ImageFiles.writePNG(image, to: url)
        return url
    }
}
