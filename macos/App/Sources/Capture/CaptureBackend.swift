import AppKit
import AVFoundation
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
    /// Narration was asked for but the microphone can't be used (docs/04 §4.9).
    case microphone(MicrophoneAccess)
    case failed(String)

    var code: String {
        switch self {
        case .permissionDenied: "permissionDenied"
        case .microphone(.unavailable): "microphoneUnavailable"
        case .microphone: "microphonePermissionDenied"
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
        case let .microphone(access): access.problem ?? "The microphone could not be used."
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
    /// Whether narration can be recorded right now. Never shows UI.
    func microphoneAccess() -> MicrophoneAccess
    /// Shows the system Microphone prompt (only while `notDetermined`). Returns whether access was granted.
    func requestMicrophoneAccess() async -> Bool
    /// Starts recording `source` into a QuickTime movie at `url`, with a microphone narration
    /// track when `narration` is set (access must already be granted). `onUnexpectedStop` runs on
    /// the main actor if the recording ends by itself (display unplugged, window closed).
    func startRecording(
        _ source: CaptureSource,
        to url: URL,
        narration: Bool,
        onUnexpectedStop: @escaping @MainActor () -> Void
    ) async throws -> ActiveRecording
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

    func microphoneAccess() -> MicrophoneAccess {
        guard AVCaptureDevice.default(for: .audio) != nil else { return .unavailable }
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized: return .authorized
        case .notDetermined: return .notDetermined
        case .restricted: return .restricted
        default: return .denied
        }
    }

    func requestMicrophoneAccess() async -> Bool {
        await AVCaptureDevice.requestAccess(for: .audio)
    }

    func startRecording(
        _ source: CaptureSource,
        to url: URL,
        narration: Bool,
        onUnexpectedStop: @escaping @MainActor () -> Void
    ) async throws -> ActiveRecording {
        guard hasPermission() else { throw CaptureFailure.permissionDenied }
        if narration, microphoneAccess() != .authorized { throw CaptureFailure.microphone(microphoneAccess()) }
        let (filter, configuration) = try await Self.makeFilter(for: source)
        return try await StreamRecorder.start(
            filter: filter,
            configuration: configuration,
            url: url,
            narration: narration,
            onUnexpectedStop: onUnexpectedStop
        )
    }

    nonisolated static func map(_ error: Error) -> CaptureFailure {
        if let failure = error as? CaptureFailure { return failure }
        let nsError = error as NSError
        if nsError.domain == SCStreamErrorDomain, nsError.code == SCStreamError.userDeclined.rawValue {
            return .permissionDenied
        }
        return .failed(nsError.localizedDescription)
    }
}

/// Renders a test card with the exact pixel size the real capture would have, and stands in a
/// sine tone for the microphone. `UXREVIEW_SYNTHETIC_MICROPHONE` (a `MicrophoneAccess` raw value,
/// default `authorized`) simulates the microphone's permission state for tests.
@MainActor
struct SyntheticCaptureBackend: CaptureBackend {
    let name = "synthetic"
    var microphone: MicrophoneAccess = ProcessInfo.processInfo.environment["UXREVIEW_SYNTHETIC_MICROPHONE"]
        .flatMap(MicrophoneAccess.init(rawValue:)) ?? .authorized

    func hasPermission() -> Bool { true }
    func requestPermission() -> Bool { true }
    func microphoneAccess() -> MicrophoneAccess { microphone }
    func requestMicrophoneAccess() async -> Bool { microphone == .authorized }

    func screenshot(_ source: CaptureSource) async throws -> CapturedImage {
        let (width, height, scale) = try Self.pixelSize(for: source)
        guard let image = ImageFiles.testCard(width: width, height: height, label: Int(Date().timeIntervalSince1970)) else {
            throw CaptureFailure.failed("could not render the synthetic image")
        }
        return CapturedImage(image: image, displayScale: scale)
    }

    func startRecording(
        _ source: CaptureSource,
        to url: URL,
        narration: Bool,
        onUnexpectedStop _: @escaping @MainActor () -> Void
    ) async throws -> ActiveRecording {
        if narration, microphone != .authorized { throw CaptureFailure.microphone(microphone) }
        let (width, height, scale) = try Self.pixelSize(for: source)
        return try SyntheticRecorder(url: url, width: width, height: height, scale: scale, narration: narration)
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
