import AteKit
import SwiftUI

/// **A dish review: who, and how much** (round 4) — the review avatar, the handle (or "You"), and
/// their score as the token at the right. No words: the words are one tap away, in the entry.
///
/// Two doors side by side (a button inside a button's label is never heard): the avatar and handle
/// open **the person**, the rest of the row opens **the visit**. Either is simply not a control when
/// it has nowhere to go — your own name, a blocked author, a legacy review with no entry.
struct AteReviewRow: View {
    let userID: UUID
    /// "You", "@jessw", or "Someone" for an author who is gone.
    let name: String
    let handle: String
    var rating: Rating?
    var isFirst = false
    var onProfile: (() -> Void)?
    var onOpen: (() -> Void)?

    @Environment(\.atePalette) private var palette

    var body: some View {
        HStack(spacing: 0) {
            door(onProfile, identifier: "dish.review.person") {
                HStack(spacing: AteDishRowMetrics.gap) {
                    AteAvatar(userID: userID, handle: handle, size: .review)
                    Text(name)
                        .ateText(.controlSmall)
                        .foregroundStyle(palette.fg)
                        .lineLimit(1)
                }
                .padding(.trailing, AteDishRowMetrics.gap)
            }
            door(onOpen, identifier: "dish.review.entry") {
                // An unrated review's token draws nothing, and a frame on nothing is nothing: the
                // spacer keeps the visit's door — and the row, and its hairline — the full width.
                HStack(spacing: 0) {
                    Spacer(minLength: 0)
                    AteScoreToken(rating: rating)
                }
            }
        }
        .frame(maxWidth: .infinity, minHeight: AteReviewRowMetrics.height)
        .overlay(alignment: .top) {
            if isFirst == false { AteHairline() }
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("dish.review")
    }

    @ViewBuilder
    private func door(
        _ action: (() -> Void)?,
        identifier: String,
        @ViewBuilder label: () -> some View
    ) -> some View {
        let face = label()
            .frame(minHeight: AteReviewRowMetrics.height)
            .contentShape(.rect)
        if let action {
            Button(action: action) { face }
                .buttonStyle(.plain)
                .accessibilityElement(children: .combine)
                .accessibilityIdentifier(identifier)
        } else {
            face.accessibilityElement(children: .combine)
        }
    }
}

/// The reviews before they arrive: the avatar, the handle and the token, still.
struct AteReviewRowSkeleton: View {
    var count = 3

    @Environment(\.atePalette) private var palette

    var body: some View {
        VStack(spacing: 0) {
            ForEach(0..<count, id: \.self) { index in
                HStack(spacing: AteDishRowMetrics.gap) {
                    Circle()
                        .fill(palette.hairline)
                        .frame(width: AteReviewRowMetrics.avatar, height: AteReviewRowMetrics.avatar)
                    AteSkeletonBar(width: AteReviewRowMetrics.handleBar, height: AteReviewRowMetrics.bar,
                                   palette: palette)
                    Spacer(minLength: 0)
                    AteSkeletonBar(width: AteReviewRowMetrics.tokenBar, height: AteReviewRowMetrics.tokenHeight,
                                   palette: palette)
                }
                .frame(minHeight: AteReviewRowMetrics.height)
                .overlay(alignment: .top) {
                    if index > 0 { AteHairline() }
                }
            }
        }
        .ateBreathing()
        .accessibilityHidden(true)
    }
}

enum AteReviewRowMetrics {
    /// `padding:14px 0` around a 36 avatar.
    static let avatar: CGFloat = 36
    static let height: CGFloat = 64
    static let handleBar: CGFloat = 88
    static let bar: CGFloat = 12
    static let tokenBar: CGFloat = 46
    static let tokenHeight: CGFloat = 22
}
