import Foundation

/// The projects Hot Sheet itself knows (`HS2-T32CZC`, docs/07 §7.6): its registered checkouts, from
/// `hotsheet-cli checkout list` (a JSON array of `{"id", "root", "alias", "stores", …}`). The
/// Submit Review window's **Change** menu offers them below UX Review's own recent projects, so it
/// isn't nearly empty before the first submit.
public enum HotSheetProjects {
    /// Folders under these are test and scratch checkouts, never offered.
    static let temporaryPrefixes = ["/tmp/", "/private/tmp/", "/var/folders/", "/private/var/folders/"]

    /// The checkouts' project folders in `json`, standardized, in order, without duplicates or
    /// temporary folders. Unreadable output gives none.
    public static func parse(_ json: String) -> [String] {
        struct Checkout: Decodable { var root: String? }
        guard let checkouts = try? JSONDecoder().decode([Checkout].self, from: Data(json.utf8)) else { return [] }
        var seen = Set<String>()
        return checkouts.compactMap { checkout -> String? in
            guard let root = checkout.root?.trimmingCharacters(in: .whitespacesAndNewlines), root.hasPrefix("/") else { return nil }
            let path = URL(fileURLWithPath: root, isDirectory: true).standardizedFileURL.path
            guard !temporaryPrefixes.contains(where: { (path + "/").hasPrefix($0) }), seen.insert(path).inserted else { return nil }
            return path
        }
    }

    /// Runs `hotsheet-cli checkout list` (global: no store needed). Any failure (an old CLI
    /// without `checkout`, a non-zero exit) gives none.
    public static func list(cliPath: String, runner: ProcessRunning = SystemProcessRunner()) -> [String] {
        var env = ProcessInfo.processInfo.environment
        env["HOTSHEET_ACTOR_ROLE"] = nil
        env["HOTSHEET_ACTOR_ID"] = nil
        guard let result = try? runner.run(
            executable: URL(fileURLWithPath: cliPath), arguments: ["checkout", "list"], environment: env, currentDirectory: nil
        ), result.exitCode == 0 else { return [] }
        return parse(result.stdout)
    }
}
