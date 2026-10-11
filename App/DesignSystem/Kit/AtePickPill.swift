import SwiftUI

/// **A field you fill by choosing** — ``AteFieldPill``'s label and pill, holding a choice made on
/// another sheet (a place) instead of typed text. Empty, it shows its prompt in the muted colour with
/// the icon leading; chosen, the value in the row title's type, and — when the choice has one — its
/// second line under it (a suggested place's locality, `share-to-ate.html`).
struct AtePickPill: View {
    let label: String
    let icon: AteIcon
    let value: String?
    var detail: String?
    let prompt: String
    var identifier: String?
    let action: () -> Void

    @Environment(\.atePalette) private var palette

    var body: some View {
        VStack(alignment: .leading, spacing: AteFieldPillMetrics.labelGap) {
            Text(label)
                .ateText(.meta)
                .foregroundStyle(palette.muted)
            Button(action: action) {
                HStack(spacing: AteMetrics.snug) {
                    icon.view(size: AtePickPillMetrics.icon)
                        .foregroundStyle(palette.muted)
                    VStack(alignment: .leading, spacing: AtePickPillMetrics.detailGap) {
                        Text(value ?? prompt)
                            .ateText(.rowTitle)
                            .foregroundStyle(value == nil ? palette.muted : palette.fg)
                            .lineLimit(1)
                        if value != nil, let detail {
                            Text(detail)
                                .ateText(.kitPickDetail)
                                .foregroundStyle(palette.muted)
                                .lineLimit(1)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .padding(.horizontal, AteMetrics.loose)
                .atePillHeight(AteMetrics.fieldHeight)
                .background(palette.field, in: .capsule)
                .contentShape(.capsule)
            }
            .buttonStyle(.plain)
            .accessibilityLabel(label)
            .accessibilityValue([value, detail].compactMap { $0 }.joined(separator: ", "))
            .accessibilityIdentifier(identifier ?? "pick.\(label.lowercased())")
        }
    }
}

enum AtePickPillMetrics {
    static let icon: CGFloat = 18
    /// The value over its second line: `gap:2px`.
    static let detailGap: CGFloat = 2
}
