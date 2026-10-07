import Foundation

/// Builds the `CaptureContext` recorded with each capture from what the platform reports.
public enum CaptureContextBuilder {
    /// "macOS 27.0" or "macOS 27.0.1" (the patch version only when non-zero).
    public static func osVersionString(_ version: OperatingSystemVersion, platform: String = "macOS") -> String {
        var text = "\(platform) \(version.majorVersion).\(version.minorVersion)"
        if version.patchVersion > 0 { text += ".\(version.patchVersion)" }
        return text
    }

    /// Trims every text field and drops empty ones so the bundle never carries blank values.
    public static func make(
        appName: String?,
        bundleIdentifier: String?,
        windowTitle: String?,
        url: String? = nil,
        osVersion: OperatingSystemVersion,
        displayScale: Double?
    ) -> CaptureContext {
        CaptureContext(
            appName: clean(appName),
            bundleIdentifier: clean(bundleIdentifier),
            windowTitle: clean(windowTitle),
            url: clean(url),
            osVersion: osVersionString(osVersion),
            displayScale: displayScale.flatMap { $0 > 0 ? $0 : nil }
        )
    }

    static func clean(_ value: String?) -> String? {
        guard let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines), !trimmed.isEmpty else { return nil }
        return trimmed
    }
}
