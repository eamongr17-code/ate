import AteKit
import SwiftUI

/// A pill search field. The design's only text input outside the composer.
struct AteSearchField: View {
    let prompt: String
    @Binding var text: String
    /// A sheet's field is 50 on the surface's `field`; `Search`'s own is 52 on `chip` with a wider
    /// inset. Both are in the markup, so both are here.
    var height: CGFloat = AteMetrics.fieldHeight
    var horizontalPadding: CGFloat = AteMetrics.loose
    var background: Color?
    /// 600 in a sheet, 500 in `Search` — the two artboards differ, so the field takes its voice.
    var textStyle: AteTextStyle = .rowTitle

    @Environment(\.atePalette) private var palette

    var body: some View {
        HStack(spacing: 10) {
            AteIcon.search.view(size: 18)
            TextField(text: $text) {
                Text(prompt).foregroundStyle(palette.muted)
            }
            .ateText(textStyle)
            .textFieldStyle(.plain)
            .foregroundStyle(palette.fg)
            .submitLabel(.search)
        }
        .padding(.horizontal, horizontalPadding)
        .atePillHeight(height)
        .background(background ?? palette.field, in: .capsule)
    }
}
