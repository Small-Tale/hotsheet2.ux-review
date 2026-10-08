import Foundation

/// Errors surfaced by Hot Sheet integration.
public enum HotSheetError: Error, Equatable, Sendable {
    case cliNotFound
    case storeNotFound(URL)
    case commandFailed(command: String, exitCode: Int32, stderr: String)
    case unexpectedOutput(command: String, stdout: String)
    /// `attach` failed part-way: the first `storedNames.count` files of the batch were attached
    /// (under these stored names, in order) before it stopped. `hotsheet-cli attach` is not
    /// atomic, so a retry must attach only the rest (HS2-QNWMKF).
    case attachIncomplete(storedNames: [String], exitCode: Int32, stderr: String)
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
    /// Creates a ticket and returns its slug plus its file, when the transport reports it.
    func createTicketReportingFile(_ ticket: NewTicket) throws -> CreatedTicket
    /// Attaches files to a ticket as one durable batch.
    func attach(files: [URL], to slug: String, batchLabel: String?, purpose: String?) throws
    /// Attaches files as one batch and returns the name each one is stored under, in order.
    /// Hot Sheet renames a file whose name the ticket already has (`review.json` → `review (2).json`).
    /// `batchID`, when given, is the durable batch the files join, so a resumed attach lands in
    /// the same batch as the files an interrupted one already attached.
    /// - Throws: `HotSheetError.attachIncomplete` when some files were attached before a failure.
    func attachReportingNames(files: [URL], to slug: String, batchLabel: String?, purpose: String?, batchID: String?) throws -> [String]
    /// Looks up an existing ticket by slug or ULID. Nil when the store has no such ticket.
    func findTicket(_ reference: String) throws -> HotSheetTicket?
    /// Appends a Markdown note to a ticket.
    func addNote(_ markdown: String, to slug: String) throws
    /// Moves a ticket to Hot Sheet's Trash (`status: deleted`; `hotsheet-cli restore` brings it back).
    func moveToTrash(_ slug: String) throws
    /// The project's default AI tool and model (`HS2-PT8PM6`), or nil when the transport can't
    /// tell. Throws when asking failed; callers fall back (`MediaScaleTarget.detect`).
    func aiSettings() throws -> AIToolSettings?
}

public extension HotSheetClient {
    func createTicketReportingFile(_ ticket: NewTicket) throws -> CreatedTicket {
        try CreatedTicket(slug: createTicket(ticket))
    }

    /// Transports that can't read the project's AI settings: unknown.
    func aiSettings() throws -> AIToolSettings? { nil }

    /// Transports that can't report stored names or batch ids: assume each file keeps its own name.
    func attachReportingNames(files: [URL], to slug: String, batchLabel: String?, purpose: String?, batchID _: String?) throws -> [String] {
        try attach(files: files, to: slug, batchLabel: batchLabel, purpose: purpose)
        return files.map(\.lastPathComponent)
    }
}

/// A ticket Hot Sheet created: its slug and, when known, its ticket file in the store.
public struct CreatedTicket: Codable, Equatable, Sendable {
    public var slug: String
    /// The ticket's Markdown file (`hotsheet-cli new` prints it), for "Show Ticket File".
    public var file: String?

