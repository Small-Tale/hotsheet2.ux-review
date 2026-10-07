import Foundation
import UXReviewKit

/// User-level settings. The project folder can also be given with `--project <path>`.
enum AppSettings {
    private static let projectKey = "projectDirectory"

    static var version: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "dev"
    }

    static var projectDirectory: URL? {
        get {
            let args = CommandLine.arguments
            if let index = args.firstIndex(of: "--project"), index + 1 < args.count {
                return URL(fileURLWithPath: args[index + 1], isDirectory: true)
            }
            return UserDefaults.standard.string(forKey: projectKey).map { URL(fileURLWithPath: $0, isDirectory: true) }
        }
        set { UserDefaults.standard.set(newValue?.path, forKey: projectKey) }
    }

    static func currentStatus() -> HotSheetStatus {
        HotSheetStatus.detect(projectDirectory: projectDirectory)
    }
}
