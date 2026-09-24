import AteKit
import SwiftUI

/// What a slip shows: an entry, reduced to the parts that survive being one of many in a list.
///
/// **The dish is the item.** A slip opens with its dishes — the thing somebody ate and what they
/// gave it — and the place, the words and the photos follow underneath. That order is the CEO's
/// ruling and it is the same in the journal, in the feed and on a profile; what changes between
/// them is only who is named and what can be tapped.
struct AteSlip: Equatable, Identifiable {
    /// One line of the stack: a dish, a score, and whether the viewer has it saved.
    struct Dish: Equatable, Identifiable {
        /// The review line's id — unique within an entry even when a dish repeats.
        let id: UUID
        var dishID: UUID
        var name: String
        var score: Rating?
        var isSaved: Bool

        init(id: UUID, dishID: UUID, name: String, score: Rating? = nil, isSaved: Bool = false) {
            self.id = id
            self.dishID = dishID
            self.name = name
            self.score = score
            self.isSaved = isSaved
        }
    }

    /// What the right-hand end of the place line says. Design rule 2: two values, left and right,
    /// never a dot separator — and never both a time and an age.
    enum Meta: Equatable {
        /// Your own journal: when you ate, and who can see it.
        case time(String, isPublic: Bool)
        /// A profile: how long ago. (In the feed the byline already carries it.)
        case age(String)
        case none
    }

    let id: UUID
    var dishes: [Dish]
    /// `nil` when no place is attached — it is drawn as nothing, never as a guess (design rule 8).
    var place: String?
    var placeID: UUID?
    var meta: Meta
    /// The person's own words, with their tokens.
    var words: EntryComposition
    var photos: [AtePhoto]
    /// Who wrote it — present in the feed, absent in your own journal and on their own profile.
    var byline: AteByline?

    init(
        id: UUID = UUID(),
        dishes: [Dish] = [],
        place: String? = nil,
        placeID: UUID? = nil,
        meta: Meta = .none,
        words: EntryComposition,
        photos: [AtePhoto] = [],
        byline: AteByline? = nil
    ) {
        self.id = id
        self.dishes = dishes
        self.place = place
        self.placeID = placeID
        self.meta = meta
        self.words = words
        self.photos = photos
        self.byline = byline
    }
}

/// Who wrote an entry, for a feed slip's identity strip.
struct AteByline: Equatable {
    var userID: UUID
    var handle: String
    /// "2h", "1d" — already written, because how an age is worded is a product decision
    /// (``RelativeAge``), not a view's.
    var age: String
}

/// **The slip.** One component, three surfaces.
///
/// A torn piece of paper carrying, in order: the dish stack, the place line, the words at a two-line
/// clamp, and a small tilted photo cluster. Tapping it opens the entry.
///
/// `onSave` is what makes it a feed or profile slip: pass it and every dish row grows a bookmark,
/// because a save is always one dish and never a whole entry (PRODUCT.md decision 7). Pass a
/// `byline` and the person is named above the stack. Your own journal has neither.
struct EntrySlip: View {
    let slip: AteSlip
    var onOpen: (() -> Void)?
    var onProfile: (() -> Void)?
    /// Nil on the journal: your own entries are not saved, they are written.
    var onSave: ((AteSlip.Dish) -> Void)?
    /// The place line's pin opens the place page. Wired on every surface a slip appears on — the
    /// same tap must do the same thing in the journal, the feed and on a profile (AGENTS.md rule 2).
    var onPlace: ((UUID) -> Void)?
    /// …and a dish's name opens its page. The score and the bookmark beside it are not part of the
    /// target: one is a fact, the other is an action.
    var onDish: ((AteSlip.Dish) -> Void)?
    /// The identifier a drive reaches for. The journal's slips have always been `journal.slip`.
    var identifier = "journal.slip"

    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    var body: some View {
        Group {
            if isInteractive {
                // A slip with its own buttons in it cannot itself be a button — a tap inside a
                // `Button`'s label belongs to the outer button. So the parts that open the entry
                // say so one by one.
                paper { content(interactive: true) }
                    .accessibilityElement(children: .contain)
                    .accessibilityIdentifier(identifier)
            } else {
                Button {
                    onOpen?()
                } label: {
                    paper { content(interactive: false) }
                }
                .buttonStyle(.plain)
                .disabled(onOpen == nil)
                .accessibilityElement(children: .combine)
                .accessibilityIdentifier(identifier)
            }
        }
    }

    /// Whether the slip has controls of its own. When it does it cannot itself be a button — a tap
    /// inside a `Button`'s label belongs to the outer button — so its bands say what they open one
    /// by one instead.
    private var isInteractive: Bool {
        onSave != nil || onProfile != nil || onPlace != nil || onDish != nil
    }

