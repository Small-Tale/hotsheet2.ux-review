import Foundation

/// The highest capture number and media id number a draft has used, kept in
/// `<draft>/numbering.json` once a capture is removed, so later captures never reuse a removed
/// capture's file name or id (docs/07-review-session.md §7.2). Drafts that never removed a
/// capture have no file; their numbering follows from `review.json` alone.
public struct DraftNumbering: Codable, Equatable, Sendable {
    public static let filename = "numbering.json"

    /// Highest N of a `capture-N` file name used so far.
    public var lastCapture: Int
    /// Highest N of an `mN` media id used so far.
    public var lastMedia: Int

    public init(lastCapture: Int = 0, lastMedia: Int = 0) {
        self.lastCapture = lastCapture
        self.lastMedia = lastMedia
    }

    /// Raises the record to cover every item in `media`.
    public mutating func record(_ media: [MediaItem]) {
        for item in media {
            lastCapture = max(lastCapture, ReviewDraftStore.captureNumber(of: item.filename) ?? 0)
            lastMedia = max(lastMedia, ReviewDraftStore.mediaNumber(of: item.id) ?? 0)
        }
    }

    /// The draft's record; zeros when there is none or it is unreadable.
    public static func load(from directory: URL) -> DraftNumbering {
        let url = directory.appendingPathComponent(filename)
        guard let data = try? Data(contentsOf: url),
              let numbering = try? JSONDecoder().decode(DraftNumbering.self, from: data)
        else { return DraftNumbering() }
        return numbering
    }

    public func save(to directory: URL) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(self).write(to: directory.appendingPathComponent(Self.filename), options: .atomic)
    }
}
