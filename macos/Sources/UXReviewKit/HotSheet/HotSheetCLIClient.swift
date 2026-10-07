import Foundation

/// Errors surfaced by Hot Sheet integration.
public enum HotSheetError: Error, Equatable, Sendable {
    case cliNotFound
    case storeNotFound(URL)
    case commandFailed(command: String, exitCode: Int32, stderr: String)
    case unexpectedOutput(command: String, stdout: String)
}

/// Who the ticket write is attributed to. A person running a UX review is a `human` actor;
/// the AI that later splits the ticket identifies itself separately.
public struct HotSheetActor: Equatable, Sendable {
    public enum Role: String, Sendable { case human, ai, system }
    public var role: Role
    public var id: String?

    public init(role: Role, id: String? = nil) {
        self.role = role
        self.id = id
    }

    public static let reviewer = HotSheetActor(role: .human, id: "ux-review")
}

/// A ticket to create in Hot Sheet.
public struct NewTicket: Equatable, Sendable {
    public var title: String
    public var details: String
    public var category: String
    public var tags: [String]
    public var upNext: Bool

    public init(title: String, details: String, category: String = "task", tags: [String] = [], upNext: Bool = false) {
        self.title = title
        self.details = details
        self.category = category
        self.tags = tags
        self.upNext = upNext
    }
}

/// The operations UX Review needs from Hot Sheet, independent of transport (CLI or service).
public protocol HotSheetClient: Sendable {
    /// Creates a ticket and returns its slug (for example `HS-R58EY5`).
    func createTicket(_ ticket: NewTicket) throws -> String
    /// Attaches files to a ticket as one durable batch.
    func attach(files: [URL], to slug: String, batchLabel: String?, purpose: String?) throws
}

/// Talks to Hot Sheet 2 through `hotsheet-cli`, which works headless with no server running.
/// See docs/03-hotsheet-integration.md.
public struct HotSheetCLIClient: HotSheetClient {
    public var executable: URL
    /// The store directory, or a project directory linked to one via `.hotsheet2/store`.
    public var storePath: URL
    public var actor: HotSheetActor
    public var runner: ProcessRunning
    public var baseEnvironment: [String: String]

    public init(
        executable: URL,
        storePath: URL,
        actor: HotSheetActor = .reviewer,
        runner: ProcessRunning = SystemProcessRunner(),
        baseEnvironment: [String: String] = ProcessInfo.processInfo.environment
    ) {
        self.executable = executable
        self.storePath = storePath
        self.actor = actor
        self.runner = runner
        self.baseEnvironment = baseEnvironment
    }

    public func createTicket(_ ticket: NewTicket) throws -> String {
        // Bind values with `=` so titles/details that begin with `-` are not parsed as flags.
        var args = ["new", "--title=\(ticket.title)", "--category=\(ticket.category)", "--details=\(ticket.details)"]
        for tag in ticket.tags {
            args.append("--tag=\(tag)")
        }
        if ticket.upNext { args.append("--up-next") }
        let result = try invoke(args)
        // `hotsheet-cli new` prints `Created <SLUG> (<path>)`.
        for line in result.stdout.split(separator: "\n") where line.hasPrefix("Created ") {
            let rest = line.dropFirst("Created ".count)
            if let slug = rest.split(separator: " ").first, !slug.isEmpty {
                return String(slug)
            }
        }
        throw HotSheetError.unexpectedOutput(command: "new", stdout: result.stdout)
    }

    public func attach(files: [URL], to slug: String, batchLabel: String?, purpose: String?) throws {
        guard !files.isEmpty else { return }
        var args = ["attach", slug]
        if let batchLabel { args.append("--batch-label=\(batchLabel)") }
        if let purpose { args.append("--purpose=\(purpose)") }
        args.append("--")
        args += files.map(\.path)
        _ = try invoke(args)
    }