    private func paper(@ViewBuilder _ content: () -> some View) -> some View {
        content()
            .padding(.top, AteMetrics.slipPaddingTop)
            .padding(.horizontal, AteMetrics.slipPadding)
            .padding(.bottom, AteMetrics.slipPaddingBottom + AteMetrics.tornEdgeHeight)
            .frame(maxWidth: .infinity, alignment: .leading)
            .atePaper()
            .background(AteColor.paper, in: ReceiptPaper())
    }

    @ViewBuilder
    private func content(interactive: Bool) -> some View {
        VStack(alignment: .leading, spacing: AteMetrics.slipBandGap) {
            if let byline = slip.byline {
                bylineRow(byline, interactive: interactive)
            }
            if slip.dishes.isEmpty == false {
                dishStack(interactive: interactive)
            }
            // The place line is its own band: the pin goes to the place, everything under it goes
            // to the entry. (A sibling rather than a child of the body's button — a tap inside a
            // button's label belongs to that button, so a nested one would never be heard.)
            if slip.place != nil || slip.meta != .none {
                placeLine(interactive: interactive)
            }
            // The words and the photos are one target: they are the entry, in miniature.
            tappable(interactive: interactive, part: "body") {
                VStack(alignment: .leading, spacing: AteMetrics.slipBandGap) {
                    if slip.words.plain.isEmpty == false {
                        InlineTokenText(composition: slip.words, style: .slipProse, lineLimit: 2)
                    }
                    if slip.photos.isEmpty == false {
                        PhotoCluster(
                            photos: slip.photos,
                            side: AteMetrics.clusterPhoto,
                            topPadding: AteMetrics.hairspace,
                            bottomPadding: 0
                        )
                    }
                }
            }
        }
    }

    /// Wraps a band in a button when the slip has its own controls, and leaves it alone when the
    /// whole slip is already one. `part` is what a drive reaches for: with bookmarks in the way, the
    /// slip is no longer one element, so its two halves are named.
    @ViewBuilder
    private func tappable(
        interactive: Bool,
        part: String,
        @ViewBuilder _ content: () -> some View
    ) -> some View {
        if interactive, let onOpen {
            Button(action: onOpen) {
                content()
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .contentShape(.rect)
            }
            .buttonStyle(.plain)
            .accessibilityElement(children: .combine)
            .accessibilityIdentifier("\(identifier).\(part)")
        } else {
            content()
        }
    }

    // MARK: - The dish stack

