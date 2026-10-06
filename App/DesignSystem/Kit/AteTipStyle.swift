import SwiftUI
import TipKit

/// **A first-run tip's face** — TipKit's own popover, with Ate's words in it: the title in
/// Bricolage, one line of prose under it in muted ink, and a quiet ✕. Its width is fixed
/// (`first-run.html`'s 300) so the system lays the popover beside the control it points at.
/// Left to fill the screen it sits centred whatever it points to (Eamon, build 98).
struct AteTipStyle: TipViewStyle {
    func makeBody(configuration: Configuration) -> some View {
        HStack(alignment: .top, spacing: AteMetrics.regular) {
            VStack(alignment: .leading, spacing: AteMetrics.hairspace) {
                configuration.title?.ateText(.rowTitle)
                    .foregroundStyle(AtePalette.automatic.fg)
                configuration.message?.ateText(.prose)
                    .foregroundStyle(AtePalette.automatic.muted)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .fixedSize(horizontal: false, vertical: true)
            Button {
                configuration.tip.invalidate(reason: .tipClosed)
            } label: {
                AteIcon.close.view(size: AteTipMetrics.close)
                    .frame(width: AteMetrics.hit, height: AteMetrics.hit)
                    .contentShape(.rect)
            }
            .buttonStyle(.plain)
            .foregroundStyle(AtePalette.automatic.muted)
            .padding(.top, -AteMetrics.regular)
            .padding(.trailing, -AteMetrics.regular)
            .accessibilityLabel("Close tip")
        }
        .padding(AteMetrics.loose)
        .frame(width: AteTipMetrics.width)
    }
}

enum AteTipMetrics {
    /// `.tipk{width:300px}`.
    static let width: CGFloat = 300
    static let close: CGFloat = 16
}