    public init(slug: String, file: String? = nil) {
        self.slug = slug
        self.file = file
    }
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
        try createTicketReportingFile(ticket).slug
    }

    public func createTicketReportingFile(_ ticket: NewTicket) throws -> CreatedTicket {
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
            guard let slug = rest.split(separator: " ").first, !slug.isEmpty else { continue }
            var file: String?
            if let open = rest.firstIndex(of: "("), rest.hasSuffix(")") {
                let path = rest[rest.index(after: open) ..< rest.index(before: rest.endIndex)]
                file = path.isEmpty ? nil : String(path)
            }
            return CreatedTicket(slug: String(slug), file: file)
        }
        throw HotSheetError.unexpectedOutput(command: "new", stdout: result.stdout)
    }

    public func attach(files: [URL], to slug: String, batchLabel: String?, purpose: String?) throws {
        _ = try attachReportingNames(files: files, to: slug, batchLabel: batchLabel, purpose: purpose, batchID: nil)
    }

    public func attachReportingNames(
        files: [URL], to slug: String, batchLabel: String?, purpose: String?, batchID: String?
    ) throws -> [String] {
        guard !files.isEmpty else { return [] }
        var args = ["attach", slug]
        if let batchID { args.append("--batch-id=\(batchID)") }
        if let batchLabel { args.append("--batch-label=\(batchLabel)") }
        if let purpose { args.append("--purpose=\(purpose)") }
        args.append("--")
        args += files.map(\.path)
        let result = try run(args)
        let stored = Self.storedNames(in: result.stdout)
        guard result.exitCode == 0 else {
            // `attach` writes file by file: the ones it printed before failing are attached.
            if !stored.isEmpty, stored.count < files.count {
                throw HotSheetError.attachIncomplete(storedNames: stored, exitCode: result.exitCode, stderr: result.stderr)
            }
            throw HotSheetError.commandFailed(command: "attach", exitCode: result.exitCode, stderr: result.stderr)
        }
        return stored.count == files.count ? stored : files.map(\.lastPathComponent)
    }

    /// The stored file name from each `Durable attachment id: <ULID> (<stored path>)` line that
    /// `hotsheet-cli attach` prints, one per attached file, in order.
    static func storedNames(in stdout: String) -> [String] {
        stdout.split(separator: "\n").compactMap { line -> String? in
            guard line.hasPrefix("Durable attachment id: "), let open = line.firstIndex(of: "("), line.hasSuffix(")") else { return nil }
            let path = line[line.index(after: open) ..< line.index(before: line.endIndex)]
            return path.isEmpty ? nil : (String(path) as NSString).lastPathComponent
        }
    }

    public func findTicket(_ reference: String) throws -> HotSheetTicket? {
        let result = try run(["show", reference])
        guard result.exitCode == 0 else {
            // `hotsheet-cli show` exits 1 with `Error: no ticket matching '<ref>'`.
            if result.stderr.contains("no ticket matching") { return nil }
            throw HotSheetError.commandFailed(command: "show", exitCode: result.exitCode, stderr: result.stderr)
        }
        guard var ticket = HotSheetTicket.parseShow(result.stdout) else {
            throw HotSheetError.unexpectedOutput(command: "show", stdout: result.stdout)
        }
        let file = HotSheetTicket.ticketFile(id: ticket.id, store: storePath)
        ticket.file = FileManager.default.fileExists(atPath: file.path) ? file.path : nil
        return ticket
    }

    public func addNote(_ markdown: String, to slug: String) throws {
        // A file, not `--note=`, so a long note never meets the argument-length limit.
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("uxreview-note-\(UUID().uuidString).md")
        try Data(markdown.utf8).write(to: file, options: .atomic)
        defer { try? FileManager.default.removeItem(at: file) }
        _ = try invoke(["edit", slug, "--note-file=\(file.path)"])
    }

    public func moveToTrash(_ slug: String) throws {
        _ = try invoke(["edit", slug, "--status=deleted"])
    }

    /// `hotsheet-cli -C <store> ai-settings get --json`: the project's default AI tool, else the
    /// machine-wide fallback (`{"tool":"claude","model":"sonnet","effort":"medium"}`). Throws
    /// `commandFailed` on a non-zero exit (a CLI without `ai-settings`) and `unexpectedOutput`
    /// when the JSON names no tool.
    public func aiSettings() throws -> AIToolSettings? {
        let result = try invoke(["ai-settings", "get", "--json"])
        guard let settings = AIToolSettings.parse(result.stdout) else {
            throw HotSheetError.unexpectedOutput(command: "ai-settings", stdout: result.stdout)
        }
        return settings
    }

    /// Runs `hotsheet-cli`, throwing on a non-zero exit.
    func invoke(_ args: [String]) throws -> ProcessResult {
        let result = try run(args)
        guard result.exitCode == 0 else {
            throw HotSheetError.commandFailed(command: args.first ?? "", exitCode: result.exitCode, stderr: result.stderr)
        }
        return result
    }

    /// Runs `hotsheet-cli -C <store> <args> --actor-role … [--actor-id …]`.
    private func run(_ args: [String]) throws -> ProcessResult {
        var actorArgs = ["--actor-role=\(actor.role.rawValue)"]
        if let id = actor.id { actorArgs.append("--actor-id=\(id)") }
        // Global options go before the subcommand's positional arguments and any `--`.
        let full = ["-C", storePath.path, args[0]] + actorArgs + args.dropFirst()
        // Never let an inherited AI-session identity leak into a human reviewer's writes.
        var env = baseEnvironment
        env["HOTSHEET_ACTOR_ROLE"] = nil
        env["HOTSHEET_ACTOR_ID"] = nil
        return try runner.run(executable: executable, arguments: full, environment: env, currentDirectory: nil)
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
