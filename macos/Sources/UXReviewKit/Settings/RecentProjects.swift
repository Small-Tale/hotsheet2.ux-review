import Foundation

/// Project folders the reviewer has submitted to, most recent first, so the session window can
/// switch the target project without an open panel. The current project itself is stored
/// separately (defaults key `projectDirectory`, docs/05 §5.3). Spec: docs/07-review-session.md §7.6.
public struct RecentProjects: Codable, Equatable, Sendable {
    public static let limit = 10

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

/// One project row of Submit Review's **Change** menu (docs/07 §7.6).
public struct ProjectMenuItem: Equatable, Sendable {
    public var path: String
    /// The folder name, or the abbreviated path when another listed project has the same name.
    public var title: String
    /// The project the review files into now (shown checked).
    public var isCurrent: Bool
    /// Offered because Hot Sheet knows it (a registered checkout), below the recent projects.
    public var isFromHotSheet = false
}

public extension RecentProjects {
    /// The **Change** menu's projects: every recent project whose folder still exists, most
    /// recent first, with the current project included (first when it isn't recent yet).
    /// **Choose Folder…** follows them.
    /// - Parameter abbreviate: shortens a path for display (`~/Code/app`).
    /// - Parameter hotSheet: projects Hot Sheet knows (`HotSheetProjects`, `HS2-T32CZC`), listed
    ///   after the recent ones by name, without the ones already listed or whose folder is gone.
    func menu(
        current: String?,
        hotSheet: [String] = [],
        isDirectory: (String) -> Bool = RecentProjects.directoryExists,
        abbreviate: (String) -> String = { ($0 as NSString).abbreviatingWithTildeInPath }
    ) -> [ProjectMenuItem] {
        var list = self
        let current = current.map { URL(fileURLWithPath: $0).standardizedFileURL.path }
        if let current, !list.paths.contains(current) {
            list.paths.insert(current, at: 0)
        }
        let paths = list.paths.filter { $0 == current || isDirectory($0) }
        let known = Set(paths)
        let extra = hotSheet.map { URL(fileURLWithPath: $0).standardizedFileURL.path }
            .filter { !known.contains($0) && isDirectory($0) }
            .reduce(into: [String]()) { if !$0.contains($1) { $0.append($1) } }
            .sorted {
                URL(fileURLWithPath: $0).lastPathComponent
                    .localizedStandardCompare(URL(fileURLWithPath: $1).lastPathComponent) == .orderedAscending
            }
        let all = paths + extra
        let names = all.map { URL(fileURLWithPath: $0).lastPathComponent }
        return zip(all, names).enumerated().map { index, entry in
            let (path, name) = entry
            let clash = names.count(where: { $0 == name }) > 1 || name.isEmpty
            return ProjectMenuItem(
                path: path, title: clash ? abbreviate(path) : name, isCurrent: path == current, isFromHotSheet: index >= paths.count
            )
        }
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
