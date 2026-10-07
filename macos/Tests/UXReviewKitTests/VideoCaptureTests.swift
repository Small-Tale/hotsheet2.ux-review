import CoreGraphics
import CoreMedia
import Foundation
import Testing
@testable import UXReviewKit

struct VideoCaptureTests {
    @Test func evenSizesTrimAtMostOnePixel() {
        #expect(RegionGeometry.evenPixelSize(width: 601, height: 400) == (600, 400))
        #expect(RegionGeometry.evenPixelSize(width: 1, height: 3) == (2, 2))
        let odd = DisplayRegion(sourceRect: CGRect(x: 10, y: 20, width: 100.5, height: 50.5), pixelWidth: 201, pixelHeight: 101)
        let even = odd.evenSized
        #expect(even.pixelWidth == 200)
        #expect(even.pixelHeight == 100)
        #expect(even.sourceRect == CGRect(x: 10, y: 20, width: 100, height: 50))
        let already = DisplayRegion(sourceRect: CGRect(x: 0, y: 0, width: 10, height: 10), pixelWidth: 20, pixelHeight: 20)
        #expect(already.evenSized == already)
    }

    @Test func videoCommandsNeedADuration() throws {
        let command = try #require(try CaptureCommand.parse([
            "--capture",
            "video",
            "--target",
            "display",
            "--duration",
            "2.5",
            "--delay",
            "1",
        ]))
        #expect(command.request == CaptureRequest(kind: .video, target: .display, delaySeconds: 1))
        #expect(command.durationSeconds == 2.5)
        #expect(throws: CommandLineError.missing("--duration (required for --capture video)")) {
            try CaptureCommand.parse(["--capture", "video"])
        }
        #expect(throws: CommandLineError.invalidValue("--duration", "only valid with --capture video")) {
            try CaptureCommand.parse(["--capture", "screenshot", "--duration", "2"])
        }
        for bad in ["0", "-1", "601", "soon"] {
            #expect(throws: CommandLineError.invalidValue("--duration", bad)) {
                try CaptureCommand.parse(["--capture", "video", "--duration", bad])
            }
        }
    }

    /// Writes a real movie: 10 fps of frames for 1.5 s, then stops at 2.0 s as if the screen had
    /// stopped changing. The movie must last until the stop, not the last frame.
    @Test(.timeLimit(.minutes(1)))
    func writesAMovieThatEndsAtTheStopTime() async throws {
        let dir = try TestSupport.makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("clip.mov")
        let writer = try VideoFileWriter(url: url, width: 160, height: 90, framesPerSecond: 10)
        let card = try #require(ImageFiles.testCard(width: 160, height: 90))
        let frame = try #require(VideoFileWriter.pixelBuffer(from: card, width: 160, height: 90))
        let base = CMTime(seconds: 1000, preferredTimescale: 600) // host-clock-like, not zero
        for index in 0 ..< 16 {
            let time = CMTimeAdd(base, CMTime(value: CMTimeValue(index * 60), timescale: 600))
            while !writer.append(frame, at: time) {
                try await Task.sleep(for: .milliseconds(5)) // encoder busy: retry (tests only)
                if writer.framesDropped > 500 { Issue.record("encoder never became ready"); return }
            }
        }
        #expect(writer.framesWritten == 16)
        #expect(!writer.append(frame, at: base)) // out of order: dropped
        let durationMs = try await writer.finish(at: CMTimeAdd(base, CMTime(seconds: 2, preferredTimescale: 600)))
        #expect(durationMs == 2000)

        let inspected = try await VideoFileWriter.inspect(url)
        #expect(inspected.width == 160)
        #expect(inspected.height == 90)
        #expect(abs(inspected.durationMs - 2000) <= 50)
        #expect(!writer.append(frame, at: CMTimeAdd(base, CMTime(seconds: 3, preferredTimescale: 600)))) // after finish
        await #expect(throws: VideoWriterError.failed("already finished")) { _ = try await writer.finish(at: base) }
    }

    @Test(.timeLimit(.minutes(1)))
    func finishingWithoutFramesFailsAndLeavesNoFile() async throws {
        let dir = try TestSupport.makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("empty.mov")
        let writer = try VideoFileWriter(url: url, width: 2, height: 2)
        await #expect(throws: VideoWriterError.noFrames) { _ = try await writer.finish(at: .zero) }
        #expect(!FileManager.default.fileExists(atPath: url.path))
    }

    @Test func rejectsOddOrTinySizes() {
        let url = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("\(UUID().uuidString).mov")
        #expect(throws: VideoWriterError.self) { try VideoFileWriter(url: url, width: 161, height: 90) }
        #expect(throws: VideoWriterError.self) { try VideoFileWriter(url: url, width: 0, height: 0) }
    }
}

