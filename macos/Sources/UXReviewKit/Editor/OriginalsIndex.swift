import Foundation

/// `<draft>/originals/crops.json`: for each image whose untouched original is kept under
/// `originals/`, the crop (relative to that original) that produced the current file. It lets a
/// later editor session restore the original and map annotations back (review.json has no crop
/// field). Never attached to tickets. Spec: docs/06-annotation-editor.md §6.6.
public struct OriginalsIndex: Codable, Equatable, Sendable {
    public static let filename = "crops.json"
    public static let currentVersion = 1

    public var version = OriginalsIndex.currentVersion
    /// Keyed by media filename.
    public var crops: [String: PixelRect] = [:]

    public init(crops: [String: PixelRect] = [:]) {
        self.crops = crops
    }

    public static func url(in originals: URL) -> URL { originals.appendingPathComponent(filename) }

    /// The index in `originals`, or an empty one when it is missing or unreadable (an unreadable
    /// index just makes earlier crops non-restorable; it never blocks editing).
    public static func load(from originals: URL) -> OriginalsIndex {
        guard let data = try? Data(contentsOf: url(in: originals)),
              let index = try? JSONDecoder().decode(OriginalsIndex.self, from: data),
              index.version == currentVersion
        else { return OriginalsIndex() }
        return index
    }

    public func save(to originals: URL) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try FileManager.default.createDirectory(at: originals, withIntermediateDirectories: true)
        try encoder.encode(self).write(to: Self.url(in: originals), options: .atomic)
    }

    /// The prior crop of an image, when it can be trusted: an original exists (`originalSize`),
    /// the recorded crop lies inside it, and the current file has the crop's size. With no
    /// record, an original the same size as the current file must be identical (offset 0).
    public func prior(filename: String, originalSize: PixelRect?, currentWidth: Int, currentHeight: Int) -> PriorCrop? {
        guard let originalSize else { return nil }
        let crop = crops[filename] ?? PixelRect(x: 0, y: 0, width: originalSize.width, height: originalSize.height)
        guard crop.x >= 0, crop.y >= 0, crop.width > 0, crop.height > 0,
              crop.x + crop.width <= originalSize.width, crop.y + crop.height <= originalSize.height,
              crop.width == currentWidth, crop.height == currentHeight
        else { return nil }
        return PriorCrop(originalSize: originalSize, crop: crop)
    }
}
