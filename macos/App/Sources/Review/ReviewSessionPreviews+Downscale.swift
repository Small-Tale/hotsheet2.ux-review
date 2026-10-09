import AppKit
import SwiftUI
import UXReviewKit

/// HS2-ZMDH5D: the Settings › Downscale for AI wiring, end to end inside the app, for
/// `scripts/app-e2e.sh` (`session-downscale-wiring.json`). The Settings toggle's own binding
/// saves `downscaleForAI`; `SettingsModel` posts `captureSettingsChanged`; an open Submit Review
/// model re-reads the setting (`refreshScale`) and its capture list shows the size as filed.
/// Settings live in a throwaway store and Hot Sheet's AI size comes from a counting fake, so the
/// probe touches neither the user's defaults nor `hotsheet-cli`. Spec: docs/07 §7.5.1.
extension ReviewSessionPreviews {
    /// Counts AI size detections (they run off the main thread).
    final class DetectionCounter: @unchecked Sendable {
        private let lock = NSLock()
        private var count = 0
        var value: Int { lock.withLock { count } }
        func increment() { lock.withLock { count += 1 } }
    }

    static func probeDownscaleWiring(_ draft: ReviewDraft, store: ReviewDraftStore, to directory: URL) throws -> [URL] {
        let settingsStore = UIPreviews.MemoryStore()
        // No hotkeys, so the probe registers nothing with the system.
        try CaptureSettingsStore.save(
            CaptureSettings(captureHotkey: nil, recordHotkey: nil, openReviewHotkey: nil, downscaleForAI: true),
            to: settingsStore
        )
        let settings = SettingsModel(store: settingsStore)
        defer { settings.hotkeys.unregister() }
        let toggle = SettingsView(model: settings).binding(\.downscaleForAI)

        let detections = DetectionCounter()
        let model = ReviewSessionModel(
            draft: draft, store: store, target: ready,
            scaleDetector: { _, _ in
                detections.increment()
                return .claudeStandard
            },
            downscaleSetting: { CaptureSettingsStore.load(from: settingsStore).downscaleForAI }
        )
        model.statusProvider = { ready }
        model.ticketFinder = { _, _ in .success(nil) }

        /// What the window shows now: the setting as saved, the model's view of it, each
        /// capture's size as filed (the capture list's text), and the detections so far.
        func state() -> [String: Any] {
            [
                "saved": CaptureSettingsStore.load(from: settingsStore).downscaleForAI,
                "downscaleForAI": model.downscaleForAI,
                "scaled": model.scaleTarget != nil,
                "sizes": draft.bundle.media.map { model.preview.media[$0.id]?.sizeText ?? "?" },
                "detections": detections.value,
            ]
        }

        var steps: [[String: Any]] = []
        var written: [URL] = []
        func step(_ name: String, until done: () -> Bool) throws {
            let deadline = Date().addingTimeInterval(5)
            while !done(), Date() < deadline {
                RunLoop.main.run(until: Date().addingTimeInterval(0.02))
            }
            var entry = state()
            entry["step"] = name
            entry["settled"] = done()
            steps.append(entry)
            written.append(try snapshot(
                ReviewSessionView(model: model), size: size,
                to: directory.appendingPathComponent("session-downscale-\(name).png")
            ))
        }

        // Opened with the setting on: the AI size is detected once, then the list shows it.
        try step("opened") { model.scaleTarget != nil }
        // Settings › Downscale for AI turned off while the window is open.
        toggle.wrappedValue = false
        try step("off") { !model.downscaleForAI && model.scaleTarget == nil }
        // Back on: the size detected for this store is reused, not detected again.
        toggle.wrappedValue = true
        try step("on-again") { model.scaleTarget != nil }

        let json = directory.appendingPathComponent("session-downscale-wiring.json")
        try JSONSerialization.data(withJSONObject: ["steps": steps], options: [.prettyPrinted, .sortedKeys]).write(to: json)
        return [json] + written
    }
}
