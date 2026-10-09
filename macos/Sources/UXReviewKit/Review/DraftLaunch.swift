import Foundation

/// Where a review started by a capture link (`HS2-CWTNY2`, `CaptureLink`) is meant to go: its
/// Hot Sheet project and the existing ticket to add it to. Kept beside review.json in
/// `launch.json` and never attached. The Submit Review window and `--submit` start from it; the
/// app-wide project setting is not changed. Spec: docs/04-capture.md §4.13, docs/07 §7.6.
public struct DraftLaunch: Codable, Equatable, Sendable {
    public static let filename = "launch.json"

    /// The project folder's path.
    public var projectDirectory: String?
    /// The ticket reference (slug or ULID).
    public var ticket: String?

    public init(projectDirectory: String? = nil, ticket: String? = nil) {
        self.projectDirectory = projectDirectory
        self.ticket = ticket
    }

    public var project: URL? { projectDirectory.map { URL(fileURLWithPath: $0, isDirectory: true) } }

    /// This launch's values over `older`'s: a later link to the same review replaces what it sets.
    public func merged(into older: DraftLaunch) -> DraftLaunch {
        DraftLaunch(projectDirectory: projectDirectory ?? older.projectDirectory, ticket: ticket ?? older.ticket)
    }

    /// The draft's launch, or an empty one when it has none (or it can't be read).
    public static func load(from directory: URL) -> DraftLaunch {
        let url = directory.appendingPathComponent(filename)
        guard let data = try? Data(contentsOf: url), let launch = try? JSONDecoder().decode(DraftLaunch.self, from: data)
        else { return DraftLaunch() }
        return launch
    }

    /// Writes `launch.json`, or removes it when nothing is set.
    public func save(to directory: URL) throws {
        let url = directory.appendingPathComponent(Self.filename)
        if self == DraftLaunch() {
            if FileManager.default.fileExists(atPath: url.path) { try FileManager.default.removeItem(at: url) }
            return
        }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(self).write(to: url, options: .atomic)
    }

    /// The project a draft files to: `explicit` (`--project`) first, then the draft's launch
    /// project, then the app's selected project.
    public static func project(explicit: URL?, draft directory: URL, selected: URL?) -> URL? {
        explicit ?? load(from: directory).project ?? selected
    }
}
