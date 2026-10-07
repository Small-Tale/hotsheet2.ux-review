import CoreGraphics
import Foundation
import Testing
@testable import UXReviewKit

struct CaptureRequestTests {
    @Test func delaysClampToTheSupportedRange() {
        #expect(CaptureRequest(delaySeconds: -3).delaySeconds == 0)
        #expect(CaptureRequest(delaySeconds: 5).delaySeconds == 5)
        #expect(CaptureRequest(delaySeconds: 600).delaySeconds == CaptureRequest.maxDelaySeconds)
    }

    @Test func countdownCountsDownToOne() {
        #expect(CaptureRequest(delaySeconds: 0).countdown.isEmpty)
        #expect(CaptureRequest(delaySeconds: 3).countdown == [3, 2, 1])
    }

    @Test func summaryDescribesTheRequest() {
        #expect(CaptureRequest(kind: .screenshot, target: .region).summary == "Screenshot of Region")
        #expect(CaptureRequest(kind: .video, target: .window, delaySeconds: 5).summary == "Video of Window after 5 s")
        #expect(CaptureRequest(target: .display, delaySeconds: 3).summary == "Screenshot of Screen after 3 s")
    }

    @Test func decodingFillsDefaultsAndClamps() throws {
        let decoder = JSONDecoder()
        #expect(try decoder.decode(CaptureRequest.self, from: Data("{}".utf8)) == CaptureRequest())
        let clamped = try decoder.decode(CaptureRequest.self, from: Data(#"{"kind":"video","target":"window","delaySeconds":999}"#.utf8))
        #expect(clamped == CaptureRequest(kind: .video, target: .window, delaySeconds: 60))
        let roundTrip = CaptureRequest(kind: .video, target: .display, delaySeconds: 10)
        #expect(try decoder.decode(CaptureRequest.self, from: JSONEncoder().encode(roundTrip)) == roundTrip)
    }

    @Test func delayPresetsAreWithinRange() {
        #expect(CaptureRequest.delayPresets.allSatisfy { CaptureRequest.clampDelay($0) == $0 })
        #expect(CaptureRequest.delayPresets.first == 0)
    }
}

struct RegionGeometryTests {
    /// A 1440×900 pt Retina primary display and a 1920×1080 pt 1x display to its right, top-aligned.
    let primary = ScreenGeometry(frame: CGRect(x: 0, y: 0, width: 1440, height: 900), scale: 2)
    let secondary = ScreenGeometry(frame: CGRect(x: 1440, y: -180, width: 1920, height: 1080), scale: 1)

    @Test func dragRectIsTheSameInEveryDirection() {
        let expected = CGRect(x: 10, y: 20, width: 90, height: 60)
        #expect(RegionGeometry.dragRect(from: CGPoint(x: 10, y: 20), to: CGPoint(x: 100, y: 80)) == expected)
        #expect(RegionGeometry.dragRect(from: CGPoint(x: 100, y: 80), to: CGPoint(x: 10, y: 20)) == expected)
        #expect(RegionGeometry.dragRect(from: CGPoint(x: 10, y: 80), to: CGPoint(x: 100, y: 20)) == expected)
    }

    @Test func flipsToTopLeftDisplayLocalPoints() throws {
        // 100×50 pt at AppKit (10, 800) on the primary: its top edge is 900 - 850 = 50 pt from the top.
        let region = try #require(RegionGeometry.displayRegion(forGlobal: CGRect(x: 10, y: 800, width: 100, height: 50), on: primary))
        #expect(region.sourceRect == CGRect(x: 10, y: 50, width: 100, height: 50))
        #expect(region.pixelWidth == 200)
        #expect(region.pixelHeight == 100)
    }

    @Test func secondaryDisplayIsLocalToItsOwnOrigin() throws {
        // Global AppKit rect on the right-hand display, whose frame starts at x 1440, y -180.
        let region = try #require(RegionGeometry.displayRegion(forGlobal: CGRect(x: 1500, y: 800, width: 200, height: 100), on: secondary))
        #expect(region.sourceRect == CGRect(x: 60, y: 0, width: 200, height: 100))
        #expect(region.pixelWidth == 200)
    }

    @Test func clipsToTheDisplay() throws {
        let region = try #require(RegionGeometry.displayRegion(forGlobal: CGRect(x: 1400, y: 880, width: 300, height: 300), on: primary))
        #expect(region.sourceRect == CGRect(x: 1400, y: 0, width: 40, height: 20))
        #expect(region.pixelWidth == 80)
        #expect(region.pixelHeight == 40)
    }

    @Test func snapsFractionalPointsOutwardToWholePixels() throws {
        // At 1x, 10.4…20.6 must grow to 10…21 so no pixel is cut in half.
        let region = try #require(RegionGeometry.displayRegion(
            forLocal: CGRect(x: 10.4, y: 10.4, width: 10.2, height: 10.2), displaySize: CGSize(width: 100, height: 100), scale: 1
        ))
        #expect(region.sourceRect == CGRect(x: 10, y: 10, width: 11, height: 11))
        #expect(region.pixelWidth == 11)
        // At 2x, 0.25 pt is half a pixel: the origin snaps down to 0 and the extent rounds up.
        let retina = try #require(RegionGeometry.displayRegion(
            forLocal: CGRect(x: 0.25, y: 0, width: 10, height: 10), displaySize: CGSize(width: 100, height: 100), scale: 2
        ))
        #expect(retina.sourceRect == CGRect(x: 0, y: 0, width: 10.5, height: 10))
        #expect(retina.pixelWidth == 21)
    }

    @Test func fractionalScaleNeverExceedsTheDisplay() throws {
        let size = CGSize(width: 1512, height: 982)
        let region = try #require(RegionGeometry.displayRegion(forLocal: CGRect(origin: .zero, size: size), displaySize: size, scale: 1.5))
        #expect(region.pixelWidth == 2268)
        #expect(region.pixelHeight == 1473)
        #expect(region.sourceRect.maxX <= size.width)
        #expect(region.sourceRect.maxY <= size.height)
    }

    @Test(arguments: [
        CGRect(x: 5000, y: 5000, width: 50, height: 50), // off every display
        CGRect(x: 10, y: 10, width: 3, height: 100), // too narrow: an accidental click
        CGRect(x: 10, y: 10, width: 100, height: 0),
        CGRect(x: 1438, y: 10, width: 100, height: 100), // only 2 pt left after clipping
    ])
    func rejectsRegionsTooSmallOrOffscreen(rect: CGRect) {
        #expect(RegionGeometry.displayRegion(forGlobal: rect, on: primary) == nil)
    }

    @Test func rejectsNonPositiveScale() {
        #expect(RegionGeometry.displayRegion(
            forLocal: CGRect(x: 0, y: 0, width: 10, height: 10),
            displaySize: CGSize(width: 50, height: 50),
            scale: 0
        ) == nil)
    }

    @Test func picksTheScreenContainingThePoint() {
        let screens = [primary, secondary]
        #expect(RegionGeometry.screenIndex(containing: CGPoint(x: 100, y: 100), in: screens) == 0)
        #expect(RegionGeometry.screenIndex(containing: CGPoint(x: 1440, y: 100), in: screens) == 1) // shared edge → right display
        #expect(RegionGeometry.screenIndex(containing: CGPoint(x: 2000, y: -100), in: screens) == 1)
        #expect(RegionGeometry.screenIndex(containing: CGPoint(x: -1, y: 100), in: screens) == nil)
    }

    @Test func pixelSizeRoundsAndIsAtLeastOne() {
        #expect(RegionGeometry.pixelSize(points: CGSize(width: 1440, height: 900), scale: 2) == (2880, 1800))
        #expect(RegionGeometry.pixelSize(points: CGSize(width: 0.1, height: 0), scale: 1) == (1, 1))
    }
}

