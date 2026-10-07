import CoreGraphics
import Foundation

/// Headless capture invocation of the app, used by scripts and end-to-end tests:
///
///     UXReview --capture screenshot|video [--target display|window|region] [--delay N] [--duration S]
///              [--display-id N] [--window-id N] [--rect x,y,w,h]
///              [--drafts-dir DIR] [--new-review]
///
/// There is no interactive picking: `region` needs `--rect` (display-local, top-left points),
/// and `window` uses `--window-id` or else the frontmost app's front window. Video needs
/// `--duration` (seconds, up to `maxDurationSeconds`). Spec: docs/04 §4.11.
public struct CaptureCommand: Equatable, Sendable {
    public var request: CaptureRequest
    public var displayID: UInt32?
    public var windowID: UInt32?
    public var rect: CGRect?
    public var draftsDirectory: URL?
    public var newReview: Bool
    /// Video only: how long to record, in seconds.
    public var durationSeconds: Double?

    public static let maxDurationSeconds: Double = 600

    public init(
        request: CaptureRequest,
        displayID: UInt32? = nil,
        windowID: UInt32? = nil,
        rect: CGRect? = nil,
        draftsDirectory: URL? = nil,
        newReview: Bool = false,
        durationSeconds: Double? = nil
    ) {
        self.request = request
        self.displayID = displayID
        self.windowID = windowID
        self.rect = rect
        self.draftsDirectory = draftsDirectory
        self.newReview = newReview
        self.durationSeconds = durationSeconds
    }

    /// Parses the arguments after the executable. Returns nil when `--capture` is absent.
    public static func parse(_ arguments: [String]) throws -> CaptureCommand? {
        guard let captureIndex = arguments.firstIndex(of: "--capture") else { return nil }
        let values = ArgumentValues(arguments)
        let kindText = try values.value(after: captureIndex, flag: "--capture")
        guard let kind = CaptureKind(rawValue: kindText) else { throw CommandLineError.invalidValue("--capture", kindText) }

        let target = try values.optional("--target").map { text in
            guard let target = CaptureTarget(rawValue: text) else { throw CommandLineError.invalidValue("--target", text) }
            return target
        } ?? .display
        let delay = try values.optional("--delay").map { text in
            guard let seconds = Int(text), (0 ... CaptureRequest.maxDelaySeconds).contains(seconds) else {
                throw CommandLineError.invalidValue("--delay", text)
            }
            return seconds
        } ?? 0

        var command = CaptureCommand(request: CaptureRequest(kind: kind, target: target, delaySeconds: delay))
        command.displayID = try values.optional("--display-id").map { try parseID($0, flag: "--display-id") }
        command.windowID = try values.optional("--window-id").map { try parseID($0, flag: "--window-id") }
        command.rect = try values.optional("--rect").map(parseRect)
        command.draftsDirectory = try values.optional("--drafts-dir").map { URL(fileURLWithPath: $0, isDirectory: true) }
        command.newReview = arguments.contains("--new-review")
        command.durationSeconds = try values.optional("--duration").map { text in
            guard let seconds = Double(text), seconds > 0, seconds <= maxDurationSeconds else {
                throw CommandLineError.invalidValue("--duration", text)
            }
            return seconds
        }
        if kind == .video, command.durationSeconds == nil { throw CommandLineError.missing("--duration (required for --capture video)") }
        if kind == .screenshot, command.durationSeconds != nil {
            throw CommandLineError.invalidValue("--duration", "only valid with --capture video")
        }

        if target == .region, command.rect == nil { throw CommandLineError.missing("--rect (required for --target region)") }
        if target != .region, command.rect != nil { throw CommandLineError.invalidValue("--rect", "only valid with --target region") }
        if target != .window,
           command.windowID != nil { throw CommandLineError.invalidValue("--window-id", "only valid with --target window") }
        return command
    }

    static func parseID(_ text: String, flag: String) throws -> UInt32 {
        guard let id = UInt32(text) else { throw CommandLineError.invalidValue(flag, text) }
        return id
    }

    static func parseRect(_ text: String) throws -> CGRect {
        let parts = text.split(separator: ",").map { Double($0.trimmingCharacters(in: .whitespaces)) }
        guard parts.count == 4, let x = parts[0], let y = parts[1], let width = parts[2], let height = parts[3],
              x >= 0, y >= 0, width > 0, height > 0
        else { throw CommandLineError.invalidValue("--rect", text) }
        return CGRect(x: x, y: y, width: width, height: height)
    }
}

public enum CommandLineError: Error, Equatable, CustomStringConvertible {
    case missingValue(String)
    case invalidValue(String, String)
    case missing(String)

    public var description: String {
        switch self {
        case let .missingValue(flag): "\(flag) needs a value"
        case let .invalidValue(flag, value): "Invalid \(flag): \(value)"
        case let .missing(what): "Missing \(what)"
        }
    }
}

/// Reads `--flag value` pairs from an argument list.
struct ArgumentValues {
    let arguments: [String]

    init(_ arguments: [String]) {
        self.arguments = arguments
    }

    func value(after index: Int, flag: String) throws -> String {
        let next = index + 1
        guard next < arguments.count, !arguments[next].hasPrefix("--") else { throw CommandLineError.missingValue(flag) }
        return arguments[next]
    }

    func optional(_ flag: String) throws -> String? {
        guard let index = arguments.firstIndex(of: flag) else { return nil }
        return try value(after: index, flag: flag)
    }
}
