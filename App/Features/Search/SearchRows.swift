import AteKit
import SwiftUI

/// Score + count, or the honest "unrated" mark.
///
/// A null average is a *product state* ("nobody's rated this yet"), not missing data, so it renders
/// `–/5` and never `0`. This is the compact, list-row rendering; the DishCard's larger `ScoreMark`
/// lands with that surface and the two should be unified at that point.
struct SearchScoreMark: View {
    let score: Double?
    let reviewCount: Int
    var showsCount = true

    var body: some View {
        HStack(spacing: Theme.Spacing.tight) {
            if let score {
                Image(systemName: "star.fill")
                    .foregroundStyle(Theme.Color.accent)
                    .imageScale(.small)
                Text(score.formatted(.number.precision(.fractionLength(1))))
                    .font(Theme.Text.rowScore)
                    .foregroundStyle(Theme.Color.textPrimary)
                if showsCount, reviewCount > 0 {
                    Text("(\(reviewCount))")
                        .font(Theme.Text.caption)
                        .foregroundStyle(Theme.Color.textTertiary)
                }
            } else {
                Text("–/5")
                    .font(Theme.Text.rowScore)
                    .foregroundStyle(Theme.Color.textTertiary)
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibilityLabel)
    }

    private var accessibilityLabel: String {
        guard let score else { return "Not rated yet" }
        let value = score.formatted(.number.precision(.fractionLength(1)))
        return reviewCount > 0 ? "\(value) out of 5, \(reviewCount) reviews" : "\(value) out of 5"
    }
}

/// One restaurant row. Identical for every kind and section — a manual row and a Places prediction
/// are visually indistinguishable by design (manual-search-blend-contract §6).
struct RestaurantResultRow: View {
    let row: RestaurantRowModel
    let isResolving: Bool

    var body: some View {
        HStack(spacing: Theme.Spacing.regular) {
            VStack(alignment: .leading, spacing: Theme.Spacing.hairline) {
                Text(row.name)
                    .font(Theme.Text.itemTitle)
                    .foregroundStyle(Theme.Color.textPrimary)
                    .lineLimit(1)
                if let detail {
                    Text(detail)
                        .font(Theme.Text.detail)
                        .foregroundStyle(Theme.Color.textSecondary)
                        .lineLimit(1)
                }
            }
            Spacer(minLength: Theme.Spacing.snug)
            if isResolving {
                ProgressView().controlSize(.small)
            }
        }
        .contentShape(.rect)
        .accessibilityElement(children: .combine)
    }

    /// "Fitzroy · 1.2 km", "Fitzroy", "1.2 km", or nothing. Never "0 km", never an empty separator.
    private var detail: String? {
        [row.secondary, SearchDistance.string(meters: row.distanceMeters)]
            .compactMap { $0 }
            .joined(separator: " · ")
            .nilIfBlank
    }
}

/// One dish row: name over restaurant (in the global scope), score trailing.
struct DishResultRow: View {
    let row: DishRowModel

    var body: some View {
        HStack(spacing: Theme.Spacing.regular) {
            // §3: the picker is where a dish most often has no photo yet, so it is the surface the
            // tile matters most on — fifteen grey squares is what "pick a dish" used to look like.
            DishTile(
                dish: DishTileSubject(id: row.dishID, name: row.name),
                size: Theme.Size.thumbnail
            )
            VStack(alignment: .leading, spacing: Theme.Spacing.hairline) {
                Text(row.name)
                    .font(Theme.Text.itemTitle)
                    .foregroundStyle(Theme.Color.textPrimary)
                    .lineLimit(2)
                if let restaurantName = row.restaurantName {
                    Text(restaurantName)
                        .font(Theme.Text.detail)
                        .foregroundStyle(Theme.Color.textSecondary)
                        .lineLimit(1)
                }
                if let yourScore = row.yourScore {
                    Text("you rated \(yourScore.value.formatted(.number.precision(.fractionLength(1))))")
                        .font(Theme.Text.caption)
                        .foregroundStyle(Theme.Color.textSecondary)
                }
            }
            Spacer(minLength: Theme.Spacing.snug)
            SearchScoreMark(score: row.score, reviewCount: row.reviewCount)
        }
        .contentShape(.rect)
    }
}

/// The **standing add row** (§6). Permanently visible in both pickers, and permanently LAST.
///
/// Its whole job is to be findable without competing: zero-results gating is gone (a person who
/// knows the dish isn't listed shouldn't have to prove it by typing something that returns nothing),
/// so the row is always there — which only works if it is visually demoted. `detail`/`textSecondary`
/// with a leading plus, deliberately NOT the accent colour and never a filled button: an accent-
/// coloured permanent row reads as the primary action of a list whose primary action is *picking*.
struct SearchCreateRow: View {
    let title: LocalizedStringKey
    let isBusy: Bool

    var body: some View {
        HStack(spacing: Theme.Spacing.regular) {
            Label(title, systemImage: "plus")
                .font(Theme.Text.detail)
                .foregroundStyle(Theme.Color.textSecondary)
            Spacer(minLength: Theme.Spacing.snug)
            if isBusy {
                ProgressView().controlSize(.small)
            }
        }
        .contentShape(.rect)
    }
}

/// The inline failure row (§11.5): a caption, never a full-screen error and never an alert. Loaded
/// content above it stays on screen and stays selectable.
struct SearchRetryRow: View {
    let failure: SearchFailure
    let retry: () -> Void

    var body: some View {
        Button(action: retry) {
            Label(message, systemImage: icon)
                .font(Theme.Text.caption)
                .foregroundStyle(Theme.Color.textSecondary)
        }
        .buttonStyle(.plain)
        .disabled(!failure.isRetryable)
    }

    private var message: LocalizedStringKey {
        switch failure {
        case .offline: "Offline — showing what's cached. Tap to retry."
        case .failed: "Couldn't search. Tap to retry."
        case .signedOut: "Sign in to search."
        }
    }

    private var icon: String {
        switch failure {
        case .offline: "wifi.slash"
        case .failed: "arrow.clockwise"
        case .signedOut: "person.crop.circle.badge.questionmark"
        }
    }
}

/// §11.5 first load: three redacted real rows, same geometry — no bespoke skeleton.
struct SearchPlaceholderRows: View {
    var body: some View {
        ForEach(0..<3, id: \.self) { _ in
            RestaurantResultRow(
                row: RestaurantRowModel(
                    id: "placeholder",
                    name: "Placeholder restaurant",
                    secondary: "Suburb",
                    distanceMeters: 1200,
                    selection: .place(googlePlaceID: "")
                ),
                isResolving: false
            )
            .redacted(reason: .placeholder)
            .accessibilityHidden(true)
        }
    }
}
