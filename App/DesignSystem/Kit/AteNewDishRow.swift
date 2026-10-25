import AteKit
import SwiftUI

/// **A New to the record row** — the Feed's `.nr`: the dish's thumbnail, the dish over its place, its
/// score and the bookmark, with a field-coloured rule under every row but the last. Only a rating
/// is ever printed there: no "New" pill (Eamon, 25 Oct), and nothing at all when there's no score.
/// The name is a ranked row's, line box and all, so the same dish reads the same in both sections.
struct AteNewDishRow: View {
    let photo: AtePhoto
    let name: String
    var place: String?
    let score: AteScore?
    var isSaved = false
    var isLast = false
    var onOpen: (() -> Void)?
    var onSave: (() -> Void)?

    @Environment(\.atePalette) private var palette

    var body: some View {
        HStack(spacing: AteNewDishRowMetrics.gap) {
            Button { onOpen?() } label: {
                HStack(spacing: AteNewDishRowMetrics.gap) {
                    AteThumb(photo: photo, size: .row)
                    VStack(alignment: .leading, spacing: AteNewDishRowMetrics.lineGap) {
                        Text(name)
                            .ateTextExactLifted(.kitRankedDish)
                            .foregroundStyle(palette.fg)
                            .lineLimit(2)
                        if let place {
                            Text(place)
                                .ateText(.meta)
                                .foregroundStyle(palette.muted)
                                .lineLimit(1)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    AteScoreToken(score)
                }
                .contentShape(.rect)
            }
            .buttonStyle(.plain)
            .accessibilityElement(children: .combine)
            .accessibilityIdentifier("new.open")
            if let onSave {
                AteSaveButton(dishName: name, isSaved: isSaved, identifier: "new.save", action: onSave)
                    .padding(.trailing, -AteNewDishRowMetrics.saveTrailing)
            }
        }
        .padding(.vertical, AteNewDishRowMetrics.padding)
        .overlay(alignment: .bottom) {
            if isLast == false {
                Rectangle().fill(palette.field).frame(height: 1)
            }
        }
    }
}

enum AteNewDishRowMetrics {
    /// `.nr{gap:12px; padding:10px 0}`, `.nr .d{gap:2px}`.
    static let gap: CGFloat = 12
    static let padding: CGFloat = 10
    static let lineGap: CGFloat = 2
    /// The bookmark's 44 target sits on the column's edge.
    static let saveTrailing: CGFloat = 12
}
