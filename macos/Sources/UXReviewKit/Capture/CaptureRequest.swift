import Foundation

// What the reviewer asked to capture. Platform capture code (ScreenCaptureKit in the app)
// executes requests; this file only holds the platform-neutral description and its rules.
// Spec: docs/04-capture.md.

/// Still image or video.
public enum CaptureKind: String, Codable, CaseIterable, Sendable {
    case screenshot
    case video
}

/// What part of the screen to capture.
public enum CaptureTarget: String, Codable, CaseIterable, Sendable {
    /// The whole display under the mouse pointer.
    case display
    /// One window, picked by clicking it.
    case window
    /// A rectangle dragged out on one display.
    case region

    public var label: String {
        switch self {
        case .display: "Screen"
        case .window: "Window"
        case .region: "Region"
        }
    }
}

public struct CaptureRequest: Codable, Equatable, Hashable, Sendable {
    /// Delay presets offered in menus and settings, in seconds (0 = immediately).
    public static let delayPresets = [0, 3, 5, 10]
    /// Upper bound for a custom delay.
    public static let maxDelaySeconds = 60

    public var kind: CaptureKind
    public var target: CaptureTarget
    /// Countdown before capturing (screenshots) or before recording starts (video).
    public var delaySeconds: Int

    public init(kind: CaptureKind = .screenshot, target: CaptureTarget = .region, delaySeconds: Int = 0) {
        self.kind = kind
        self.target = target
        self.delaySeconds = Self.clampDelay(delaySeconds)
    }

    /// The same capture as `kind` (Capture Image / Capture Video of the default request).
    public func with(kind: CaptureKind) -> CaptureRequest {
        var request = self
        request.kind = kind
        return request
    }

    public static func clampDelay(_ seconds: Int) -> Int {
        min(max(seconds, 0), maxDelaySeconds)
    }

    /// Countdown values shown to the reviewer, one per second: `[3, 2, 1]` for a 3 s delay.
    public var countdown: [Int] {
        delaySeconds > 0 ? Array((1 ... delaySeconds).reversed()) : []
    }

    /// Menu-style description, for example "Screenshot of Region after 5 s".
    public var summary: String {
        let what = kind == .screenshot ? "Screenshot" : "Video"
        let delay = delaySeconds > 0 ? " after \(delaySeconds) s" : ""
        return "\(what) of \(target.label)\(delay)"
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(
            kind: container.decodeIfPresent(CaptureKind.self, forKey: .kind) ?? .screenshot,
            target: container.decodeIfPresent(CaptureTarget.self, forKey: .target) ?? .region,
            delaySeconds: container.decodeIfPresent(Int.self, forKey: .delaySeconds) ?? 0
        )
    }
}
