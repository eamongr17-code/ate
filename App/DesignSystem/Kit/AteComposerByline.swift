import SwiftUI
import TipKit

/// **Where and who** — the composer's byline, under close and the tick (`compose-toolbar` direction
/// C, Eamon 2026-10-12). The place and the people are facts about the meal, not words in the review,
/// so they sit at the head of the sheet the way a receipt prints the venue, and the keys above the
/// keyboard keep only what goes into the words (Score, Diet) and the photos.
///
/// Empty, each is an outlined pill with its glyph and word. Held, it fills with the field and prints
/// what it holds: the place in full (wrapping to its own line before it truncates), the people as
/// their avatars and handles.
///
/// The third is **when** (13 Oct beta, design/rebuild/date-and-photos.html): "Today" outlined until
/// the day is another one — picked, or the photos' own — then filled with it ("Sun 11 Oct").
struct AteComposerByline: View {
    /// The place attached, if one is.
    let place: String?
    let people: [AteWithPerson]
    let onPlace: () -> Void
    let onPeople: () -> Void
    /// The day, as the pill prints it; `nil` is today. Shown only when there is `onDay` to open.
    var day: String?
    var onDay: (() -> Void)?
    /// A tip on the Place pill: a first entry's Place tip.
    var placeTip: (any Tip)?

    var body: some View {
        AteFlow(spacing: AteComposerBylineMetrics.gap) {
            pill(identifier: "composer.key.place", label: place.map { "Place: \($0)" } ?? "Place",
                 isHeld: place != nil, action: onPlace) {
                AteIcon.place.view(size: AteComposerBylineMetrics.glyph)
                Text(place ?? "Place")
                    .ateText(.controlSmall)
                    .lineLimit(1)
                    .truncationMode(.tail)
            }
            .popoverTip(placeTip, arrowEdge: .top)
            pill(identifier: "composer.key.with", label: peopleLabel,
                 isHeld: people.isEmpty == false, action: onPeople) {
                if people.isEmpty {
                    AteIcon.userPlus.view(size: AteComposerBylineMetrics.glyph)
                    Text("People").ateText(.controlSmall)
                } else {
                    Text("with").ateText(.controlSmall).opacity(AteComposerBylineMetrics.withOpacity)
                    avatars
                    Text(handles)
                        .ateText(.controlSmall)
                        .lineLimit(1)
                        .truncationMode(.tail)
                }
            }
            if let onDay {
                pill(identifier: "composer.key.date", label: "Date: \(day ?? "Today")",
                     isHeld: day != nil, action: onDay) {
                    AteIcon.calendar.view(size: AteComposerBylineMetrics.glyph)
                    Text(day ?? "Today")
                        .ateText(.controlSmall)
                        .lineLimit(1)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, AteMetrics.gutter)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("composer.byline")
    }

    private func pill<Face: View>(
        identifier: String,
        label: String,
        isHeld: Bool,
        action: @escaping () -> Void,
        @ViewBuilder face: () -> Face
    ) -> some View {
        Button(action: action) {
            HStack(spacing: AteComposerBylineMetrics.inner) { face() }
                .padding(.leading, AteComposerBylineMetrics.leading)
                .padding(.trailing, AteComposerBylineMetrics.trailing)
                .frame(height: AteComposerBylineMetrics.height)
                .foregroundStyle(isHeld ? AteColor.keyInk : AteColor.tagInk)
                .background(isHeld ? AteColor.keyFill : Color.clear, in: .capsule)
                .overlay {
                    if isHeld == false {
                        Capsule().strokeBorder(AteFeedColor.rule, lineWidth: AteComposerBylineMetrics.stroke)
                    }
                }
                .contentShape(.capsule)
                .ateHitArea(AteComposerBylineMetrics.hit)
        }
        .buttonStyle(.plain)
        .ateHitFootprint(AteComposerBylineMetrics.hit)
        .accessibilityLabel(label)
        .accessibilityIdentifier(identifier)
    }

    /// The first two avatars, the second ringed in the key's fill over the first.
    private var avatars: some View {
        HStack(spacing: -AteComposerBylineMetrics.avatarOverlap) {
            ForEach(people.prefix(2)) { person in
                AteAvatar(
                    userID: person.id,
                    handle: person.handle,
                    side: AteComposerBylineMetrics.avatar,
                    textStyle: .avatarInitialKey
                )
                .padding(AteComposerBylineMetrics.ring)
                .background(AteColor.keyFill, in: .circle)
            }
        }
        .padding(-AteComposerBylineMetrics.ring)
    }

    /// "@sam", "@sam, @jo", or "@sam +2".
    private var handles: String {
        let named = people.prefix(2).map { "@\($0.handle)" }
        if people.count > 2 { return "\(named[0]) +\(people.count - 1)" }
        return named.joined(separator: ", ")
    }

    private var peopleLabel: String {
        people.isEmpty ? "People" : "With: " + people.map { "@\($0.handle)" }.joined(separator: ", ")
    }
}

enum AteComposerBylineMetrics {
    /// A byline pill is 32 high, a finger gets 44.
    static let height: CGFloat = 32
    static let hit = AteHitOutset(height: height)
    static let gap: CGFloat = 8
    static let inner: CGFloat = 5
    static let leading: CGFloat = 9
    static let trailing: CGFloat = 12
    static let glyph: CGFloat = 15
    static let stroke: CGFloat = 1.25
    static let avatar: CGFloat = 20
    static let avatarOverlap: CGFloat = 7
    static let ring: CGFloat = 1.5
    static let withOpacity: Double = 0.7
}
