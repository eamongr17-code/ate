import AteKit
import SwiftUI

/// What a slip shows: an entry, reduced to the parts that survive being one of many in a list.
struct AteSlip: Equatable, Identifiable {
    let id: UUID
    var place: String
    var isPublic: Bool
    /// The person's own words, with their tokens.
    var words: EntryComposition
    var photos: [AtePhoto]
    /// Line items, already in the order the receipt prints them.
    var items: [AteReceipt.Item]
    /// Who wrote it and when — present in the feed, absent in your own journal.
    var byline: AteByline?

    init(
        id: UUID = UUID(),
        place: String,
        isPublic: Bool = true,
        words: EntryComposition,
        photos: [AtePhoto] = [],
        items: [AteReceipt.Item],
        byline: AteByline? = nil
    ) {
        self.id = id
        self.place = place
        self.isPublic = isPublic
        self.words = words
        self.photos = photos
        self.items = items
        self.byline = byline
    }
}

/// Who wrote an entry, for a feed slip's identity strip.
struct AteByline: Equatable {
    var userID: UUID
    var handle: String
    /// "2h", "1d" — already written, because how an age is worded is a product decision, not a view's.
    var age: String
    var isSaved: Bool

    init(userID: UUID, handle: String, age: String, isSaved: Bool = false) {
        self.userID = userID
        self.handle = handle
        self.age = age
        self.isSaved = isSaved
    }
}

/// **The journal slip.** A torn piece of paper: the place and whether it is public, the words with
/// their tokens clamped to three lines, a small tilted photo cluster, a dashed rule, and the line
/// items. Tapping it opens the entry.
struct JournalSlip: View {
    let slip: AteSlip
    var onTap: (() -> Void)?

    var body: some View {
        Button {
            onTap?()
        } label: {
            VStack(alignment: .leading, spacing: AteMetrics.regular) {
                HStack {
                    Text(slip.place)
                        .ateText(.slipPlace)
                        .lineLimit(2)
                    Spacer(minLength: AteMetrics.snug)
                    (slip.isPublic ? AteIcon.publicEntry : AteIcon.privateEntry)
                        .view(size: 16)
                        .foregroundStyle(AtePalette.paper.muted)
                        .accessibilityHidden(false)
                        .accessibilityLabel(slip.isPublic ? "Public" : "Private")
                }
                InlineTokenText(composition: slip.words, style: .prose, lineLimit: 3)
                if slip.photos.isEmpty == false {
                    PhotoCluster(photos: slip.photos, side: AteMetrics.clusterPhoto)
                }
                AteDashedRule()
                SlipLineItems(items: slip.items)
            }
            .padding(.top, AteMetrics.slipPadding)
            .padding(.horizontal, AteMetrics.slipPadding)
            .padding(.bottom, AteMetrics.slipPadding - 2 + AteMetrics.tornEdgeHeight)
            .frame(maxWidth: .infinity, alignment: .leading)
            .atePaper()
            .background(AteColor.paper, in: ReceiptPaper())
        }
        .buttonStyle(.plain)
        .disabled(onTap == nil)
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("journal.slip")
    }
}

/// **The feed slip.** The journal slip plus a byline, and denser: a straight 84pt thumbnail beside two
/// lines of words (design rule 6 — nothing in a scrolling list tilts), and at most two line items.
struct FeedSlip: View {
    let slip: AteSlip
    var onTap: (() -> Void)?
    var onProfileTap: (() -> Void)?
    var onSaveTap: (() -> Void)?

    /// The design's cap: a feed slip is an invitation, not the whole entry.
    private static let maximumItems = 2

