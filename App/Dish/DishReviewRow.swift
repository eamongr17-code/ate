import AteKit
import SwiftUI

/// **One review: who, and how much** (round 4) — a 36pt avatar, the handle, and their score as the
/// butter pill at the right. No words: the words are one tap away, in the entry.
///
/// Two doors, side by side rather than nested (a button inside a button's label is never heard):
/// the avatar and handle open **the person**, the rest of the row opens **the visit** it came out
/// of. A legacy review carries no `entry_id` (0018) and a blocked or deleted author no name — that
/// half is simply not a control then, because a control that goes nowhere is worse than none.
struct DishReviewRow: View {
    let review: DishReview
    let onOpen: () -> Void
    var onProfile: (() -> Void)?

    /// `padding:14px 0` around a 36pt avatar, `gap:12px`.
    private static let avatar: CGFloat = 36
    private static let padding: CGFloat = 14

    var body: some View {
        VStack(spacing: 0) {
            AteHairline()
            HStack(spacing: 0) {
                person
                visit
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier(review.isMine ? "dish.review.mine" : "dish.review")
    }

    @ViewBuilder
    private var person: some View {
        let label = HStack(spacing: AteMetrics.regular) {
            AteAvatar(
                userID: review.author?.id ?? review.reviewID,
                handle: handle,
                side: Self.avatar,
                textStyle: .avatarInitialMedium
            )
            Text(name)
                .ateText(.controlSmall)
                .lineLimit(1)
                .truncationMode(.tail)
        }
        .padding(.vertical, Self.padding)
        .padding(.trailing, AteMetrics.regular)
        .contentShape(.rect)
        if let onProfile {
            Button(action: onProfile) { label }
                .buttonStyle(.plain)
                .accessibilityElement(children: .combine)
                .accessibilityIdentifier("dish.review.person")
        } else {
            label.accessibilityElement(children: .combine)
        }
    }

    @ViewBuilder
    private var visit: some View {
        let label = HStack(spacing: 0) {
            Spacer(minLength: 0)
            score
        }
        .frame(maxWidth: .infinity, minHeight: Self.avatar + Self.padding * 2)
        .contentShape(.rect)
        if review.entryID == nil {
            label
        } else {
            Button(action: onOpen) { label }
                .buttonStyle(.plain)
                .accessibilityLabel(scoreLabel)
                .accessibilityIdentifier("dish.review.entry")
        }
    }

    /// "You" for your own, the handle for everybody else's. A missing author is blocked or gone —
    /// the review still stands, it just loses its name (contract).
    private var name: String {
        if review.isMine { return "You" }
        guard let username = review.author?.username else { return "Someone" }
        return "@\(username)"
    }

    private var handle: String { review.author?.username ?? "?" }

    private var scoreLabel: String {
        review.score.map { "\(name), \(ScoreFormat.halfStep($0.value))" } ?? name
    }

    /// Design rule 7: an unrated review leaves the score slot empty — no number, no zero, no mark.
    @ViewBuilder
    private var score: some View {
        if let score = review.score {
            ScoreToken(rating: score, prose: 16)
        }
    }
}

/// The header before it has arrived — the shape of a dish, not a spinner.
struct DishHeaderSkeleton: View {
    var body: some View {
        VStack(alignment: .leading, spacing: AteMetrics.loose) {
            RoundedRectangle(cornerRadius: 42, style: .continuous)
                .fill(AtePalette.automatic.hairline)
                .frame(width: 150, height: 150)
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(AtePalette.automatic.hairline)
                .frame(width: 240, height: 36)
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .fill(AtePalette.automatic.hairline)
                .frame(width: 96, height: 16)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityHidden(true)
    }
}

/// …and the reviews, drawn as the rows they are waiting for.
struct ReviewSkeleton: View {
    var body: some View {
        VStack(spacing: 0) {
            ForEach(0..<3, id: \.self) { _ in
                VStack(spacing: 0) {
                    AteHairline()
                    HStack(spacing: AteMetrics.regular) {
                        Circle()
                            .fill(AtePalette.automatic.hairline)
                            .frame(width: 36, height: 36)
                        RoundedRectangle(cornerRadius: 6, style: .continuous)
                            .fill(AtePalette.automatic.hairline)
                            .frame(width: 88, height: 12)
                        Spacer(minLength: 0)
                        Capsule()
                            .fill(AtePalette.automatic.hairline)
                            .frame(width: 46, height: 20)
                    }
                    .padding(.vertical, 14)
                }
            }
        }
        .accessibilityHidden(true)
    }
}