struct WindowSelectionTests {
    static let ourPID: Int32 = 99

    /// Front to back: our own overlay, a tiny decoration, a menu-bar item (layer 25), Safari, Finder.
    let windows = [
        WindowSnapshot(
            windowID: 1,
            ownerPID: ourPID,
            ownerName: "UX Review",
            title: nil,
            layer: 0,
            frame: CGRect(x: 0, y: 0, width: 2000, height: 2000)
        ),
        WindowSnapshot(
            windowID: 2,
            ownerPID: 10,
            ownerName: "Safari",
            title: "tooltip",
            layer: 0,
            frame: CGRect(x: 100, y: 100, width: 20, height: 20)
        ),
        WindowSnapshot(
            windowID: 3,
            ownerPID: 11,
            ownerName: "Control Center",
            title: nil,
            layer: 25,
            frame: CGRect(x: 0, y: 0, width: 2000, height: 30)
        ),
        WindowSnapshot(
            windowID: 4,
            ownerPID: 10,
            ownerName: "Safari",
            title: "Settings",
            layer: 0,
            frame: CGRect(x: 50, y: 50, width: 800, height: 600)
        ),
        WindowSnapshot(
            windowID: 5,
            ownerPID: 12,
            ownerName: "Finder",
            title: "Desktop",
            layer: 0,
            frame: CGRect(x: 0, y: 0, width: 1400, height: 900)
        ),
        WindowSnapshot(
            windowID: 6,
            ownerPID: 12,
            ownerName: "Finder",
            title: "hidden",
            layer: 0,
            frame: CGRect(x: 0, y: 0, width: 400, height: 400),
            alpha: 0
        ),
    ]

