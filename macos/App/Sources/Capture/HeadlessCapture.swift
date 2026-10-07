import AppKit
import UXReviewKit

/// `UXReview --capture …`: one capture (or a fixed-length recording) without any UI, printing a JSON result. Used by
/// scripts/app-e2e.sh. Exit codes: 0 captured, 2 bad arguments, 4 no Screen Recording
/// permission, 5 target unavailable or capture failed. Spec: docs/04-capture.md §4.11.
@MainActor
enum HeadlessCapture {
    struct Success: Encodable {
        var status = "captured"
        var backend: String
        var file: String
        var draftDirectory: String
        var media: MediaItem
        var bundleContext: CaptureContext
        var delayMs: Int
    }

    struct Failure: Encodable {
        var status = "error"
        var error: String
        var message: String
    }

    static func run(arguments: [String]) async -> Int32 {
        let command: CaptureCommand
        do {
            guard let parsed = try CaptureCommand.parse(arguments) else { return fail("invalidArguments", "missing --capture", code: 2) }
            command = parsed
        } catch {
            return fail("invalidArguments", String(describing: error), code: 2)
        }

        let backend = CaptureBackends.make()
        let store = ReviewDraftStore(root: command.draftsDirectory ?? AppSettings.draftsDirectory())
        guard backend.hasPermission() else { return fail(CaptureFailure.permissionDenied) }

        do {
            let source = try resolve(command)
            let started = Date()
            if command.request.delaySeconds > 0 {
                try await Task.sleep(for: .seconds(command.request.delaySeconds))
            }
            let delayMs = Int(Date().timeIntervalSince(started) * 1000)
            if command.newReview { try store.startNew() }
            let pipeline = CapturePipeline(backend: backend, store: store)
            let outcome: CaptureOutcome
            if command.request.kind == .video {
                let context = CaptureContextProvider.context(for: source, displayScale: nil)
                let startedAt = Date()
                let recording = try await backend.startRecording(source, to: CapturePipeline.temporaryMovieURL()) {}
                try await Task.sleep(for: .seconds(command.durationSeconds ?? 1))
                outcome = try await pipeline.addVideo(try recording.stop(), context: context, startedAt: startedAt)
            } else {
                outcome = try await pipeline.screenshot(source)
            }
            print(json(Success(
                backend: backend.name,
                file: outcome.fileURL.path,
                draftDirectory: outcome.draft.directory.path,
                media: outcome.media,
                bundleContext: outcome.draft.bundle.context,
                delayMs: delayMs
            )))
            return 0
        } catch let failure as CaptureFailure {
            return fail(failure)
        } catch let error as CommandLineError {
            return fail("invalidArguments", error.description, code: 2)
        } catch {
            return fail(CaptureFailure.failed(String(describing: error)))
        }
    }

    /// Turns the command's flags into a capture source without showing any picker.
    static func resolve(_ command: CaptureCommand) throws -> CaptureSource {
        switch command.request.target {
        case .display, .region:
            let id = command.displayID ?? CGMainDisplayID()
            guard let screen = DisplayDirectory.screen(for: id) else { throw CaptureFailure.targetUnavailable("Display \(id)") }
            guard let rect = command.rect else { return .display(id: id, region: nil) }
            guard let region = RegionGeometry.displayRegion(forLocal: rect, displaySize: screen.frame.size, scale: screen.scale) else {
                throw CommandLineError.invalidValue(
                    "--rect",
                    "region is off the display or smaller than \(Int(RegionGeometry.minimumSide)) pt"
                )
            }
            return .display(id: id, region: region)
        case .window:
            let windows = WindowDirectory.snapshot()
            if let id = command.windowID {
                guard windows.contains(where: { $0.windowID == id }) else { throw CaptureFailure.targetUnavailable("Window \(id)") }
                return .window(id: id)
            }
            guard let app = CaptureContextProvider.frontmostOtherApp(),
                  let window = WindowSelection.frontWindow(ofPID: app.processIdentifier, in: windows)
            else { throw CaptureFailure.targetUnavailable("The frontmost window") }
            return .window(id: window.windowID)
        }
    }

    private static func fail(_ failure: CaptureFailure) -> Int32 {
        fail(failure.code, failure.description, code: failure == .permissionDenied ? 4 : 5)
    }

    private static func fail(_ error: String, _ message: String, code: Int32) -> Int32 {
        print(json(Failure(error: error, message: message)))
        return code
    }

    static func json(_ value: some Encodable) -> String {
        let encoder = ReviewBundle.makeEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return (try? encoder.encode(value)).flatMap { String(data: $0, encoding: .utf8) } ?? "{}"
    }
}
