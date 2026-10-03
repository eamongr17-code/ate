import AteKit
import SwiftUI

/// **A New to the record row** — the Feed's `.nr`: the dish's thumbnail, the dish over its place, its
/// badge and the bookmark, with a field-coloured rule under every row but the last. The badge says
/// why it is new: a secret 6 and a 5.0 are their score tokens (brick and butter), anything else is
/// "New" on the field colour.
struct AteNewDishRow: View {
    enum Badge: Equatable {
        case score(AteScore)
        case new
    }

    let photo: AtePhoto
    let name: String
    var place: String?
    let badge: Badge
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
                            .ateText(.feedNewDish)
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
                    badgeView
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

    @ViewBuilder
    private var badgeView: some View {
        switch badge {
        case .score(let score):
            AteScoreToken(score)
        case .new:
            Text("New")
                .ateText(.feedBadge)
                .padding(.horizontal, AteNewDishRowMetrics.badgePadding)
                .padding(.vertical, AteNewDishRowMetrics.badgeVertical)
                .foregroundStyle(palette.fg)
                .background(palette.field, in: .capsule)
                .fixedSize()
        }
    }
}

enum AteNewDishRowMetrics {
    /// `.nr{gap:12px; padding:10px 0}`, `.nr .d{gap:2px}`.
    static let gap: CGFloat = 12
    static let padding: CGFloat = 10
    static let lineGap: CGFloat = 2
    /// `.badge{padding:3px 10px}`.
    static let badgePadding: CGFloat = 10
    static let badgeVertical: CGFloat = 3
    /// The bookmark's 44 target sits on the column's edge.
    static let saveTrailing: CGFloat = 12
}
