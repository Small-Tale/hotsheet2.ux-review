import AVFoundation
import CoreGraphics
import Foundation
import ImageIO

/// `UXReview --submit [--drafts-dir DIR] [--draft NAME] [--project DIR] [--title T] [--summary S] [--to-ticket REF [--exclude IDS]]
/// [--downscale on|off]`:
/// files a draft (the current one unless `--draft` names one) in the project's Hot Sheet store
/// with no UI and prints JSON; `--to-ticket` adds it to that existing ticket instead of a new one.
/// `--downscale` overrides the Downscale for AI setting for this run.
/// `--project` is read by the app's settings, like `--status`. Spec: docs/07-review-session.md §7.8.
public struct SubmitCommand: Equatable, Sendable {
    public var draftsDirectory: URL?
    public var draft: String?
    public var title: String?
    public var summary: String?
    /// The existing ticket to add the review to, as typed (a slug, ULID, or ticket reference).
    public var toTicket: String?
    /// With `toTicket`: media and annotation ids left out of what is added (`--exclude m2,a3`).
    public var exclude: [String]
    /// Overrides `CaptureSettings.downscaleForAI` for this submission (`--downscale on|off`).
    public var downscale: Bool?

    public init(
        draftsDirectory: URL? = nil,
        draft: String? = nil,
        title: String? = nil,
        summary: String? = nil,
        toTicket: String? = nil,
        exclude: [String] = [],
        downscale: Bool? = nil
    ) {
        self.draftsDirectory = draftsDirectory
        self.draft = draft
        self.title = title
        self.summary = summary
        self.toTicket = toTicket
        self.exclude = exclude
        self.downscale = downscale
    }

    /// `exclude` as a selection of `bundle`.
    /// - Throws: `invalidValue("--exclude", ids)` naming ids that are neither a capture nor an
    ///   annotation of the review.
    public func selection(in bundle: ReviewBundle) throws -> ReviewSelection {
        let media = Set(bundle.media.map(\.id))
        let annotations = Set(bundle.annotations.map(\.id))
        let unknown = exclude.filter { !media.contains($0) && !annotations.contains($0) }
        guard unknown.isEmpty else { throw CommandLineError.invalidValue("--exclude", unknown.joined(separator: ",")) }
        return ReviewSelection(
            excludedMedia: Set(exclude.filter(media.contains)),
            excludedAnnotations: Set(exclude.filter(annotations.contains))
        )
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
        let exclude = try values.optional("--exclude").map {
            $0.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        }
        if let exclude, exclude.isEmpty || toTicket == nil {
            throw CommandLineError.invalidValue("--exclude", toTicket == nil ? "needs --to-ticket" : "")
        }
        return try SubmitCommand(
            draftsDirectory: values.optional("--drafts-dir").map { URL(fileURLWithPath: $0, isDirectory: true) },
            draft: draft,
            title: values.optional("--title"),
            summary: values.optional("--summary"),
            toTicket: toTicket,
            exclude: exclude ?? [],
            downscale: SettingsCommand.parseSwitch(values, flag: "--downscale")
        )
    }
}

/// Small previews of captures for the session window's capture list.
public enum MediaThumbnail {
    /// A thumbnail at most `maxPixels` on its longer side: the image, or a movie's first frame.
    /// With `crop`, only that part of the image; with `atMs`, the movie's frame at that time
    /// (the start of its trim), so the thumbnail shows the capture as it will be filed.
    public static func make(_ url: URL, kind: MediaKind, crop: PixelRect? = nil, atMs: Int = 0, maxPixels: Int = 240) -> CGImage? {
        switch kind {
        case .image:
            guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
            if let crop {
                guard let full = CGImageSourceCreateImageAtIndex(source, 0, nil),
                      let part = ImageCrop.apply(crop, to: full)
                else { return nil }
                return scaled(part, maxPixels: maxPixels)
            }
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
            generator.requestedTimeToleranceBefore = .zero
            generator.requestedTimeToleranceAfter = CMTime(value: 100, timescale: 1000)
            return try? generator.copyCGImage(at: CMTime(value: CMTimeValue(max(atMs, 0)), timescale: 1000), actualTime: nil)
        }
    }

    /// `image` scaled down to at most `maxPixels` on its longer side (never up).
    static func scaled(_ image: CGImage, maxPixels: Int) -> CGImage? {
        let scale = min(1, Double(maxPixels) / Double(max(image.width, image.height)))
        let width = max(1, Int((Double(image.width) * scale).rounded()))
        let height = max(1, Int((Double(image.height) * scale).rounded()))
        guard let context = CGContext(
            data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return nil }
        context.interpolationQuality = .high
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        return context.makeImage()
    }
}
