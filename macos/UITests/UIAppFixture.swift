import AppKit
import UXReviewKit
import XCTest

/// Real on-disk data and CLI, isolated from the developer's reviews, preferences and ticket store.
@MainActor
final class UIAppFixture {
    let app = XCUIApplication()
    let root: URL
    let project: URL
    let store: URL
    let drafts: ReviewDraftStore
    let image: URL
    let defaults: UserDefaults
    let cli: URL
    let executable: URL
    private let suite: String

    init() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("uxreview-ui-\(UUID().uuidString)")
        project = root.appendingPathComponent("project")
        store = root.appendingPathComponent("project.hs2")
        drafts = ReviewDraftStore(root: root.appendingPathComponent("drafts"))
        image = root.appendingPathComponent("fixture.png")
        suite = root.appendingPathComponent("defaults").path
        defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        cli = try XCTUnwrap(HotSheetLocator.findCLI(), "Install hotsheet-cli or set HOTSHEET_CLI")
        executable = URL(fileURLWithPath: try XCTUnwrap(ProcessInfo.processInfo.environment["UXREVIEW_UI_APP"]))
        var prepared = false
        defer {
            if !prepared {
                defaults.removePersistentDomain(forName: suite)
                defaults.synchronize()
                try? FileManager.default.removeItem(at: root)
            }
        }
        try FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)
        try ImageFiles.writePNG(XCTUnwrap(ImageFiles.testCard(width: 800, height: 500)), to: image)
        let settings = CaptureSettings(
            defaultRequest: CaptureRequest(kind: .screenshot, target: .display),
            captureHotkey: nil, recordHotkey: nil, openReviewHotkey: nil, downscaleForAI: false
        )
        try CaptureSettingsStore.save(settings, to: defaults)
        defaults.synchronize()
        app.launchArguments = ["--project", project.path, "-AppleLanguages", "(en)", "-AppleLocale", "en_US"]
        app.launchEnvironment = [
            "UXREVIEW_DEFAULTS_SUITE": suite, "UXREVIEW_DRAFTS_DIR": drafts.root.path,
            "UXREVIEW_TRASH_DIR": root.appendingPathComponent("trash").path,
            "HOTSHEET_HOME": root.appendingPathComponent("hotsheet-home").path,
            "HOTSHEET_CLI": cli.path, "HOTSHEET_STORE": store.path,
            "UXREVIEW_CAPTURE_BACKEND": "screenCaptureKit",
        ]
        _ = try run(cli, ["-C", store.path, "init"])
        prepared = true
    }

    func cleanup() {
        app.terminate()
        defaults.removePersistentDomain(forName: suite)
        defaults.synchronize()
        try? FileManager.default.removeItem(at: root)
    }

    @discardableResult
    func run(_ tool: URL, _ arguments: [String]) throws -> String {
        let result = try process(tool, arguments)
        XCTAssertEqual(result.exitCode, 0, "\(arguments.first ?? tool.lastPathComponent): \(result.stderr)")
        return result.stdout
    }

    func process(_ tool: URL, _ arguments: [String]) throws -> ProcessResult {
        var environment = ProcessInfo.processInfo.environment
        environment.merge(app.launchEnvironment) { _, new in new }
        environment["HOTSHEET_ACTOR_ROLE"] = nil
        environment["HOTSHEET_ACTOR_ID"] = nil
        return try SystemProcessRunner().run(executable: tool, arguments: arguments, environment: environment, currentDirectory: root)
    }

    func launch() {
        app.launch()
    }

    func openStatusMenu() {
        let status = app.statusItems["status-item"]
        XCTAssertTrue(status.waitForExistence(timeout: 10), "UX Review status item missing; check UI automation permissions")
        status.click()
    }

    func clickStatusEntry(_ title: String) {
        app.statusItems["status-item"].menuItems["menu-\(title)"].click()
    }

    func openEditor() -> XCUIElement {
        openStatusMenu()
        clickStatusEntry("Open UX Review")
        let canvas = app.groups["annotation-canvas"]
        XCTAssertTrue(canvas.waitForExistence(timeout: 10))
        app.activate()
        let editor = app.windows.containing(.group, identifier: "annotation-canvas").firstMatch
        editor.coordinate(withNormalizedOffset: CGVector(dx: 0.2, dy: 0.02)).click()
        XCTContext.runActivity(named: "Editor launch") { activity in
            let screenshot = XCTAttachment(screenshot: editor.screenshot())
            screenshot.name = "editor-opened"
            screenshot.lifetime = .keepAlways
            activity.add(screenshot)
        }
        return canvas
    }

    /// Import through the shipped File menu and NSOpenPanel, rather than injecting app model state.
    func importImage() -> XCUIElement {
        let canvas = openEditor()
        app.typeKey("o", modifierFlags: [.command, .shift])
        let panel = app.sheets["open-panel"]
        XCTAssertTrue(panel.waitForExistence(timeout: 5), app.debugDescription)
        app.typeKey("g", modifierFlags: [.command, .shift])
        let path = app.textFields["PathTextField"]
        XCTAssertTrue(path.waitForExistence(timeout: 5))
        path.typeKey("a", modifierFlags: .command)
        path.typeText(image.path)
        path.typeKey(.return, modifierFlags: [])
        let add = app.buttons["OKButton"]
        XCTAssertTrue(add.waitForExistence(timeout: 5), app.debugDescription)
        XCTAssertTrue(wait(timeout: 30) { add.isEnabled })
        add.click()
        XCTAssertTrue(wait { canvas.label.contains("capture-1.png") })
        return canvas
    }

    func openSubmit() -> XCUIElement {
        app.buttons["Submit Review…"].click()
        let window = app.windows["Submit Review"]
        XCTAssertTrue(window.waitForExistence(timeout: 10))
        return window
    }

    func tickets() throws -> [URL] {
        let enumerator = FileManager.default.enumerator(at: store.appendingPathComponent("tickets"), includingPropertiesForKeys: nil)
        return (enumerator?.allObjects as? [URL] ?? []).filter { $0.pathExtension == "md" }
    }

    func attachedBundles() throws -> [ReviewBundle] {
        let files = FileManager.default.enumerator(at: store.appendingPathComponent("attachments"), includingPropertiesForKeys: nil)
        return try (files?.allObjects as? [URL] ?? []).filter { $0.lastPathComponent == "review.json" }.map {
            try ReviewBundle.makeDecoder().decode(ReviewBundle.self, from: Data(contentsOf: $0))
        }
    }

    func verifyAttachedImage(_ bundle: ReviewBundle) throws {
        let media = try XCTUnwrap(bundle.media.first)
        XCTAssertEqual(bundle.media.count, 1)
        let files = FileManager.default.enumerator(at: store.appendingPathComponent("attachments"), includingPropertiesForKeys: nil)
        let matching = (files?.allObjects as? [URL] ?? []).filter { $0.lastPathComponent == media.filename }
        XCTAssertEqual(matching.count, 1)
        let attached = try XCTUnwrap(matching.first)
        let pixels = try ImageFiles.pixelSize(of: attached)
        XCTAssertEqual(pixels.width, media.pixelWidth)
        XCTAssertEqual(pixels.height, media.pixelHeight)
        XCTAssertEqual(try Data(contentsOf: attached), try Data(contentsOf: image))
    }

    @discardableResult
    func wait(timeout: TimeInterval = 10, _ condition: @escaping () -> Bool) -> Bool {
        let expectation = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in condition() }, object: nil)
        return XCTWaiter.wait(for: [expectation], timeout: timeout) == .completed
    }
}