    /// Runs `hotsheet-cli -C <store> <args> --actor-role … [--actor-id …]`.
    func invoke(_ args: [String]) throws -> ProcessResult {
        var actorArgs = ["--actor-role=\(actor.role.rawValue)"]
        if let id = actor.id { actorArgs.append("--actor-id=\(id)") }
        // Global options go before the subcommand's positional arguments and any `--`.
        let full = ["-C", storePath.path, args[0]] + actorArgs + args.dropFirst()
        // Never let an inherited AI-session identity leak into a human reviewer's writes.
        var env = baseEnvironment
        env["HOTSHEET_ACTOR_ROLE"] = nil
        env["HOTSHEET_ACTOR_ID"] = nil
        let result = try runner.run(executable: executable, arguments: full, environment: env, currentDirectory: nil)
        guard result.exitCode == 0 else {
            throw HotSheetError.commandFailed(command: args.first ?? "", exitCode: result.exitCode, stderr: result.stderr)
        }
        return result
    }
}

/// Finds `hotsheet-cli` and the store a project uses.
public enum HotSheetLocator {
    /// Resolution order: `$HOTSHEET_CLI`, then each `$PATH` entry, then common install locations.
    /// GUI apps launched from Finder get a minimal `PATH`, hence the fallbacks.
    public static func findCLI(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        isExecutable: (String) -> Bool = { FileManager.default.isExecutableFile(atPath: $0) }
    ) -> URL? {
        if let explicit = environment["HOTSHEET_CLI"], isExecutable(explicit) {
            return URL(fileURLWithPath: explicit)
        }
        let pathDirs = (environment["PATH"] ?? "").split(separator: ":").map(String.init)
        let fallbacks = ["/opt/homebrew/bin", "/usr/local/bin"]
            + (environment["HOME"].map { ["\($0)/.cargo/bin", "\($0)/.local/bin"] } ?? [])
        for dir in pathDirs + fallbacks {
            let candidate = (dir as NSString).appendingPathComponent("hotsheet-cli")
            if isExecutable(candidate) { return URL(fileURLWithPath: candidate) }
        }
        return nil
    }

    /// Resolves the ticket store a project uses, following Hot Sheet 2's own order:
    /// `$HOTSHEET_STORE`; then, walking up from `directory`, a directory that is itself a store
    /// (`hotsheet-store.json`) or holds a `.hotsheet2/store` pointer; then a sibling
    /// `<checkout>.hs2` store next to any directory on that walk.
    public static func resolveStore(
        for directory: URL,
        environment: [String: String] = ProcessInfo.processInfo.environment,
        fileManager: FileManager = .default
    ) throws -> URL {
        func isStore(_ url: URL) -> Bool {
            fileManager.fileExists(atPath: url.appendingPathComponent("hotsheet-store.json").path)
        }
        if let explicit = environment["HOTSHEET_STORE"], !explicit.isEmpty {
            let store = URL(fileURLWithPath: explicit, relativeTo: directory).standardizedFileURL
            if isStore(store) { return store }
            throw HotSheetError.storeNotFound(store)
        }
        // Walk path strings, not URLs: for a directory URL at `/`, `deletingLastPathComponent()`
        // yields `/..` forever, so a URL-based walk never terminates.
        var ancestors: [URL] = []
        var current = directory.standardizedFileURL.path
        while true {
            ancestors.append(URL(fileURLWithPath: current, isDirectory: true))
            let parent = (current as NSString).deletingLastPathComponent
            if parent == current || parent.isEmpty { break }
            current = parent
        }
        for dir in ancestors {
            if isStore(dir) { return dir }
            let pointer = dir.appendingPathComponent(".hotsheet2/store")
            if let raw = try? String(contentsOf: pointer, encoding: .utf8) {
                let path = raw.trimmingCharacters(in: .whitespacesAndNewlines)
                if !path.isEmpty {
                    let store = URL(fileURLWithPath: path, relativeTo: dir).standardizedFileURL
                    if isStore(store) { return store }
                }
            }
        }
        for dir in ancestors where dir.path != "/" {
            let sibling = dir.deletingLastPathComponent().appendingPathComponent(dir.lastPathComponent + ".hs2")
            if isStore(sibling) { return sibling }
        }
        throw HotSheetError.storeNotFound(directory)
    }
}
