import SwiftUI

/// **A labelled text field** — the "New place" sheet's Name, Suburb and Street: the label in muted
/// meta, and under it the 50pt pill in the field colour that a sheet's search field also is. An
/// optional prompt sits in the empty pill ("Optional").
struct AteFieldPill: View {
    let label: String
    @Binding var text: String
    var prompt: String?
    var identifier: String?

    @Environment(\.atePalette) private var palette

    var body: some View {
        VStack(alignment: .leading, spacing: AteFieldPillMetrics.labelGap) {
            Text(label)
                .ateText(.meta)
                .foregroundStyle(palette.muted)
            TextField(text: $text) {
                Text(prompt ?? "").foregroundStyle(palette.muted)
            }
            .ateText(.rowTitle)
            .textFieldStyle(.plain)
            .foregroundStyle(palette.fg)
            .padding(.horizontal, AteMetrics.loose)
            .atePillHeight(AteMetrics.fieldHeight)
            .background(palette.field, in: .capsule)
            .accessibilityLabel(label)
            .accessibilityIdentifier(identifier ?? "field.\(label.lowercased())")
        }
    }
}

enum AteFieldPillMetrics {
    /// The label over its pill: 6.
    static let labelGap: CGFloat = 6
}
