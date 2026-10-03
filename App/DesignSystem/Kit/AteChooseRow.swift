import SwiftUI

/// **A row that opens a chooser** — the Feed's "Choose your cravings", there only while nothing is
/// chosen: one line on the raised colour at the column's width, a muted chevron at its end. It opens
/// a sheet; it never pushes.
struct AteChooseRow: View {
    let title: String
    var identifier: String?
    let action: () -> Void

    @Environment(\.atePalette) private var palette

    var body: some View {
        Button(action: action) {
            HStack(spacing: AteMetrics.regular) {
                Text(title)
                    .ateText(.feedRow)
                    .foregroundStyle(palette.fg)
                    .frame(maxWidth: .infinity, alignment: .leading)
                AteIcon.chevron.view(size: AteChooseRowMetrics.chevron)
                    .foregroundStyle(palette.muted)
            }
            .padding(.leading, AteChooseRowMetrics.leading)
            .padding(.trailing, AteMetrics.loose)
            .frame(minHeight: AteChooseRowMetrics.height)
            .background(palette.raised, in: RoundedRectangle(cornerRadius: AteChooseRowMetrics.radius,
                                                              style: .continuous))
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier(identifier ?? "choose")
    }
}

enum AteChooseRowMetrics {
    /// `height:64px; border-radius:22px; padding:0 16px 0 18px`, its chevron 18.
    static let height: CGFloat = 64
    static let radius: CGFloat = 22
    static let leading: CGFloat = 18
    static let chevron: CGFloat = 18
}
