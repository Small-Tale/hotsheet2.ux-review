import Foundation

/// The running Hot Sheet 2 web client on this machine, and its ticket deep links, so a filed
/// review can be opened in Hot Sheet (docs/07 §7.5, `HS2-ZEF6XD`).
///
/// The web host publishes its loopback origin in `${HOTSHEET_HOME:-~/.hotsheet2}/client.json`
/// (`url`, `pid`, `started_at`, `id`). It opens a ticket at
/// `<url>/?store=<project path, else ticket store path>&ticket=<slug>` (Hot Sheet 2 docs/06,
/// `HS2-RVSPQ9`; the parameter is named `store` but takes a project too). A record counts only while its process is alive and its URL
/// answers.
public struct HotSheetWebClient: Equatable, Sendable {
    public static let discoveryFilename = "client.json"

    public var url: URL
    public var pid: Int32

    public init(url: URL, pid: Int32) {
        self.url = url
        self.pid = pid
    }

    /// `$HOTSHEET_HOME`, else `~/.hotsheet2`.
    public static func home(environment: [String: String] = ProcessInfo.processInfo.environment) -> URL {
        if let home = environment["HOTSHEET_HOME"], !home.trimmingCharacters(in: .whitespaces).isEmpty {
            return URL(fileURLWithPath: (home as NSString).expandingTildeInPath, isDirectory: true)
        }
        return FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".hotsheet2", isDirectory: true)
    }

    /// The client `client.json` describes, if it is a loopback `http(s)` origin with a pid.
    /// Doesn't check that it is running.
    public static func read(home: URL) -> HotSheetWebClient? {
        struct Record: Decodable {
            var url: String
            var pid: Int32
        }
        guard let data = try? Data(contentsOf: home.appendingPathComponent(discoveryFilename)),
              let record = try? JSONDecoder().decode(Record.self, from: data),
              record.pid > 0,
              let url = URL(string: record.url),
              ["http", "https"].contains(url.scheme?.lowercased() ?? ""),
              isLoopback(url.host)
        else { return nil }
        return HotSheetWebClient(url: url, pid: record.pid)
    }

    /// The running client, or nil when there is none: no record, a dead process, or a URL that
    /// doesn't answer. `isAlive` and `responds` are seams for tests; `responds` may block briefly,
    /// so call this off the main thread.
    public static func discover(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        isAlive: (Int32) -> Bool = HotSheetWebClient.processIsAlive,
        responds: (URL) -> Bool = { HotSheetWebClient.answers($0) }
    ) -> HotSheetWebClient? {
        guard let client = read(home: home(environment: environment)), isAlive(client.pid), responds(client.url) else {
            return nil
        }
        return client
    }

    /// The deep link that opens `ticket` in its project (`HS2-G3BA3P`). Hot Sheet's `store`
    /// parameter takes a project folder as well as a store path. The project is what the
    /// reviewer chose, while the store is the project's implementation detail, so the link names
    /// the project and falls back to the store only when the project isn't known.
    public func ticketURL(project: String?, store: String, ticket: String) -> URL {
        let trimmed = project?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let target = trimmed.isEmpty ? store : URL(fileURLWithPath: trimmed, isDirectory: true).standardizedFileURL.path
        return ticketURL(target: target, ticket: ticket)
    }

    private func ticketURL(target store: String, ticket: String) -> URL {
        var components = URLComponents(url: url, resolvingAgainstBaseURL: false) ?? URLComponents()
        if components.path.isEmpty { components.path = "/" }
        // Hot Sheet reads the query with URLSearchParams, where `+` is a space, so everything
        // but unreserved characters and `/` `:` is percent-encoded.
        func encode(_ value: String) -> String {
            value.addingPercentEncoding(withAllowedCharacters: Self.queryValueCharacters) ?? value
        }
        components.percentEncodedQuery = "store=\(encode(store))&ticket=\(encode(ticket))"
        return components.url ?? url
    }

    static let queryValueCharacters = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-._~/:"))
        .intersection(CharacterSet(charactersIn: Unicode.Scalar(0) ... Unicode.Scalar(127)))

    static func isLoopback(_ host: String?) -> Bool {
        guard let host = host?.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: "[]")) else { return false }
        return host == "localhost" || host == "::1" || host.hasPrefix("127.")
    }

    /// True while a process with `pid` exists (one owned by another user counts too).
    @Sendable public static func processIsAlive(_ pid: Int32) -> Bool {
        kill(pid, 0) == 0 || errno == EPERM
    }

    /// True when `url` gives any HTTP response within `timeout` seconds.
    public static func answers(_ url: URL, timeout: TimeInterval = 1.5) -> Bool {
        var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: timeout)
        request.httpMethod = "GET"
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = timeout
        configuration.timeoutIntervalForResource = timeout
        configuration.connectionProxyDictionary = [:]
        let session = URLSession(configuration: configuration)
        defer { session.invalidateAndCancel() }
        let done = DispatchSemaphore(value: 0)
        let answered = Answered()
        let task = session.dataTask(with: request) { _, response, _ in
            answered.value = response is HTTPURLResponse
            done.signal()
        }
        task.resume()
        if done.wait(timeout: .now() + timeout + 0.5) == .timedOut {
            task.cancel()
            return false
        }
        return answered.value
    }

    private final class Answered: @unchecked Sendable {
        var value = false
    }
}
