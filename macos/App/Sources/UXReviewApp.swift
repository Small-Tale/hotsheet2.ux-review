import AppKit
import UXReviewKit

/// Menu bar app (`LSUIElement`): capture from the menu or a global hotkey, annotate drafts in
/// the UX Review window, and submit them to Hot Sheet from the review session window (docs/07).
/// It shows a Dock icon and menu bar only while one of its windows is open (docs/05 §5.1.1).
@main
enum UXReviewMain {
    static func main() {
        // Headless smoke mode used by scripts/check.sh: print Hot Sheet status as JSON and exit.
        if CommandLine.arguments.contains("--status") {
            let status = AppSettings.currentStatus()
            let data = (try? JSONEncoder().encode(status)) ?? Data("{}".utf8)
            FileHandle.standardOutput.write(data)
            FileHandle.standardOutput.write(Data("\n".utf8))
            exit(status.isReady ? 0 : 3)
        }
        // Offscreen renders of the capture UI for visual QA (no Screen Recording permission needed).
        if let index = CommandLine.arguments.firstIndex(of: "--render-ui-previews"), index + 1 < CommandLine.arguments.count {
            _ = NSApplication.shared
            NSApplication.shared.setActivationPolicy(.prohibited)
            let directory = URL(fileURLWithPath: CommandLine.arguments[index + 1], isDirectory: true)
            let code: Int32 = MainActor.assumeIsolated {
                do {
                    try UIPreviews.render(to: directory).forEach { print($0.path) }
                    return 0
                } catch {
                    FileHandle.standardError.write(Data("\(error)\n".utf8))
                    return 1
                }
            }
            exit(code)
        }
        // Headless modes used by scripts/app-e2e.sh: run once, print a JSON result, and exit.
        // Synchronous: --settings (apply/print settings, check the hotkey), --annotate (run an
        // editing script on a draft), --submit (file a draft in Hot Sheet, docs/07 §7.8),
        // --discard-draft / --drafts (discard one draft, list them all, docs/07 §7.10).
        let arguments = Array(CommandLine.arguments.dropFirst())
        let synchronous: [(String, @MainActor @Sendable ([String]) -> Int32)] = [
            ("--settings", HeadlessSettings.run(arguments:)),
            ("--annotate", HeadlessAnnotate.run(arguments:)),
            ("--submit", HeadlessSubmit.run(arguments:)),
            ("--discard-draft", HeadlessDrafts.run(arguments:)),
            ("--drafts", HeadlessDrafts.run(arguments:)),
        ]
        for (flag, run) in synchronous where CommandLine.arguments.contains(flag) {
            startHeadless()
            exit(MainActor.assumeIsolated { run(arguments) })
        }
        // Asynchronous: --import (add existing files to the draft), --open-media (route files like
        // Finder "Open With" or an editor drop), --capture (one capture).
        let asynchronous: [(String, @MainActor @Sendable ([String]) async -> Int32)] = [
            ("--import", HeadlessImport.run(arguments:)),
            ("--open-media", HeadlessOpenMedia.run(arguments:)),
            ("--capture", HeadlessCapture.run(arguments:)),
        ]
        for (flag, run) in asynchronous where CommandLine.arguments.contains(flag) {
            startHeadless()
            Task { @MainActor in await exit(run(arguments)) }
            dispatchMain()
        }
        MainActor.assumeIsolated {
            let app = NSApplication.shared
            app.setActivationPolicy(.accessory)
            app.delegate = appDelegate
            app.run()
        }
    }

    /// `NSApplication.delegate` is weak; this keeps the delegate alive for the app's lifetime.
    @MainActor private static let appDelegate = AppDelegate()

    /// An app object without a Dock icon or menu bar item, for the headless modes.
    private static func startHeadless() {
        MainActor.assumeIsolated {
            _ = NSApplication.shared
            NSApplication.shared.setActivationPolicy(.prohibited)
        }
    }
}
