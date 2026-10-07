import CoreMedia
import Foundation
import Testing
@testable import UXReviewKit

extension EncodingTests {

    /// Microphone narration (HS2-T0EY2W): the audio track of `VideoFileWriter`, fed with synthetic
    /// LPCM buffers on the same host-like clock as the frames, plus the permission decision.
    struct NarrationTests {
        static let base = CMTime(seconds: 1000, preferredTimescale: 48000) // host-clock-like, not zero
        static let chunk = 4800 // 100 ms at 48 kHz

        static func at(_ seconds: Double) -> CMTime {
            CMTimeAdd(base, CMTime(seconds: seconds, preferredTimescale: 48000))
        }

        /// Appends, retrying while the encoder is busy (tests feed faster than real time). A writer
        /// that never becomes ready again (a stalled input) fails the test instead of hanging.
        static func eventually(_ append: () -> Bool) async throws -> Bool {
            for _ in 0 ..< 400 {
                if append() { return true }
                try await Task.sleep(for: .milliseconds(5))
            }
            return false
        }

        static func makeWriter(_ url: URL, audio: AudioTrackFormat? = .narration) throws -> (VideoFileWriter, CVPixelBuffer) {
            let writer = try VideoFileWriter(url: url, width: 160, height: 90, framesPerSecond: 10, audio: audio)
            let card = try #require(ImageFiles.testCard(width: 160, height: 90))
            return (writer, try #require(VideoFileWriter.pixelBuffer(from: card, width: 160, height: 90)))
        }

        /// Writes 100 ms tone chunks covering `from ..< to` seconds (relative to `base`).
        static func feedAudio(_ writer: VideoFileWriter, from: Double, until end: Double) async throws -> (written: Int, refused: Int) {
            var written = 0, refused = 0
            var index = Int((from * 10).rounded())
            while Double(index) / 10 < end - 0.0001 {
                let buffer = try #require(SyntheticAudio.toneBuffer(at: at(Double(index) / 10), firstSample: index * chunk, count: chunk))
                if Double(index) / 10 < 0 {
                    if !writer.appendAudio(buffer) { refused += 1 } // before the first frame: refused, no retry
                } else if try await eventually({ writer.appendAudio(buffer) }) {
                    written += 1
                } else {
                    Issue.record("audio input stalled at \(Double(index) / 10) s")
                    return (written, refused)
                }
                index += 1
            }
            return (written, refused)
        }

        /// Audio starts before the first frame and runs past the stop time. The movie's audio must
        /// start with the video (earlier audio dropped) and end at the stop time (later audio trimmed).
        @Test(.timeLimit(.minutes(1)))
        func narrationStartsAndEndsWithTheVideo() async throws {
            let dir = try TestSupport.makeTempDirectory()
            defer { try? FileManager.default.removeItem(at: dir) }
            let url = dir.appendingPathComponent("narrated.mov")
            let (writer, frame) = try Self.makeWriter(url)

            // Audio that arrives before any frame has no session to land in.
            let early = try #require(SyntheticAudio.toneBuffer(at: Self.at(-0.3), firstSample: 0, count: Self.chunk))
            #expect(!writer.appendAudio(early))
            for index in 0 ..< 16 { // frames 0…1.5 s, then the screen goes static
                let appended = try await Self.eventually { writer.append(frame, at: Self.at(Double(index) / 10)) }
                #expect(appended)
            }
            let fed = try await Self.feedAudio(writer, from: -0.2, until: 2.3)
            #expect(fed.refused == 2)
            #expect(fed.written == 23)
            #expect(writer.hasAudio)
            #expect(writer.audioBuffersWritten == 23)
            #expect(writer.audioBuffersDropped >= 3)

            let durationMs = try await writer.finish(at: Self.at(2))
            #expect(durationMs == 2000)
            let video = try await VideoFileWriter.inspect(url)
            #expect(abs(video.durationMs - 2000) <= 50)
            let inspected = try await VideoFileWriter.inspectAudio(url)
            let audio = try #require(inspected)
            #expect(abs(audio.startMs) <= 30, "audio starts at \(audio.startMs) ms")
            #expect(abs(audio.startMs + audio.durationMs - video.durationMs) <= 60, "audio \(audio), video \(video.durationMs) ms")
        }

        /// A static screen sends one frame and then nothing for seconds while the microphone keeps
        /// going. The audio input must keep accepting buffers (no interleaving stall).
        @Test(.timeLimit(.minutes(1)))
        func narrationContinuesThroughAStaticScreen() async throws {
            let dir = try TestSupport.makeTempDirectory()
            defer { try? FileManager.default.removeItem(at: dir) }
            let url = dir.appendingPathComponent("static.mov")
            let (writer, frame) = try Self.makeWriter(url)
            #expect(writer.append(frame, at: Self.base))
            let fed = try await Self.feedAudio(writer, from: 0, until: 3)
            #expect(fed.written == 30)
            let durationMs = try await writer.finish(at: Self.at(3))
            #expect(durationMs == 3000)
            let inspected = try await VideoFileWriter.inspectAudio(url)
            let audio = try #require(inspected)
            #expect(abs(audio.durationMs - 3000) <= 60, "audio \(audio)")
            #expect(writer.framesWritten == 1)
        }

        /// Regression: with an audio track, AVAssetWriter ended the movie at the last sample, so audio
        /// that stopped early (microphone unplugged) on a static screen cut the movie short. The
        /// writer now holds the last frame until the stop time.
        @Test(.timeLimit(.minutes(1)))
        func audioEndingEarlyDoesNotShortenTheMovie() async throws {
            let dir = try TestSupport.makeTempDirectory()
            defer { try? FileManager.default.removeItem(at: dir) }
            let url = dir.appendingPathComponent("early-end.mov")
            let (writer, frame) = try Self.makeWriter(url)
            #expect(writer.append(frame, at: Self.base))
            _ = try await Self.feedAudio(writer, from: 0, until: 0.3)
            let durationMs = try await writer.finish(at: Self.at(2))
            #expect(durationMs == 2000)
            let video = try await VideoFileWriter.inspect(url)
            #expect(abs(video.durationMs - 2000) <= 50, "video \(video.durationMs) ms")
            let inspected = try await VideoFileWriter.inspectAudio(url)
            let audio = try #require(inspected)
            #expect(abs(audio.durationMs - 300) <= 40, "audio \(audio)")
        }

        /// Narration was on but no audio ever arrived (a silent or failed microphone): the movie is
        /// still written, just without narration.
        @Test(.timeLimit(.minutes(1)))
        func narrationWithoutAnyAudioStillWritesTheMovie() async throws {
            let dir = try TestSupport.makeTempDirectory()
            defer { try? FileManager.default.removeItem(at: dir) }
            let url = dir.appendingPathComponent("silent.mov")
            let (writer, frame) = try Self.makeWriter(url)
            #expect(writer.append(frame, at: Self.base))
            let durationMs = try await writer.finish(at: Self.at(1))
            #expect(durationMs == 1000)
            #expect(!writer.hasAudio)
            let video = try await VideoFileWriter.inspect(url)
            #expect(abs(video.durationMs - 1000) <= 50)
            let audio = try await VideoFileWriter.inspectAudio(url)
            #expect(audio == nil || audio?.durationMs == 0)
        }

        /// Without an audio track, out of order, and after finishing: refused and counted.
        @Test(.timeLimit(.minutes(1)))
        func refusesAudioItCannotWrite() async throws {
            let dir = try TestSupport.makeTempDirectory()
            defer { try? FileManager.default.removeItem(at: dir) }
            let tone = try #require(SyntheticAudio.toneBuffer(at: Self.at(0.5), firstSample: 0, count: Self.chunk))

            let (videoOnly, frame) = try Self.makeWriter(dir.appendingPathComponent("plain.mov"), audio: nil)
            #expect(videoOnly.append(frame, at: Self.base))
            #expect(!videoOnly.appendAudio(tone))
            #expect(videoOnly.audioBuffersDropped == 1)
            _ = try await videoOnly.finish(at: Self.at(1))
            let plainAudio = try await VideoFileWriter.inspectAudio(dir.appendingPathComponent("plain.mov"))
            #expect(plainAudio == nil)

            let url = dir.appendingPathComponent("narrated.mov")
            let (writer, frame2) = try Self.makeWriter(url)
            #expect(writer.append(frame2, at: Self.base))
            let toneAppended = try await Self.eventually { writer.appendAudio(tone) }
            #expect(toneAppended)
            #expect(!writer.appendAudio(tone)) // same time again
            let earlier = try #require(SyntheticAudio.toneBuffer(at: Self.at(0.2), firstSample: 0, count: Self.chunk))
            #expect(!writer.appendAudio(earlier)) // out of order
            _ = try await writer.finish(at: Self.at(1))
            let late = try #require(SyntheticAudio.toneBuffer(at: Self.at(0.9), firstSample: 0, count: Self.chunk))
            #expect(!writer.appendAudio(late)) // after finish
            #expect(writer.audioBuffersWritten == 1)
            #expect(writer.audioBuffersDropped == 3)
        }

        /// Trimming a narrated recording in the editor keeps its narration.
        @Test(.timeLimit(.minutes(1)))
        func trimmingKeepsNarration() async throws {
            let dir = try TestSupport.makeTempDirectory()
            defer { try? FileManager.default.removeItem(at: dir) }
            let url = dir.appendingPathComponent("narrated.mov")
            let (writer, frame) = try Self.makeWriter(url)
            for index in 0 ..< 20 {
                let appended = try await Self.eventually { writer.append(frame, at: Self.at(Double(index) / 10)) }
                #expect(appended)
            }
            _ = try await Self.feedAudio(writer, from: 0, until: 2)
            _ = try await writer.finish(at: Self.at(2))
            let trimmed = dir.appendingPathComponent("trimmed.mov")
            try VideoTrim.export(url, range: TimeRange(startMs: 500, endMs: 1500), to: trimmed)
            let inspected = try await VideoFileWriter.inspectAudio(trimmed)
            let audio = try #require(inspected)
            #expect(abs(audio.durationMs - 1000) <= 80, "audio \(audio)")
        }

        @Test func toneBuffersAreContiguousLPCM() throws {
            let buffer = try #require(SyntheticAudio.toneBuffer(at: Self.base, firstSample: 0, count: Self.chunk))
            #expect(CMSampleBufferGetNumSamples(buffer) == Self.chunk)
            #expect(CMSampleBufferGetPresentationTimeStamp(buffer) == Self.base)
            #expect(abs(CMTimeGetSeconds(CMSampleBufferGetDuration(buffer)) - 0.1) < 0.0001)
            let format = try #require(CMSampleBufferGetFormatDescription(buffer))
            let description = try #require(CMAudioFormatDescriptionGetStreamBasicDescription(format)?.pointee)
            #expect(description.mSampleRate == 48000)
            #expect(description.mChannelsPerFrame == 1)
            #expect(SyntheticAudio.toneBuffer(at: Self.base, firstSample: 0, count: 0) == nil)
        }

        /// Every (requested, access, canPrompt) combination.
        @Test func narrationPlanMatrix() {
            for access in MicrophoneAccess.allCases {
                for canPrompt in [true, false] {
                    #expect(NarrationPlan.decide(requested: false, access: access, canPrompt: canPrompt) == .off)
                    let expected: NarrationPlan = switch access {
                    case .authorized: .record
                    case .notDetermined: canPrompt ? .askPermission : .blocked(.notDetermined)
                    default: .blocked(access)
                    }
                    #expect(
                        NarrationPlan.decide(requested: true, access: access, canPrompt: canPrompt) == expected,
                        "\(access) \(canPrompt)"
                    )
                }
            }
            #expect(MicrophoneAccess.authorized.problem == nil)
            #expect(MicrophoneAccess.denied.problem?.contains("System Settings") == true)
            #expect(MicrophoneAccess.allCases.filter { $0.problem == nil } == [.authorized])
        }
    }
}
