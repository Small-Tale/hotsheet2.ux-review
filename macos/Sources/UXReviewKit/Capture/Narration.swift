import AudioToolbox
import CoreMedia
import Foundation

/// Whether UX Review may record from the microphone right now. Mirrors
/// `AVAuthorizationStatus`, plus `unavailable` for a Mac with no audio input.
/// Spec: docs/04-capture.md §4.9.
public enum MicrophoneAccess: String, CaseIterable, Sendable {
    case authorized
    case notDetermined
    case denied
    case restricted
    case unavailable

    /// Why narration can't be recorded, for alerts and headless errors. Nil when authorized.
    public var problem: String? {
        switch self {
        case .authorized: nil
        case .notDetermined:
            "UX Review hasn't been given Microphone access yet. Start a recording with narration from the menu bar once to "
                + "answer the system prompt."
        case .denied:
            "UX Review needs Microphone permission to record narration. Turn it on in System Settings › Privacy & Security › "
                + "Microphone."
        case .restricted: "Microphone access is restricted on this Mac (for example by a device management profile)."
        case .unavailable: "No microphone is connected."
        }
    }
}

/// What to do about narration before a recording starts. Spec: docs/04-capture.md §4.9.
public enum NarrationPlan: Equatable, Sendable {
    /// Narration was not asked for: record video only.
    case off
    /// Record with the microphone.
    case record
    /// Show the system Microphone prompt, then decide again with its answer.
    case askPermission
    /// Narration is impossible; the app asks whether to record without it, headless mode fails.
    case blocked(MicrophoneAccess)

    /// `canPrompt` is false in headless mode, which never shows the system prompt.
    public static func decide(requested: Bool, access: MicrophoneAccess, canPrompt: Bool) -> NarrationPlan {
        guard requested else { return .off }
        switch access {
        case .authorized: return .record
        case .notDetermined: return canPrompt ? .askPermission : .blocked(.notDetermined)
        case .denied, .restricted, .unavailable: return .blocked(access)
        }
    }
}

/// A sine tone as LPCM sample buffers, standing in for a microphone in tests and in the
/// synthetic capture backend (`UXREVIEW_CAPTURE_BACKEND=synthetic`).
public enum SyntheticAudio {
    public static let sampleRate = 48000.0

    /// `count` mono 16-bit samples of a `frequency` Hz tone, starting at sample `firstSample` of
    /// the tone (so consecutive buffers join without a click), presented at `time`.
    public static func toneBuffer(at time: CMTime, firstSample: Int, count: Int, frequency: Double = 440) -> CMSampleBuffer? {
        guard count > 0 else { return nil }
        var description = AudioStreamBasicDescription(
            mSampleRate: sampleRate,
            mFormatID: kAudioFormatLinearPCM,
            mFormatFlags: kLinearPCMFormatFlagIsSignedInteger | kLinearPCMFormatFlagIsPacked,
            mBytesPerPacket: 2,
            mFramesPerPacket: 1,
            mBytesPerFrame: 2,
            mChannelsPerFrame: 1,
            mBitsPerChannel: 16,
            mReserved: 0
        )
        var format: CMAudioFormatDescription?
        guard CMAudioFormatDescriptionCreate(
            allocator: kCFAllocatorDefault, asbd: &description, layoutSize: 0, layout: nil,
            magicCookieSize: 0, magicCookie: nil, extensions: nil, formatDescriptionOut: &format
        ) == noErr, let format else { return nil }

        let samples = (0 ..< count).map { index in
            Int16(sin(2 * Double.pi * frequency * Double(firstSample + index) / sampleRate) * 8000)
        }
        let length = count * 2
        var block: CMBlockBuffer?
        guard CMBlockBufferCreateWithMemoryBlock(
            allocator: kCFAllocatorDefault, memoryBlock: nil, blockLength: length, blockAllocator: kCFAllocatorDefault,
            customBlockSource: nil, offsetToData: 0, dataLength: length, flags: kCMBlockBufferAssureMemoryNowFlag,
            blockBufferOut: &block
        ) == kCMBlockBufferNoErr, let block else { return nil }
        let copied = samples.withUnsafeBytes { bytes in
            CMBlockBufferReplaceDataBytes(with: bytes.baseAddress!, blockBuffer: block, offsetIntoDestination: 0, dataLength: length)
        }
        guard copied == kCMBlockBufferNoErr else { return nil }

        var buffer: CMSampleBuffer?
        guard CMAudioSampleBufferCreateReadyWithPacketDescriptions(
            allocator: kCFAllocatorDefault, dataBuffer: block, formatDescription: format, sampleCount: count,
            presentationTimeStamp: time, packetDescriptions: nil, sampleBufferOut: &buffer
        ) == noErr else { return nil }
        return buffer
    }
}