/// Transition matrix for `CapturePhase`: every phase × every event, then realistic and
/// adversarial sequences.
struct CapturePhaseTests {
    static let instant = CaptureRequest(kind: .screenshot, target: .region, delaySeconds: 0)
    static let delayed = CaptureRequest(kind: .video, target: .display, delaySeconds: 2)
    static let date = Date(timeIntervalSince1970: 0)

    static let phases: [CapturePhase] = [
        .idle, .picking(delayed), .countingDown(delayed, remaining: 2), .capturing, .recording(startedAt: date), .finishing,
    ]
    static let events: [CapturePhase.Event] = [
        .start(delayed), .picked, .tick, .recordingStarted(date), .stopRequested, .finished, .cancelled, .failed,
    ]

    @Test func fullMatrix() {
        let expected: [String: CapturePhase] = [
            "idle/start": .picking(Self.delayed),
            "picking/picked": .countingDown(Self.delayed, remaining: 2),
            "picking/cancelled": .idle, "picking/failed": .idle,
            "countingDown/tick": .countingDown(Self.delayed, remaining: 1),
            "countingDown/cancelled": .idle, "countingDown/failed": .idle,
            "capturing/recordingStarted": .recording(startedAt: Self.date),
            "capturing/finished": .idle, "capturing/failed": .idle,
            "recording/stopRequested": .finishing, "recording/failed": .finishing,
            "finishing/finished": .idle, "finishing/failed": .idle,
        ]
        var valid = 0
        for phase in Self.phases {
            for event in Self.events {
                let key = "\(Self.name(phase))/\(Self.name(event))"
                #expect(phase.next(event) == expected[key], "\(key)")
                if phase.next(event) != nil { valid += 1 }
            }
        }
        #expect(valid == expected.count)
    }

    @Test func screenshotWithoutDelaySkipsTheCountdown() {
        #expect(CapturePhase.picking(Self.instant).next(.picked) == .capturing)
    }

    @Test func videoLifeCycleWithCountdown() throws {
        var phase = CapturePhase.idle
        for event: CapturePhase.Event in [
            .start(Self.delayed),
            .picked,
            .tick,
            .tick,
            .recordingStarted(Self.date),
            .stopRequested,
            .finished,
        ] {
            phase = try #require(phase.next(event), "\(phase) rejected \(event)")
        }
        #expect(phase == .idle)
    }

    @Test func adversarialSequencesAreRejected() throws {
        // A second start while busy, a stop while counting down, a double stop, and ticks after
        // the countdown ended are all ignored (nil) rather than corrupting the state.
        #expect(CapturePhase.recording(startedAt: Self.date).next(.start(Self.instant)) == nil)
        #expect(CapturePhase.countingDown(Self.delayed, remaining: 1).next(.stopRequested) == nil)
        #expect(CapturePhase.finishing.next(.stopRequested) == nil)
        #expect(CapturePhase.capturing.next(.tick) == nil)
        // A recording is never cancelled into the void: cancel is ignored, stop saves it.
        #expect(CapturePhase.recording(startedAt: Self.date).next(.cancelled) == nil)
        // Empty → refill: after finishing, a new capture can start.
        let afterFinish = try #require(CapturePhase.finishing.next(.finished))
        #expect(afterFinish.next(.start(Self.instant)) == .picking(Self.instant))
    }

    @Test func flags() {
        #expect(CapturePhase.idle.isIdle)
        #expect(CapturePhase.countingDown(Self.delayed, remaining: 1).isCountingDown)
        #expect(CapturePhase.recording(startedAt: Self.date).isRecording)
        #expect(!CapturePhase.finishing.isRecording)
    }

    static func name(_ phase: CapturePhase) -> String {
        String(describing: phase).components(separatedBy: "(").first ?? ""
    }

    static func name(_ event: CapturePhase.Event) -> String {
        String(describing: event).components(separatedBy: "(").first ?? ""
    }
}
