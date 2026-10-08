import AVFoundation
import CoreGraphics
import Foundation
import ImageIO

/// `UXReview --submit [--drafts-dir DIR] [--draft NAME] [--project DIR] [--title T] [--summary S] [--to-ticket REF]`:
/// files a draft (the current one unless `--draft` names one) in the project's Hot Sheet store
/// with no UI and prints JSON; `--to-ticket` adds it to that existing ticket instead of a new one.
/// `--project` is read by the app's settings, like `--status`. Spec: docs/07-review-session.md §7.8.
public struct SubmitCommand: Equatable, Sendable {
    public var draftsDirectory: URL?
    public var draft: String?
    public var title: String?
    public var summary: String?
    /// The existing ticket to add the review to, as typed (a slug, ULID, or ticket reference).
    public var toTicket: String?

    public init(
        draftsDirectory: URL? = nil,
        draft: String? = nil,
        title: String? = nil,
        summary: String? = nil,
        toTicket: String? = nil
    ) {
        self.draftsDirectory = draftsDirectory
        self.draft = draft
        self.title = title
        self.summary = summary
        self.toTicket = toTicket
    }

    /// Returns nil when `--submit` is absent.
    public static func parse(_ arguments: [String]) throws -> SubmitCommand? {
        guard arguments.contains("--submit") else { return nil }
        let values = ArgumentValues(arguments)
        let draft = try values.optional("--draft")
        if let draft, draft.isEmpty || draft.contains("/") || draft.hasPrefix(".") {
            throw CommandLineError.invalidValue("--draft", draft)
        }
        let toTicket = try values.optional("--to-ticket")
        if let toTicket, TicketReference.parse(toTicket) == nil {
            throw CommandLineError.invalidValue("--to-ticket", toTicket)
        }
        return try SubmitCommand(
            draftsDirectory: values.optional("--drafts-dir").map { URL(fileURLWithPath: $0, isDirectory: true) },
            draft: draft,
            title: values.optional("--title"),
            summary: values.optional("--summary"),
            toTicket: toTicket
        )
    }
}

/// Small previews of captures for the session window's capture list.
public enum MediaThumbnail {
    /// A thumbnail at most `maxPixels` on its longer side: the image, or a movie's first frame.
    public static func make(_ url: URL, kind: MediaKind, maxPixels: Int = 240) -> CGImage? {
        switch kind {
        case .image:
            guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
            let options: [CFString: Any] = [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceCreateThumbnailWithTransform: true,
                kCGImageSourceThumbnailMaxPixelSize: maxPixels,
            ]
            return CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary)
        case .video:
            let generator = AVAssetImageGenerator(asset: AVURLAsset(url: url))
            generator.appliesPreferredTrackTransform = true
            generator.maximumSize = CGSize(width: maxPixels, height: maxPixels)
            return try? generator.copyCGImage(at: .zero, actualTime: nil)
        }
    }
}
