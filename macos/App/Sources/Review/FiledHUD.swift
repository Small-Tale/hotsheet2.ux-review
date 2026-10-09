import AppKit
import SwiftUI
import UXReviewKit

/// The transient confirmation after filing (`HS2-ZYV3SC`, docs/07 §7.2): a dark HUD, like the
/// capture HUD, with where the review went and **Open in Hot Sheet** (once the web client's link
/// is found) and **Copy Slug**. It never takes focus, stays while the pointer is over it, and
/// fades a few seconds after. The Submit Review window has closed by then.
@MainActor
final class FiledHUD {
    /// The HUD showing now; a new filing replaces it.
    private static var current: FiledHUD?

    private let panel: NSPanel
    private let model: ReviewSessionModel
    private var hideTask: Task<Void, Never>?

    /// Shows the HUD for `review`, centered on `frame` (the closing window's) on its screen.
    static func show(_ review: SubmittedReview, model: ReviewSessionModel, centeredOn frame: CGRect) {
        current?.dismiss()
        let hud = FiledHUD(review: review, model: model)
        current = hud
        hud.present(centeredOn: frame, seconds: review.confirmationSeconds)
    }

    private init(review: SubmittedReview, model: ReviewSessionModel) {
        self.model = model
        panel = NSPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: true)
        panel.level = .floating
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle]
        panel.contentView = NSHostingView(rootView: FiledHUDView(review: review, model: model) { [weak self] inside in
            self?.hover(inside)
        } done: { [weak self] in
            self?.dismiss()
        })
    }

    private var seconds: Double = 5

    private func present(centeredOn frame: CGRect, seconds: Double) {
        self.seconds = seconds
        guard let content = panel.contentView else { return }
        let size = content.fittingSize
        panel.setFrame(
            CGRect(x: frame.midX - size.width / 2, y: frame.midY - size.height / 2, width: size.width, height: size.height),
            display: true
        )
        panel.alphaValue = 1
        panel.orderFrontRegardless()
        scheduleHide()
    }

    private func hover(_ inside: Bool) {
        if inside { hideTask?.cancel() } else { scheduleHide() }
    }

    private func scheduleHide() {
        hideTask?.cancel()
        let seconds = seconds
        hideTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(seconds))
            guard !Task.isCancelled else { return }
            self?.fadeOut()
        }
    }

    private func fadeOut() {
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.3
            panel.animator().alphaValue = 0
        } completionHandler: { [weak self] in
            MainActor.assumeIsolated { self?.dismiss() }
        }
    }

    private func dismiss() {
        hideTask?.cancel()
        panel.orderOut(nil)
        if Self.current === self { Self.current = nil }
    }
}

/// The HUD's content: dark and translucent like the capture HUD, white text, small buttons.
struct FiledHUDView: View {
    let review: SubmittedReview
    @ObservedObject var model: ReviewSessionModel
    var hover: (Bool) -> Void = { _ in }
    var done: () -> Void = {}

    var body: some View {
        VStack(spacing: 8) {
            HStack(spacing: 8) {
                Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
                Text(review.confirmationTitle).font(.headline).foregroundStyle(.white)
            }
            Text(review.confirmationDetail)
                .font(.callout)
                .foregroundStyle(.white.opacity(0.75))
                .multilineTextAlignment(.center)
                .lineLimit(3)
                .frame(maxWidth: 320)
            HStack(spacing: 8) {
                if model.hotSheetLink != nil {
                    Button("Open in Hot Sheet") {
                        model.openInHotSheet()
                        done()
                    }
                }
                Button("Copy Slug") {
                    model.copySlug()
                    done()
                }
            }
            .controlSize(.small)
            .buttonStyle(.bordered)
            .environment(\.colorScheme, .dark)
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 14)
        .frame(minWidth: 260)
        .background(Color(white: 0.1, opacity: 0.85), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .onHover(perform: hover)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("\(review.confirmationTitle). \(review.confirmationDetail)")
    }
}