    private func dishStack(interactive: Bool) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(Array(slip.dishes.enumerated()), id: \.element.id) { index, dish in
                VStack(spacing: 0) {
                    // The design rules rows at the TOP, so the first dish starts on clean paper.
                    if index > 0 { AteHairline() }
                    dishRow(dish, interactive: interactive)
                }
            }
        }
    }

    private func dishRow(_ dish: AteSlip.Dish, interactive: Bool) -> some View {
        HStack(spacing: AteMetrics.regular) {
            dishTarget(dish, interactive: interactive) {
                HStack(spacing: AteMetrics.regular) {
                    Text(dish.name)
                        .ateText(.slipDish)
                        // A dish name wraps; it is never truncated. The dish IS the item, and an
                        // elided one is a dish nobody can recognise.
                        .fixedSize(horizontal: false, vertical: true)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    score(dish)
                }
                .frame(minHeight: AteMetrics.hit)
            }
            if let onSave {
                bookmark(dish, action: onSave)
            }
        }
        .frame(minHeight: AteMetrics.hit)
    }

    /// Where a dish row goes. **The dish, when there is a dish page to go to** — the name and its
    /// score are the item, and the item has a page. Without one it falls back to opening the entry,
    /// which is what a slip did before those pages existed.
    @ViewBuilder
    private func dishTarget(
        _ dish: AteSlip.Dish,
        interactive: Bool,
        @ViewBuilder _ content: () -> some View
    ) -> some View {
        if let onDish {
            Button { onDish(dish) } label: {
                content()
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .contentShape(.rect)
            }
            .buttonStyle(.plain)
            .accessibilityElement(children: .combine)
            .accessibilityIdentifier("\(identifier).dish")
        } else {
            tappable(interactive: interactive, part: "dish") { content() }
        }
    }

    @ViewBuilder
    private func score(_ dish: AteSlip.Dish) -> some View {
        if let score = dish.score {
            HStack(spacing: 5) {
                AteIcon.starFilled.view(size: 16)
                Text(ScoreFormat.halfStep(score.value))
                    .ateText(.slipScore)
                    .monospacedDigit()
            }
            .accessibilityElement()
            .accessibilityLabel("Scored \(ScoreFormat.halfStep(score.value)) out of 5")
        } else {
            // Design rule 7: no number, no zero, and a full-strength outline — "not scored" is a
            // state, not a disabled control.
            UnscoredMark(side: 22)
                .foregroundStyle(AtePalette.paper.muted)
        }
    }

    private func bookmark(_ dish: AteSlip.Dish, action: @escaping (AteSlip.Dish) -> Void) -> some View {
        Button {
            action(dish)
        } label: {
            (dish.isSaved ? AteIcon.saved : AteIcon.save)
                .view(size: 22)
                .frame(width: AteMetrics.hit, height: AteMetrics.hit)
                .contentShape(.rect)
        }
        .buttonStyle(.plain)
        // `margin:-10px -12px -10px 0` — the target stays 44, the mark sits on the paper's edge.
        .padding(.vertical, -10)
        .padding(.trailing, -12)
        .accessibilityLabel(dish.isSaved ? "Saved \(dish.name)" : "Save \(dish.name)")
        .accessibilityAddTraits(dish.isSaved ? [.isButton, .isSelected] : .isButton)
        .accessibilityIdentifier("slip.save")
    }

    // MARK: - The place line

    private func placeLine(interactive: Bool) -> some View {
        HStack(spacing: AteMetrics.regular) {
            if let place = slip.place {
                placeTarget(place, interactive: interactive)
            }
            Spacer(minLength: 0)
            metaValue
        }
    }

    /// How far the place's target is grown past its glyphs, and given straight back to the layout.
    /// The line is 13pt type — a 17pt-tall target on a moving list is a miss — but growing the band
    /// would push every slip taller than the artboard draws it, so the air is padded on and the
    /// margin is padded off, exactly as a slip's bookmark does it.
    private static let placeTargetPadding: CGFloat = 9

    @ViewBuilder
    private func placeTarget(_ place: String, interactive: Bool) -> some View {
        let name = HStack(spacing: 5) {
            AteIcon.place.view(size: 15)
            Text(place).ateText(.slipPlaceName)
        }
        .foregroundStyle(AtePalette.paper.fg)

        if interactive, let onPlace, let placeID = slip.placeID {
            Button {
                onPlace(placeID)
            } label: {
                name
                    .padding(.vertical, Self.placeTargetPadding)
                    .contentShape(.rect)
            }
            .buttonStyle(.plain)
            .padding(.vertical, -Self.placeTargetPadding)
            .accessibilityElement(children: .combine)
            .accessibilityLabel(place)
            .accessibilityIdentifier("\(identifier).place")
        } else {
            name.accessibilityElement(children: .combine)
        }
    }

    @ViewBuilder
    private var metaValue: some View {
        switch slip.meta {
        case .time(let time, let isPublic):
            HStack(spacing: 10) {
                Text(time).ateText(.meta)
                (isPublic ? AteIcon.publicEntry : AteIcon.privateEntry)
                    .view(size: 15)
                    .accessibilityHidden(false)
                    .accessibilityLabel(isPublic ? "Public" : "Private")
            }
            .foregroundStyle(AtePalette.paper.muted)
        case .age(let age):
            Text(age)
                .ateText(.meta)
                .foregroundStyle(AtePalette.paper.muted)
        case .none:
            EmptyView()
        }
    }

    // MARK: - The byline

    private func bylineRow(_ byline: AteByline, interactive: Bool) -> some View {
        HStack(spacing: AteMetrics.regular) {
            Group {
                if interactive, let onProfile {
                    Button(action: onProfile) { bylineName(byline) }
                        .buttonStyle(.plain)
                        .accessibilityLabel("@\(byline.handle)")
                        .accessibilityIdentifier("slip.byline")
                } else {
                    bylineName(byline)
                }
            }
            Spacer(minLength: 0)
            Text(byline.age)
                .ateText(.meta)
                .foregroundStyle(AtePalette.paper.muted)
        }
    }

    private func bylineName(_ byline: AteByline) -> some View {
        HStack(spacing: AteMetrics.snug) {
            AteAvatar(userID: byline.userID, handle: byline.handle)
            Text(verbatim: "@\(byline.handle)")
                .ateText(.controlSmall)
        }
        .contentShape(.rect)
    }
}

/// A byline avatar: a letter on one of the six accents, picked deterministically from the person's
/// UUID — never from their position in a list, which would re-colour people as a feed loads.
struct AteAvatar: View {
    let userID: UUID
    let handle: String
    var side: CGFloat = AteMetrics.avatar
    /// The monogram's own size; the design draws 12 in a 28pt disc and 34 in a 76pt one.
    var textStyle: AteTextStyle = .avatarInitial

    var body: some View {
        Text(initials)
            .ateText(textStyle)
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

#if DEBUG
#Preview("Slips") {
    ScrollView {
        VStack(spacing: AteMetrics.slipGap) {
            EntrySlip(slip: .previewJournal, onOpen: {})
            EntrySlip(slip: .previewFeed, onOpen: {}, onProfile: {}, onSave: { _ in },
                      identifier: "feed.slip")
        }
        .padding(.horizontal, AteMetrics.gutter)
        .padding(.vertical, AteMetrics.section)
    }
    .ateGround()
}
#endif
