import Foundation

/// Project folders the reviewer has submitted to, most recent first, so the session window can
/// switch the target project without an open panel. The current project itself is stored
/// separately (defaults key `projectDirectory`, docs/05 §5.3). Spec: docs/07-review-session.md §7.6.
public struct RecentProjects: Codable, Equatable, Sendable {
    public static let limit = 5

    public private(set) var paths: [String]

    public init(paths: [String] = []) {
        self.paths = []
        for path in paths.reversed() {
            use(path)
        }
    }

    /// Moves `path` to the front (adding it when new) and keeps at most `limit` entries.
    /// Paths are compared after standardizing, so `/a/b/` and `/a/b` are one project.
    public mutating func use(_ path: String) {
        guard !path.trimmingCharacters(in: .whitespaces).isEmpty else { return }
        let normalized = URL(fileURLWithPath: path).standardizedFileURL.path
        paths.removeAll { $0 == normalized }
        paths.insert(normalized, at: 0)
        if paths.count > Self.limit { paths.removeLast(paths.count - Self.limit) }
    }

    public mutating func remove(_ path: String) {
        let normalized = URL(fileURLWithPath: path).standardizedFileURL.path
        paths.removeAll { $0 == normalized }
    }

    /// The entries whose folders still exist.
    public func existing(_ isDirectory: (String) -> Bool = RecentProjects.directoryExists) -> [String] {
        paths.filter(isDirectory)
    }

    public static func directoryExists(_ path: String) -> Bool {
        var isDirectory: ObjCBool = false
        return FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory) && isDirectory.boolValue
    }
}

public enum RecentProjectsStore {
    public static let key = "recentProjects"

    /// The saved list, or an empty one when nothing (or something unreadable) is saved.
    public static func load(from store: KeyValueStoring) -> RecentProjects {
        guard let data = store.data(forKey: key),
              let recent = try? JSONDecoder().decode(RecentProjects.self, from: data)
        else { return RecentProjects() }
        return RecentProjects(paths: recent.paths)
    }

    public static func save(_ recent: RecentProjects, to store: KeyValueStoring) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        try store.set(encoder.encode(recent), forKey: key)
    }
}
