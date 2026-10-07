import Foundation

/// Whether UX Review can file tickets right now, for display in the menu bar and `--status`.
public struct HotSheetStatus: Codable, Equatable, Sendable {
    public var cliPath: String?
    public var projectDirectory: String?
    public var storePath: String?
    public var problem: String?

    public var isReady: Bool { problem == nil }

    public init(cliPath: String? = nil, projectDirectory: String? = nil, storePath: String? = nil, problem: String? = nil) {
        self.cliPath = cliPath
        self.projectDirectory = projectDirectory
        self.storePath = storePath
        self.problem = problem
    }

    /// Detects the CLI and the store for `projectDirectory` (the project under review).
    public static func detect(
        projectDirectory: URL?,
        environment: [String: String] = ProcessInfo.processInfo.environment,
        isExecutable: (String) -> Bool = { FileManager.default.isExecutableFile(atPath: $0) }
    ) -> HotSheetStatus {
        var status = HotSheetStatus(projectDirectory: projectDirectory?.path)
        guard let cli = HotSheetLocator.findCLI(environment: environment, isExecutable: isExecutable) else {
            status.problem = "hotsheet-cli not found. Install Hot Sheet 2 or set HOTSHEET_CLI."
            return status
        }
        status.cliPath = cli.path
        guard let projectDirectory else {
            status.problem = "No project selected."
            return status
        }
        do {
            status.storePath = try HotSheetLocator.resolveStore(for: projectDirectory, environment: environment).path
        } catch {
            status.problem = "No Hot Sheet store found for \(projectDirectory.path)."
        }
        return status
    }

    /// One line for the menu.
    public var summary: String {
        if let problem { return "Hot Sheet: \(problem)" }
        let store = storePath.map { ($0 as NSString).lastPathComponent } ?? "?"
        return "Hot Sheet: ready (\(store))"
    }
}
