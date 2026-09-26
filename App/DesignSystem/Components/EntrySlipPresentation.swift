import AteKit
import SwiftUI

/// **One row, three slips.** Turning an `entry_cards` row into the slip the design draws, in the one
/// place that does it — the journal, the feed and a profile show the same component and must never
/// drift into showing the same entry differently.
///
/// Pure and free of the network, so "what does this entry look like in a list" can be reasoned about
/// without one.
enum EntrySlipPresentation {

    /// Your own journal: no byline, no bookmarks (your entries are written, not saved), and the
    /// right of the foot line carries the day you ate.
    static func journal(_ card: EntryCard, timeZone: TimeZone = .autoupdatingCurrent) -> AteSlip {
        slip(card, surface: .journal, meta: .day(RelativeAge.day(card.createdAt, timeZone: timeZone)))
    }

    /// The feed: the person is named above the stack, every dish carries its own bookmark, and a
    /// visit of three dishes or more leaves its words to the entry (``SlipAnatomy``).
    static func feed(_ card: EntryCard, now: Date = Date()) -> AteSlip {
        var slip = slip(card, surface: .feed, meta: .none)
        // A blocked or deleted author is simply absent from the row (contract). The entry is still
        // readable; it just loses its byline rather than taking the page down.
        if let author = card.author {
            slip.byline = AteByline(
                userID: author.id,
                handle: author.username,
                age: RelativeAge.short(card.createdAt, now: now)
            )
        }
        return slip
    }

    /// A profile: the byline would be the page's own title repeated, so the age moves to the right
    /// of the foot line — where the journal prints its date — and the stack keeps its bookmarks.
    static func profile(_ card: EntryCard, now: Date = Date()) -> AteSlip {
        slip(card, surface: .profile, meta: .age(RelativeAge.short(card.createdAt, now: now)))
    }

    // MARK: - The shape they share

    /// The design's cluster: three photos, tilted. A fourth would be a fourth angle and a wider
    /// stack than the artboard draws — the rest stay on the entry.
    private static let maximumPhotos = 3

    private static func slip(_ card: EntryCard, surface: SlipAnatomy.Surface, meta: AteSlip.Meta) -> AteSlip {
        let showsWords = SlipAnatomy.showsWords(on: surface, dishCount: card.items.count)
        var slip = AteSlip(
            id: card.id,
            dishes: card.items.map {
                AteSlip.Dish(
                    id: $0.reviewID,
                    dishID: $0.dishID,
                    name: $0.dishName,
                    score: $0.score,
                    isSaved: $0.saved
                )
            },
            place: card.place?.name,
            placeID: card.place?.id,
            suburb: card.place?.suburb,
            meta: meta,
            // The foot line already says the place, so a pill at the very start of the words is the
            // same fact twice. A place named mid-sentence is part of the sentence and stays: the
            // words themselves are never rewritten, only the decoration comes off.
            words: showsWords
                ? EntryPresentation.composition(for: card).droppingLeadingPlace()
                : EntryComposition(plain: "", spans: []),
            photos: card.photos.prefix(maximumPhotos).map { AtePhoto(url: URL(string: $0.url)) }
        )
        slip.wordsLineLimit = SlipAnatomy.wordsLineLimit(on: surface)
        return slip
    }
}

/// First load, drawn as the component it is waiting for — never a spinner (`docs/DESIGN.md`).
///
/// The shape of a real slip: two dish rows parted by a hairline, two lines of words, a foot line.
/// Nothing animates and nothing shimmers; it is paper that has not been written on yet.
struct SlipSkeleton: View {
    var count = 2
    /// The feed's skeletons carry a byline row, because the feed's slips do.
    var hasByline = false

    var body: some View {
        VStack(alignment: .leading, spacing: AteMetrics.slipGap) {
            ForEach(0..<count, id: \.self) { _ in
                VStack(alignment: .leading, spacing: AteMetrics.slipBandGap) {
                    if hasByline {
                        HStack(spacing: AteMetrics.snug) {
                            Circle()
                                .fill(AtePalette.slip.hairline)
                                .frame(width: AteMetrics.avatar, height: AteMetrics.avatar)
                            bar(width: 88, height: 12)
                        }
                    }
                    VStack(alignment: .leading, spacing: 0) {
                        ForEach(0..<2, id: \.self) { row in
                            VStack(spacing: 0) {
                                if row > 0 { AteHairline() }
                                HStack {
                                    bar(width: row == 0 ? 168 : 120, height: 18)
                                    Spacer(minLength: 0)
                                    bar(width: 56, height: 20)
                                }
                                .frame(minHeight: AteMetrics.hit)
                            }
                        }
                    }
                    // The words, then the foot line — the order a real slip prints them in.
                    bar(height: 12)
                    bar(width: 220, height: 12)
                    bar(width: 110, height: 12)
                }
                .padding(.top, hasByline ? AteMetrics.slipPaddingTop : AteMetrics.slipPaddingTopBare)
                .padding(.horizontal, AteMetrics.slipPadding)
                .padding(.bottom, AteMetrics.slipPaddingBottom + AteMetrics.tornEdgeHeight)
                .frame(maxWidth: .infinity, alignment: .leading)
                .ateSlip()
                .background(AteColor.slip, in: ReceiptPaper())
            }
        }
        .accessibilityHidden(true)
    }

    /// A blank line of the thing that is coming. `width: nil` fills the paper, the way a line of
    /// words does.
    private func bar(width: CGFloat? = nil, height: CGFloat) -> some View {
        RoundedRectangle(cornerRadius: height / 2, style: .continuous)
            .fill(AtePalette.slip.hairline)
            .frame(width: width, height: height)
            .frame(maxWidth: width == nil ? .infinity : nil, alignment: .leading)
    }
}

#if DEBUG
#Preview("Skeleton") {
    ScrollView {
        VStack(spacing: AteMetrics.slipGap) {
            SlipSkeleton(count: 1, hasByline: true)
            SlipSkeleton(count: 1)
        }
        .padding(.horizontal, AteMetrics.listGutter)
        .padding(.vertical, AteMetrics.section)
    }
    .ateGround()
}
#endif
