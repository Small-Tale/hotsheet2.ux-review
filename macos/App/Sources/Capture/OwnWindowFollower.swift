import AppKit
import ScreenCaptureKit
import UXReviewKit

/// Keeps a display or region recording's filter showing UX Review's own windows as they open and
/// close (HS2-XT5K63). Every `RecordingWindowExceptions.pollInterval` it reads the window list
/// (cheap), and only when the own non-chrome windows changed does it ask ScreenCaptureKit for the
/// shareable content and give the stream a rebuilt filter. Capture chrome stays out, as when the
/// recording started. Spec: docs/04-capture.md §4.3.
@MainActor
final class OwnWindowFollower {
    /// The recorded display and the exceptions its filter started with.
    struct Target {
        var displayID: CGDirectDisplayID
        var exceptions: Set<UInt32>
    }

    private let displayID: CGDirectDisplayID
    private var exceptions: RecordingWindowExceptions
    private let apply: @Sendable (SCContentFilter) async throws -> Void
    private var timer: Timer?

    /// `apply` hands a rebuilt filter to the running stream (`SCStream.updateContentFilter`).
    init(_ target: Target, apply: @escaping @Sendable (SCContentFilter) async throws -> Void) {
        displayID = target.displayID
        exceptions = RecordingWindowExceptions(applied: target.exceptions)
        self.apply = apply
    }

    func start() {
        let timer = Timer(timeInterval: RecordingWindowExceptions.pollInterval, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.check() }
        }
        // Common modes: keep following while a menu is open (the menu bar's Stop Recording).
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    func stop() {
        timer?.invalidate()
        timer = nil
    }

    private func check() {
        guard let kept = exceptions.check(
            WindowDirectory.snapshot(), ownPID: CaptureContextProvider.ownPID, chrome: CaptureChrome.windowIDs()
        ) else { return }
        Task { [displayID, apply] in
            let succeeded = await Self.update(displayID: displayID, keeping: kept, apply: apply)
            self.exceptions.finished(succeeded: succeeded)
        }
    }

    /// Rebuilds the display's filter from the current shareable content and hands it to the
    /// stream. Off the main actor, so the filter never crosses an isolation boundary.
    private nonisolated static func update(
        displayID: CGDirectDisplayID,
        keeping kept: Set<UInt32>,
        apply: @Sendable (SCContentFilter) async throws -> Void
    ) async -> Bool {
        guard let content = try? await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true),
              let display = content.displays.first(where: { $0.displayID == displayID }) else { return false }
        do {
            try await apply(ScreenCaptureKitBackend.displayFilter(display, in: content, keeping: kept))
            return true
        } catch {
            return false
        }
    }
}