    @Test func picksTheFrontmostOrdinaryWindowUnderThePoint() {
        #expect(WindowSelection.topmostWindow(at: CGPoint(x: 110, y: 110), in: windows, excludingPID: Self.ourPID)?.windowID == 4)
        #expect(WindowSelection.topmostWindow(at: CGPoint(x: 1000, y: 800), in: windows, excludingPID: Self.ourPID)?.windowID == 5)
        #expect(WindowSelection.topmostWindow(at: CGPoint(x: 1900, y: 1900), in: windows, excludingPID: Self.ourPID) == nil)
        // Without excluding our PID the overlay would win.
        #expect(WindowSelection.topmostWindow(at: CGPoint(x: 110, y: 110), in: windows, excludingPID: nil)?.windowID == 1)
    }

    @Test func frontWindowOfAnAppSkipsDecorations() {
        #expect(WindowSelection.frontWindow(ofPID: 10, in: windows)?.title == "Settings")
        #expect(WindowSelection.frontWindow(ofPID: 12, in: windows)?.title == "Desktop")
        #expect(WindowSelection.frontWindow(ofPID: 404, in: windows) == nil)
    }

    @Test func convertsBetweenAppKitAndWindowServerCoordinates() {
        #expect(WindowSelection.windowServerPoint(fromAppKit: CGPoint(x: 10, y: 890), primaryHeight: 900) == CGPoint(x: 10, y: 10))
        let rect = CGRect(x: 50, y: 50, width: 800, height: 600)
        let appKit = WindowSelection.appKitRect(fromWindowServer: rect, primaryHeight: 900)
        #expect(appKit == CGRect(x: 50, y: 250, width: 800, height: 600))
        #expect(WindowSelection.appKitRect(fromWindowServer: appKit, primaryHeight: 900) == rect)
    }

    @Test func readsWindowServerDictionaries() {
        let info: [String: Any] = [
            kCGWindowNumber as String: NSNumber(value: 42),
            kCGWindowOwnerPID as String: NSNumber(value: 7),
            kCGWindowOwnerName as String: "Notes",
            kCGWindowName as String: "Groceries",
            kCGWindowLayer as String: NSNumber(value: 0),
            kCGWindowAlpha as String: NSNumber(value: 1.0),
            kCGWindowBounds as String: CGRect(x: 1, y: 2, width: 300, height: 400).dictionaryRepresentation,
        ]
        #expect(WindowSnapshot(windowInfo: info) == WindowSnapshot(
            windowID: 42, ownerPID: 7, ownerName: "Notes", title: "Groceries", layer: 0, frame: CGRect(x: 1, y: 2, width: 300, height: 400)
        ))
        var missingBounds = info
        missingBounds[kCGWindowBounds as String] = nil
        #expect(WindowSnapshot(windowInfo: missingBounds) == nil)
    }
}

struct CaptureContextBuilderTests {
    @Test func formatsOSVersions() {
        #expect(
            CaptureContextBuilder
                .osVersionString(OperatingSystemVersion(majorVersion: 27, minorVersion: 0, patchVersion: 0)) == "macOS 27.0"
        )
        #expect(
            CaptureContextBuilder
                .osVersionString(OperatingSystemVersion(majorVersion: 14, minorVersion: 6, patchVersion: 1)) == "macOS 14.6.1"
        )
    }

    @Test func mapsAndCleansFields() {
        let context = CaptureContextBuilder.make(
            appName: "  Safari ", bundleIdentifier: "com.apple.Safari", windowTitle: "   ",
            osVersion: OperatingSystemVersion(majorVersion: 27, minorVersion: 1, patchVersion: 0), displayScale: 2
        )
        #expect(context == CaptureContext(
            appName: "Safari", bundleIdentifier: "com.apple.Safari", windowTitle: nil, url: nil, osVersion: "macOS 27.1", displayScale: 2
        ))
    }

    @Test func dropsUnknownValues() {
        let context = CaptureContextBuilder.make(
            appName: nil, bundleIdentifier: "", windowTitle: nil,
            osVersion: OperatingSystemVersion(majorVersion: 14, minorVersion: 0, patchVersion: 0), displayScale: 0
        )
        #expect(context == CaptureContext(osVersion: "macOS 14.0"))
        #expect(!context.isEmpty)
        #expect(CaptureContext().isEmpty)
    }
}

