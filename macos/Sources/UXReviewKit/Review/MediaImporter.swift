import AVFoundation
import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

public enum MediaImportError: Error, Equatable, Sendable, CustomStringConvertible {
    case nothingToImport
    case missing(URL)
    case unsupported(URL)
    case unreadable(URL)

    public var code: String {
        switch self {
        case .nothingToImport: "nothingToImport"
        case .missing: "missingFile"
        case .unsupported: "unsupportedMedia"
        case .unreadable: "unreadableMedia"
        }
    }

    public var description: String {
        switch self {
        case .nothingToImport: "No files to import."
        case let .missing(url): "\(url.lastPathComponent) doesn't exist."
        case let .unsupported(url): "\(url.lastPathComponent) isn't an image or a movie."
        case let .unreadable(url): "\(url.lastPathComponent) couldn't be read as an image or a movie."
        }
    }
}

/// Brings existing image and movie files into a draft review so they can be annotated like
/// captures (for example a ⇧⌘4 screenshot or an older recording). The source file is never
/// moved or changed: images are re-encoded to PNG with their EXIF orientation applied, so
/// every format behaves like a capture in the editor (crop, render); movies are copied as-is
/// once AVFoundation confirms a video track. Spec: docs/04-capture.md §4.12.
public enum MediaImporter {
    /// What the open panel offers.
    public static let contentTypes: [UTType] = [.image, .movie]

    /// Prepares every file first and only then adds them (after ending the current draft when
    /// `newReview` is set), so one bad file changes nothing. Returns the updated draft and the
    /// new media items, in the given order. With `draft`, the files go into that existing draft
    /// (the one an editor window shows, docs/04 §4.12.2) rather than the current one, and
    /// `newReview` is ignored.
    public static func importFiles(
        _ urls: [URL],
        into store: ReviewDraftStore,
        draft directory: URL? = nil,
        newReview: Bool = false,
        now: Date = Date()
    ) async throws -> (draft: ReviewDraft, media: [MediaItem]) {
        var prepared: [DraftCapture] = []
        defer { prepared.forEach { try? FileManager.default.removeItem(at: $0.fileURL) } } // left over only on failure
        for url in urls {
            try await prepared.append(prepare(url, now: now))
        }
        guard !prepared.isEmpty else { throw MediaImportError.nothingToImport }
        if newReview, directory == nil { try store.startNew() }
        var draft: ReviewDraft?
        var media: [MediaItem] = []
        for capture in prepared {
            let added = try store.add(capture, to: directory)
            draft = added.draft
            media.append(added.media)
        }
        guard let draft else { throw MediaImportError.nothingToImport }
        return (draft, media)
    }

    /// A temporary copy of `url` ready for `ReviewDraftStore.add` (which moves it into the draft).
    public static func prepare(_ url: URL, now: Date = Date()) async throws -> DraftCapture {
        guard FileManager.default.fileExists(atPath: url.path) else { throw MediaImportError.missing(url) }
        let created = (try? url.resourceValues(forKeys: [.creationDateKey]).creationDate) ?? now
        switch kind(of: url) {
        case .image: return try prepareImage(url, capturedAt: created)
        case .video: return try await prepareMovie(url, capturedAt: created)
        case nil: throw MediaImportError.unsupported(url)
        }
    }

    /// Whether `url` is an image or a movie by its type (the file's own content type, or its
    /// extension), or nil for anything else, directories included. Contents aren't read.
    public static func kind(of url: URL) -> MediaKind? {
        let type = (try? url.resourceValues(forKeys: [.contentTypeKey]).contentType) ?? UTType(filenameExtension: url.pathExtension)
        guard let type else { return nil }
        if type.conforms(to: .image) { return .image }
        if type.conforms(to: .movie) || type.conforms(to: .audiovisualContent) { return .video }
        return nil
    }

    private static func prepareImage(_ url: URL, capturedAt: Date) throws -> DraftCapture {
        guard let image = orientedImage(at: url) else { throw MediaImportError.unreadable(url) }
        let temporary = FileManager.default.temporaryDirectory.appendingPathComponent("uxreview-import-\(UUID().uuidString).png")
        try ImageFiles.writePNG(image, to: temporary)
        return DraftCapture(
            fileURL: temporary, kind: .image, pixelWidth: image.width, pixelHeight: image.height,
            capturedAt: capturedAt, context: CaptureContext()
        )
    }

    /// The first frame of the image, rotated/flipped upright per its EXIF orientation.
    static func orientedImage(at url: URL) -> CGImage? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil), CGImageSourceGetCount(source) > 0,
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = (properties[kCGImagePropertyPixelWidth] as? NSNumber)?.intValue,
              let height = (properties[kCGImagePropertyPixelHeight] as? NSNumber)?.intValue
        else { return nil }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: max(width, height),
            kCGImageSourceShouldCacheImmediately: true,
        ]
        return CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary)
    }

    private static func prepareMovie(_ url: URL, capturedAt: Date) async throws -> DraftCapture {
        let asset = AVURLAsset(url: url)
        guard let track = try? await asset.loadTracks(withMediaType: .video).first,
              let geometry = try? await track.load(.naturalSize, .preferredTransform),
              let duration = try? await asset.load(.duration), duration.isNumeric
        else { throw MediaImportError.unreadable(url) }
        // The size as displayed (what the editor's poster frame shows), so annotations line up.
        let size = CGRect(origin: .zero, size: geometry.0).applying(geometry.1).size
        let width = Int(abs(size.width).rounded())
        let height = Int(abs(size.height).rounded())
        guard width > 0, height > 0 else { throw MediaImportError.unreadable(url) }
        let ext = url.pathExtension.isEmpty ? "mov" : url.pathExtension.lowercased()
        let temporary = FileManager.default.temporaryDirectory.appendingPathComponent("uxreview-import-\(UUID().uuidString).\(ext)")
        try FileManager.default.copyItem(at: url, to: temporary)
        return DraftCapture(
            fileURL: temporary, kind: .video, pixelWidth: width, pixelHeight: height,
            durationMs: max(1, Int((CMTimeGetSeconds(duration) * 1000).rounded())),
            capturedAt: capturedAt, context: CaptureContext()
        )
    }
}

/// Headless import invocation of the app, used by scripts and end-to-end tests:
///
///     UXReview --import FILE [FILE…] [--drafts-dir DIR] [--new-review]
///
/// Spec: docs/04-capture.md §4.12.
public struct ImportCommand: Equatable, Sendable {
    public var files: [URL]
    public var draftsDirectory: URL?
    public var newReview: Bool

    public init(files: [URL], draftsDirectory: URL? = nil, newReview: Bool = false) {
        self.files = files
        self.draftsDirectory = draftsDirectory
        self.newReview = newReview
    }

    /// Returns nil when `--import` is absent. Files are every non-flag argument after
    /// `--import`, up to the next flag.
    public static func parse(_ arguments: [String]) throws -> ImportCommand? {
        guard let index = arguments.firstIndex(of: "--import") else { return nil }
        let values = ArgumentValues(arguments)
        let files = arguments[(index + 1)...].prefix { !$0.hasPrefix("--") }.map { URL(fileURLWithPath: $0) }
        guard !files.isEmpty else { throw CommandLineError.missingValue("--import") }
        return try ImportCommand(
            files: files,
            draftsDirectory: values.optional("--drafts-dir").map { URL(fileURLWithPath: $0, isDirectory: true) },
            newReview: arguments.contains("--new-review")
        )
    }
}