    var body: some View {
        VStack(alignment: .leading, spacing: AteMetrics.snug) {
            if let byline = slip.byline {
                bylineRow(byline)
            }
            Button {
                onTap?()
            } label: {
                VStack(alignment: .leading, spacing: AteMetrics.snug) {
                    HStack(alignment: .top, spacing: AteMetrics.regular) {
                        VStack(alignment: .leading, spacing: AteMetrics.tight) {
                            Text(slip.place)
                                .ateText(.feedPlace)
                                .lineLimit(1)
                            InlineTokenText(composition: slip.words, style: .proseCompact, lineLimit: 2)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        if let photo = slip.photos.first {
                            AteThumbnail(photo: photo)
                        }
                    }
                    AteDashedRule()
                    SlipLineItems(items: Array(slip.items.prefix(Self.maximumItems)))
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(.rect)
            }
            .buttonStyle(.plain)
            .disabled(onTap == nil)
        }
        .padding(.top, AteMetrics.snug)
        .padding(.horizontal, AteMetrics.slipPadding)
        .padding(.bottom, AteMetrics.regular + AteMetrics.tornEdgeHeight)
        .frame(maxWidth: .infinity, alignment: .leading)
        .atePaper()
        .background(AteColor.paper, in: ReceiptPaper())
    }

    private func bylineRow(_ byline: AteByline) -> some View {
        HStack(spacing: AteMetrics.snug + 2) {
            Button {
                onProfileTap?()
            } label: {
                HStack(spacing: AteMetrics.snug + 2) {
                    AteAvatar(userID: byline.userID, handle: byline.handle)
                    Text(verbatim: "@\(byline.handle)")
                        .ateText(.controlSmall)
                    Text(byline.age)
                        .ateText(.meta)
                        .foregroundStyle(AtePalette.paper.muted)
                    Spacer(minLength: 0)
                }
                .contentShape(.rect)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("@\(byline.handle), \(byline.age)")
            Button {
                onSaveTap?()
            } label: {
                (byline.isSaved ? AteIcon.saved : AteIcon.save)
                    .view(size: 22)
                    .frame(width: AteMetrics.hit, height: AteMetrics.hit)
                    .contentShape(.rect)
            }
            .buttonStyle(.plain)
            .padding(.trailing, -10)
            .accessibilityLabel(byline.isSaved ? "Saved" : "Save")
        }
    }
}

/// A slip's numbered line items — the same bill rows the receipt prints, without its bands.
struct SlipLineItems: View {
    let items: [AteReceipt.Item]

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(Array(items.enumerated()), id: \.element.id) { index, item in
                HStack(alignment: .firstTextBaseline, spacing: AteMetrics.snug) {
                    Text(String(format: "%02d", index + 1))
                        .ateText(.receiptLine)
                        .foregroundStyle(AtePalette.paper.muted)
                    Text(item.name)
                        .ateText(.receiptLine)
                        .lineLimit(1)
                        // The leader is a greedy Canvas; without this it claims space from the name
                        // and a dish that fits on one line is elided anyway.
                        .layoutPriority(1)
                    AteDotLeader()
                        .alignmentGuide(.firstTextBaseline) { $0[.bottom] + 4 }
                    if let score = item.score {
                        Text(ScoreFormat.halfStep(score.value))
                            .ateText(.receiptScore)
                            .monospacedDigit()
                    } else {
                        UnscoredMark(side: 14)
                            .alignmentGuide(.firstTextBaseline) { $0[.bottom] - 2 }
                    }
                }
                .accessibilityElement(children: .combine)
            }
        }
    }
}

/// A byline avatar: two letters on one of the six accents, picked deterministically from the person's
/// UUID — never from their position in a list, which would re-colour people as a feed loads.
struct AteAvatar: View {
    let userID: UUID
    let handle: String
    var side: CGFloat = AteMetrics.avatar

    var body: some View {
        Text(initials)
            .ateText(.avatarInitial)
            .foregroundStyle(AteColor.ink)
            .frame(width: side, height: side)
            .background(AteColor.accents[AteAvatar.index(for: userID)], in: .circle)
            .accessibilityHidden(true)
    }

    private var initials: String {
        let letters = handle.filter(\.isLetter)
        return String(letters.prefix(1)).uppercased()
    }

