import Foundation

/// Legacy (before `HS2-71SSJG`, read only by `ReviewDraftStore.migrateLegacyEdits`).
/// `<draft>/originals/crops.json`: for each image whose untouched original is kept under
/// `originals/`, the crop (relative to that original) that produced the current file, and for
/// each such movie, the trim. It lets a later editor session restore the original and map
/// annotations back (review.json has no crop or trim field). Never attached to tickets.
/// Spec: docs/06-annotation-editor.md §6.6 and §6.10.
public struct OriginalsIndex: Codable, Equatable, Sendable {
    public static let filename = "crops.json"
    public static let currentVersion = 1

    public var version = OriginalsIndex.currentVersion
    /// Keyed by media filename.
    public var crops: [String: PixelRect] = [:]
    /// Movie trims, keyed by media filename. Absent in indexes written before trimming existed.
    public var trims: [String: TrimRecord] = [:]

    public init(crops: [String: PixelRect] = [:], trims: [String: TrimRecord] = [:]) {
        self.crops = crops
        self.trims = trims
    }

    private enum CodingKeys: String, CodingKey { case version, crops, trims }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        version = try container.decode(Int.self, forKey: .version)
        crops = try container.decodeIfPresent([String: PixelRect].self, forKey: .crops) ?? [:]
        trims = try container.decodeIfPresent([String: TrimRecord].self, forKey: .trims) ?? [:]
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(version, forKey: .version)
        try container.encode(crops, forKey: .crops)
        if !trims.isEmpty { try container.encode(trims, forKey: .trims) }
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

    /// The prior trim of a movie, when it can be trusted: its original exists, a trim is recorded
    /// for it, the trim lies inside the original, and the current clip (`durationMs` in
    /// review.json) is exactly the trim's length. Unlike crops there is no implicit full-length
    /// record: a movie original is only ever kept together with its trim.
    public func priorTrim(filename: String, originalExists: Bool, currentDurationMs: Int?) -> PriorTrim? {
        guard originalExists, let currentDurationMs, let record = trims[filename],
              record.startMs >= 0, record.startMs < record.endMs, record.endMs <= record.originalDurationMs,
              record.endMs - record.startMs == currentDurationMs
        else { return nil }
        return PriorTrim(originalDurationMs: record.originalDurationMs, trim: TimeRange(startMs: record.startMs, endMs: record.endMs))
    }
}

/// The part of a kept movie original that the current file holds, in ms of the original, and
/// the original's length (as review.json recorded it, so it matches the clip's `durationMs`).
public struct TrimRecord: Codable, Equatable, Sendable {
    public var startMs: Int
    public var endMs: Int
    public var originalDurationMs: Int

    public init(startMs: Int, endMs: Int, originalDurationMs: Int) {
        self.startMs = startMs
        self.endMs = endMs
        self.originalDurationMs = originalDurationMs
    }
}
