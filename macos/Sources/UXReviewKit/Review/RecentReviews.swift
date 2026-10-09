import Foundation

/// Reviews opened or edited lately, most recent first, for File › Open Recent (`HS2-BKWZ5N`,
/// docs/07 §7.9). Untitled and saved reviews alike; at most `limit`, deduplicated after
/// standardizing. Kept in the app's defaults under `recentReviews` as `{"paths": [...]}`.
public struct RecentReviews: Codable, Equatable, Sendable {
    public static let limit = 10
    public static let key = "recentReviews"

    public private(set) var paths: [String]

    public init(paths: [String] = []) {
        self.paths = []
        for path in paths.reversed() {
            note(path)
        }
    }

    /// Moves `path` to the front (adding it when new).
    public mutating func note(_ path: String) {
        guard !path.trimmingCharacters(in: .whitespaces).isEmpty else { return }
        let normalized = URL(fileURLWithPath: path).standardizedFileURL.path
        paths.removeAll { $0 == normalized }
        paths.insert(normalized, at: 0)
        if paths.count > Self.limit { paths.removeLast(paths.count - Self.limit) }
    }

    /// Follows a review that moved (Save): its entry keeps its place under the new path.
    public mutating func move(_ old: String, to new: String) {
        let source = URL(fileURLWithPath: old).standardizedFileURL.path
        let target = URL(fileURLWithPath: new).standardizedFileURL.path
        guard paths.contains(source) else { return note(target) }
        paths.removeAll { $0 == target }
        if let index = paths.firstIndex(of: source) { paths[index] = target }
    }

    public mutating func remove(_ path: String) {
        let normalized = URL(fileURLWithPath: path).standardizedFileURL.path
        paths.removeAll { $0 == normalized }
    }

    public mutating func clear() { paths = [] }

    /// One Open Recent item.
    public struct Entry: Equatable, Sendable {
        public var directory: URL
        /// The review's title, or the package name when review.json can't be read.
        public var title: String
        /// Never saved: it lives in the drafts folder.
        public var isUntitled: Bool
    }

    /// The menu's items: reviews that still exist, titled from their review.json. Titles that
    /// repeat get their location ("Checkout review — Desktop").
    public func entries(store: ReviewDraftStore) -> [Entry] {
        let items = paths.compactMap { path -> Entry? in
            let directory = URL(fileURLWithPath: path, isDirectory: true)
            guard let draft = try? store.open(directory) else { return nil }
            return Entry(directory: directory, title: draft.bundle.title, isUntitled: store.isUntitled(directory))
        }
        let titles = items.map(\.title)
        return items.map { item in
            guard titles.count(where: { $0 == item.title }) > 1 else { return item }
            var item = item
            let place = item.isUntitled ? "Not saved" : item.directory.deletingLastPathComponent().lastPathComponent
            item.title += " — \(place)"
            return item
        }
    }

    public static func load(from store: KeyValueStoring) -> RecentReviews {
        guard let data = store.data(forKey: key),
              let recent = try? JSONDecoder().decode(RecentReviews.self, from: data)
        else { return RecentReviews() }
        return RecentReviews(paths: recent.paths)
    }

    public func save(to store: KeyValueStoring) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        try store.set(encoder.encode(self), forKey: Self.key)
    }
}