    /// Stable across launches and devices: the UUID's own bytes, not `hashValue` (which is seeded per
    /// process and would give the same person a different colour every launch).
    static func index(for id: UUID) -> Int {
        withUnsafeBytes(of: id.uuid) { bytes in
            Int(bytes.reduce(into: UInt8(0)) { $0 = $0 &+ $1 }) % AteColor.accents.count
        }
    }
}

// `DEBUG || BETA`: the gallery these feed ships to TestFlight.
#if DEBUG || BETA
extension AteSlip {
    @MainActor
    static var previewJournal: AteSlip {
        AteSlip(
            place: "Tipo 00",
            words: .previewWords,
            photos: AtePhoto.swatches,
            items: AteReceipt.preview.items
        )
    }

    @MainActor
    static var previewFeed: AteSlip {
        AteSlip(
            place: "Butchers Diner",
            words: .previewFeedWords,
            photos: [AtePhoto.swatch(AteColor.coral)],
            items: [
                AteReceipt.Item(name: "Cheeseburger", score: Rating(rounding: 4.5)),
                AteReceipt.Item(name: "Fries", score: Rating(rounding: 4))
            ],
            byline: AteByline(userID: UUID(uuidString: "11111111-2222-3333-4444-555555555555")!,
                             handle: "marcus.eats", age: "5h")
        )
    }
}

extension EntryComposition {
    /// Builds a fixture by *finding* each token's words in the sentence rather than hand-counting
    /// offsets — a fixture with a wrong offset is refused by the model and would silently show no
    /// tokens at all.
    static func fixture(_ text: String, _ kinds: [EntryTokenKind]) -> EntryComposition {
        var spans: [EntryTokenSpan] = []
        var searchStart = text.startIndex
        for kind in kinds {
            guard let range = text.range(of: kind.plainText, range: searchStart..<text.endIndex),
                  let lower = range.lowerBound.samePosition(in: text.utf16) else { continue }
            let location = text.utf16.distance(from: text.utf16.startIndex, to: lower)
            spans.append(EntryTokenSpan(
                token: EntryToken(kind: kind),
                span: TextSpan(location: location, length: kind.plainText.utf16.count)
            ))
            searchStart = range.upperBound
        }
        return EntryComposition(plain: text, spans: spans)
    }

    /// The prototype's own sentence, tokens and all.
    static var previewWords: EntryComposition {
        fixture(
            "With Jess for her birthday. The tagliatelle al ragù 4.5 was unreal, rich, glossy, "
                + "gone in four minutes. Tiramisu 3.0 a bit flat after that.",
            [.score(Rating(rounding: 4.5)), .score(Rating(rounding: 3))]
        )
    }

    static var previewFeedWords: EntryComposition {
        fixture(
            "Queued forty minutes for this cheeseburger 4.5 and would queue again.",
            [.score(Rating(rounding: 4.5))]
        )
    }

    /// With a place token leading the sentence, as the composer and entry page show it.
    static var previewWordsWithPlace: EntryComposition {
        fixture(
            "Tipo 00 with Jess for her birthday. The tagliatelle al ragù 4.5 was unreal, rich, "
                + "glossy, gone in four minutes. Tiramisu 3.0 a bit flat after that.",
            [.place(PlaceRef(id: UUID(), name: "Tipo 00")), .score(Rating(rounding: 4.5)),
             .score(Rating(rounding: 3))]
        )
    }
}
#endif

#if DEBUG
#Preview("Slips") {
    ScrollView {
        VStack(spacing: AteMetrics.slipGap) {
            JournalSlip(slip: .previewJournal, onTap: {})
            FeedSlip(slip: .previewFeed, onTap: {}, onProfileTap: {}, onSaveTap: {})
        }
        .padding(.horizontal, AteMetrics.gutter)
        .padding(.vertical, AteMetrics.section)
    }
    .ateGround()
}
#endif
