import AppKit
import SwiftUI

/// A small floating panel for countdowns and "saved" confirmations. It never takes focus or
/// mouse events, so hover states in the reviewed app stay put, and it is excluded from captures
/// (ScreenCaptureKit filters out all of UX Review's windows).
@MainActor
final class CaptureHUD {
    private var panel: NSPanel?
    private var hideTask: Task<Void, Never>?

    /// Shows a large countdown number centered on `screen`.
    func showCountdown(_ seconds: Int, on screen: NSScreen?, recording: Bool = false) {
        show(
            HUDContent(title: "\(seconds)", subtitle: recording ? "Recording in…" : "Capturing in…", large: true),
            on: screen,
            hideAfter: nil
        )
    }

    /// Shows a short message, then hides it.
    func flash(_ title: String, subtitle: String? = nil, on screen: NSScreen? = NSScreen.main) {
        show(HUDContent(title: title, subtitle: subtitle, large: false), on: screen, hideAfter: .seconds(2))
    }

    func hide() {
        hideTask?.cancel()
        panel?.orderOut(nil)
    }

    private func show(_ content: HUDContent, on screen: NSScreen?, hideAfter: Duration?) {
        hideTask?.cancel()
        let panel = panel ?? makePanel()
        self.panel = panel
        let host = NSHostingView(rootView: content)
        panel.contentView = host
        let size = host.fittingSize
        let frame = (screen ?? NSScreen.main)?.visibleFrame ?? CGRect(x: 0, y: 0, width: 800, height: 600)
        panel.setFrame(
            CGRect(x: frame.midX - size.width / 2, y: frame.midY - size.height / 2, width: size.width, height: size.height),
            display: true
        )
        panel.orderFrontRegardless()
        if let hideAfter {
            hideTask = Task { [weak self] in
                try? await Task.sleep(for: hideAfter)
                guard !Task.isCancelled else { return }
                self?.panel?.orderOut(nil)
            }
        }
    }

    private func makePanel() -> NSPanel {
        let panel = NSPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: true)
        panel.level = .statusBar
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.ignoresMouseEvents = true
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        return panel
    }
}

struct HUDContent: View {
    var title: String
    var subtitle: String?
    var large: Bool

    var body: some View {
        VStack(spacing: 4) {
            if let subtitle, large {
                Text(subtitle).font(.callout).foregroundStyle(.white.opacity(0.75))
            }
            Text(title)
                .font(large ? .system(size: 64, weight: .semibold, design: .rounded).monospacedDigit() : .headline)
                .foregroundStyle(.white)
            if let subtitle, !large {
                Text(subtitle).font(.callout).foregroundStyle(.white.opacity(0.75)).lineLimit(2)
            }
        }
        .multilineTextAlignment(.center)
        .padding(.horizontal, large ? 36 : 20)
        .padding(.vertical, large ? 20 : 14)
        .frame(minWidth: large ? 160 : 220)
        // Solid translucent dark, like the system volume HUD: legible over any app.
        .background(Color(white: 0.1, opacity: 0.85), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
    }
}