struct ImageFilesTests {
    @Test func writesAndReadsBackAPNG() throws {
        let dir = try TestSupport.makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("card.png")
        let image = try #require(ImageFiles.testCard(width: 64, height: 32, label: 3))
        try ImageFiles.writePNG(image, to: url)
        #expect(try ImageFiles.pixelSize(of: url) == (64, 32))
        #expect(try ImageFiles.loadImage(at: url).width == 64)
        #expect(try Data(contentsOf: url).prefix(4) == Data([0x89, 0x50, 0x4E, 0x47]))
    }

    @Test func reportsUnwritableAndUnreadablePaths() throws {
        let image = try #require(ImageFiles.testCard(width: 4, height: 4))
        let missingDir = URL(fileURLWithPath: "/nonexistent-\(UUID().uuidString)/card.png")
        #expect(throws: ImageFileError.self) { try ImageFiles.writePNG(image, to: missingDir) }
        #expect(throws: ImageFileError.unreadable(missingDir)) { try ImageFiles.pixelSize(of: missingDir) }
        #expect(ImageFiles.testCard(width: 0, height: 4) == nil)
    }
}

struct CaptureCommandTests {
    @Test func absentWithoutTheCaptureFlag() throws {
        #expect(try CaptureCommand.parse(["--status"]) == nil)
    }

    @Test func parsesAFullRegionCommand() throws {
        let command = try CaptureCommand.parse([
            "--capture", "screenshot", "--target", "region", "--delay", "3", "--display-id", "1",
            "--rect", "10, 20,300,200.5", "--drafts-dir", "/tmp/drafts", "--new-review",
        ])
        #expect(command == CaptureCommand(
            request: CaptureRequest(kind: .screenshot, target: .region, delaySeconds: 3),
            displayID: 1,
            rect: CGRect(x: 10, y: 20, width: 300, height: 200.5),
            draftsDirectory: URL(fileURLWithPath: "/tmp/drafts", isDirectory: true),
            newReview: true
        ))
    }

    @Test func defaultsToAnImmediateDisplayCapture() throws {
        let command = try #require(try CaptureCommand.parse(["--capture", "screenshot"]))
        #expect(command.request == CaptureRequest(kind: .screenshot, target: .display, delaySeconds: 0))
        #expect(!command.newReview)
        let window = try #require(try CaptureCommand.parse(["--capture", "screenshot", "--target", "window", "--window-id", "77"]))
        #expect(window.windowID == 77)
    }

    @Test(arguments: [
        (["--capture"], CommandLineError.missingValue("--capture")),
        (["--capture", "--target", "region"], CommandLineError.missingValue("--capture")),
        (["--capture", "gif"], CommandLineError.invalidValue("--capture", "gif")),
        (["--capture", "screenshot", "--target", "tab"], CommandLineError.invalidValue("--target", "tab")),
        (["--capture", "screenshot", "--delay", "61"], CommandLineError.invalidValue("--delay", "61")),
        (["--capture", "screenshot", "--delay", "-1"], CommandLineError.invalidValue("--delay", "-1")),
        (["--capture", "screenshot", "--target", "region"], CommandLineError.missing("--rect (required for --target region)")),
        (["--capture", "screenshot", "--target", "region", "--rect", "1,2,3"], CommandLineError.invalidValue("--rect", "1,2,3")),
        (["--capture", "screenshot", "--target", "region", "--rect", "1,2,0,4"], CommandLineError.invalidValue("--rect", "1,2,0,4")),
        (["--capture", "screenshot", "--rect", "1,2,3,4"], CommandLineError.invalidValue("--rect", "only valid with --target region")),
        (["--capture", "screenshot", "--window-id", "5"], CommandLineError.invalidValue("--window-id", "only valid with --target window")),
        (["--capture", "screenshot", "--display-id", "main"], CommandLineError.invalidValue("--display-id", "main")),
        (["--capture", "screenshot", "--drafts-dir"], CommandLineError.missingValue("--drafts-dir")),
    ])
    func rejectsBadArguments(arguments: [String], expected: CommandLineError) {
        #expect(throws: expected) { try CaptureCommand.parse(arguments) }
    }

    @Test func errorsDescribeThemselves() {
        #expect(CommandLineError.missingValue("--delay").description == "--delay needs a value")
        #expect(CommandLineError.invalidValue("--delay", "x").description == "Invalid --delay: x")
        #expect(CommandLineError.missing("--rect").description == "Missing --rect")
    }
}
