import AppKit
import CoreGraphics
import ScreenCaptureKit
import UXReviewKit

/// A resolved capture target: everything ScreenCaptureKit needs, with no UI left to show.
enum CaptureSource: Equatable {
    /// A whole display, or `region` of it (display-local, top-left points).
    case display(id: CGDirectDisplayID, region: DisplayRegion?)
    /// One window, captured on its own (desktop-independent).
    case window(id: CGWindowID)
}

/// A captured still image plus the scale it was taken at.
struct CapturedImage {
    var image: CGImage
    var displayScale: Double
}

enum CaptureFailure: Error, Equatable, CustomStringConvertible {
    /// Screen Recording permission is missing or was denied.
    case permissionDenied
    /// The picker was dismissed (Esc, or a click without a drag).
    case cancelled
    /// The display or window to capture no longer exists.
    case targetUnavailable(String)
    case failed(String)

    var code: String {
        switch self {
        case .permissionDenied: "permissionDenied"
        case .cancelled: "cancelled"
        case .targetUnavailable: "targetUnavailable"
        case .failed: "captureFailed"
        }
    }

    var description: String {
        switch self {
        case .permissionDenied:
            "UX Review needs Screen Recording permission. Turn it on in System Settings › Privacy & Security › "
                + "Screen & System Audio Recording, then quit and reopen UX Review."
        case .cancelled: "Capture cancelled."
        case let .targetUnavailable(what): "\(what) is no longer available."
        case let .failed(message): "Capture failed: \(message)"
        }
    }
}

/// Produces pixels for a resolved source. The real backend uses ScreenCaptureKit; the synthetic
/// backend (`UXREVIEW_CAPTURE_BACKEND=synthetic`) renders a test card of the same pixel size so
/// the app's pipeline can be exercised end to end without Screen Recording permission.
@MainActor
protocol CaptureBackend {
    var name: String { get }
    /// Whether capture is allowed right now. Never shows UI.
    func hasPermission() -> Bool
    /// Asks the OS for permission, showing its prompt the first time. Returns the current state.
    func requestPermission() -> Bool
    func screenshot(_ source: CaptureSource) async throws -> CapturedImage
}

enum CaptureBackends {
    static func make(environment: [String: String] = ProcessInfo.processInfo.environment) -> CaptureBackend {
        environment["UXREVIEW_CAPTURE_BACKEND"] == "synthetic" ? SyntheticCaptureBackend() : ScreenCaptureKitBackend()
    }
}

@MainActor
struct ScreenCaptureKitBackend: CaptureBackend {
    let name = "screencapturekit"

    func hasPermission() -> Bool {
        CGPreflightScreenCaptureAccess()
    }

    func requestPermission() -> Bool {
        CGPreflightScreenCaptureAccess() || CGRequestScreenCaptureAccess()
    }

    func screenshot(_ source: CaptureSource) async throws -> CapturedImage {
        guard hasPermission() else { throw CaptureFailure.permissionDenied }
        let (filter, configuration) = try await Self.makeFilter(for: source)
        configuration.showsCursor = false
        do {
            let image = try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: configuration)
            return CapturedImage(image: image, displayScale: Double(filter.pointPixelScale))
        } catch {
            throw Self.map(error)
        }
    }

    /// Builds the content filter and an output configuration sized to native pixels. Shared with
    /// video recording. UX Review's own windows (picker, countdown) are always excluded.
    static func makeFilter(for source: CaptureSource) async throws -> (SCContentFilter, SCStreamConfiguration) {
        let content: SCShareableContent
        do {
            content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
        } catch {
            throw map(error)
        }
        let configuration = SCStreamConfiguration()
        configuration.captureResolution = .best
        switch source {
        case let .display(id, region):
            guard let display = content.displays.first(where: { $0.displayID == id }) else {
                throw CaptureFailure.targetUnavailable("The display")
            }
            let ours = content.applications.filter { $0.processID == ProcessInfo.processInfo.processIdentifier }
            let filter = SCContentFilter(display: display, excludingApplications: ours, exceptingWindows: [])
            let scale = Double(filter.pointPixelScale)
            if let region {
                configuration.sourceRect = region.sourceRect
                configuration.width = region.pixelWidth
                configuration.height = region.pixelHeight
            } else {
                let size = RegionGeometry.pixelSize(points: filter.contentRect.size, scale: scale)
                configuration.width = size.width
                configuration.height = size.height
            }
            return (filter, configuration)
        case let .window(id):
            guard let window = content.windows.first(where: { $0.windowID == id }) else {
                throw CaptureFailure.targetUnavailable("The window")
            }
            let filter = SCContentFilter(desktopIndependentWindow: window)
            let size = RegionGeometry.pixelSize(points: filter.contentRect.size, scale: Double(filter.pointPixelScale))
            configuration.width = size.width
            configuration.height = size.height
            configuration.ignoreShadowsSingleWindow = true
            return (filter, configuration)
        }
    }

    static func map(_ error: Error) -> CaptureFailure {
        if let failure = error as? CaptureFailure { return failure }
        let nsError = error as NSError
        if nsError.domain == SCStreamErrorDomain, nsError.code == SCStreamError.userDeclined.rawValue {
            return .permissionDenied
        }
        return .failed(nsError.localizedDescription)
    }
}

/// Renders a test card with the exact pixel size the real capture would have.
@MainActor
struct SyntheticCaptureBackend: CaptureBackend {
    let name = "synthetic"

    func hasPermission() -> Bool { true }
    func requestPermission() -> Bool { true }

    func screenshot(_ source: CaptureSource) async throws -> CapturedImage {
        let (width, height, scale) = try Self.pixelSize(for: source)
        guard let image = ImageFiles.testCard(width: width, height: height, label: Int(Date().timeIntervalSince1970)) else {
            throw CaptureFailure.failed("could not render the synthetic image")
        }
        return CapturedImage(image: image, displayScale: scale)
    }

    static func pixelSize(for source: CaptureSource) throws -> (Int, Int, Double) {
        switch source {
        case let .display(id, region):
            let screen = DisplayDirectory.screen(for: id)
            let scale = screen?.scale ?? 2
            if let region { return (region.pixelWidth, region.pixelHeight, scale) }
            let size = RegionGeometry.pixelSize(points: screen?.frame.size ?? CGSize(width: 1440, height: 900), scale: scale)
            return (size.width, size.height, scale)
        case let .window(id):
            guard let window = WindowDirectory.snapshot().first(where: { $0.windowID == id }) else {
                throw CaptureFailure.targetUnavailable("The window")
            }
            let scale = DisplayDirectory.scale(containingWindowServerRect: window.frame)
            let size = RegionGeometry.pixelSize(points: window.frame.size, scale: scale)
            return (size.width, size.height, scale)
        }
    }
}
