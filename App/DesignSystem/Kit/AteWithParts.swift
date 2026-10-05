import SwiftUI

/// Somebody an entry was eaten with, as the kit draws them: their id (the avatar's colour) and
/// handle (its letter, and what is printed).
struct AteWithPerson: Identifiable, Equatable {
    let id: UUID
    let handle: String
}

/// **The With key's face** (`ate-with.html` 1a, 1d) — the composer's fourth key, the same 40pt round
/// key as the Diet leaf. Empty, the user-plus glyph; with one person, their avatar fills it; two
/// overlap; more than two, the count. It never grows past 40, so the capsule never widens.
struct AteWithKeyFace: View {
    let people: [AteWithPerson]

    var body: some View {
        Group {
            switch people.count {
            case 0:
                AteIcon.userPlus.view(size: AteWithKitMetrics.keyGlyph)
                    .foregroundStyle(AteColor.keyInk)
            case 1:
                avatar(people[0], side: AteWithKitMetrics.keyAvatar)
            case 2:
                ZStack {
                    avatar(people[0], side: AteWithKitMetrics.keyPairAvatar)
                        .offset(x: -AteWithKitMetrics.keyPairOffset)
                    avatar(people[1], side: AteWithKitMetrics.keyPairAvatar)
                        .padding(AteWithKitMetrics.ring)
                        .background(AteColor.keyFill, in: .circle)
                        .offset(x: AteWithKitMetrics.keyPairOffset)
                }
            default:
                // Silent in the artboard beyond "a count for more": the number of people, in ink.
                Text(verbatim: "\(people.count)")
                    .ateText(.avatarInitialKey)
                    .foregroundStyle(AteColor.keyFill)
                    .frame(width: AteWithKitMetrics.keyAvatar, height: AteWithKitMetrics.keyAvatar)
                    .background(AteColor.keyInk, in: .circle)
            }
        }
        .frame(width: AteMetrics.keyHeight, height: AteMetrics.keyHeight)
        .background(AteColor.keyFill, in: .circle)
        .contentShape(.circle)
    }

    private func avatar(_ person: AteWithPerson, side: CGFloat) -> some View {
        AteAvatar(userID: person.id, handle: person.handle, side: side, textStyle: .avatarInitialKey)
    }
}

/// **"with @jess"** — at the foot of the entry's paper, under the place line (`ate-with.html` 1f):
/// the byline avatar and the meta line, each handle opening that person's page. Never above the
/// dishes.
struct AteWithLine: View {
    let people: [AteWithPerson]
    let onPerson: (AteWithPerson) -> Void

    @Environment(\.atePalette) private var palette

    var body: some View {
        HStack(spacing: AteMetrics.snug) {
            avatars
            AteFlow(spacing: AteWithKitMetrics.wordSpace) {
                Text("with")
                    .ateText(.meta)
                    .foregroundStyle(palette.muted)
                ForEach(Array(people.enumerated()), id: \.element.id) { index, person in
                    Button { onPerson(person) } label: {
                        Text(verbatim: "@\(person.handle)" + (index < people.count - 1 ? "," : ""))
                            .ateText(.metaStrong)
                            .foregroundStyle(palette.fg)
                            .lineLimit(1)
                            .frame(minHeight: AteMetrics.avatar)
                            .ateHitArea(AteWithKitMetrics.handleHit)
                    }
                    .buttonStyle(.plain)
                    .ateHitFootprint(AteWithKitMetrics.handleHit)
                    .accessibilityLabel("@\(person.handle)")
                    .accessibilityIdentifier("entry.with.\(person.handle)")
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("entry.with")
    }

    /// The first person's byline avatar; a second overlaps it, ringed in the paper.
    private var avatars: some View {
        HStack(spacing: -AteWithKitMetrics.avatarOverlap) {
            ForEach(people.prefix(2)) { person in
                AteAvatar(userID: person.id, handle: person.handle, size: .byline)
                    .padding(AteWithKitMetrics.ring)
                    .background(AteColor.slip, in: .circle)
            }
        }
        .padding(-AteWithKitMetrics.ring)
    }
}

/// **One person in "Who were you with?"** (`ate-with.html` 1b): the review-size avatar, the handle
/// and their name under it, and an ink check once ticked. ``AtePersonRow``'s anatomy, plus the mark.
struct AtePersonPickRow: View {
    let person: AteWithPerson
    var name: String?
    let isSelected: Bool
    var isFirst = false
    let action: () -> Void

    @Environment(\.atePalette) private var palette

    var body: some View {
        Button(action: action) {
            HStack(spacing: AteDishRowMetrics.gap) {
                AteAvatar(userID: person.id, handle: person.handle, size: .review)
                VStack(alignment: .leading, spacing: AteDishRowMetrics.lineGap) {
                    Text(verbatim: "@\(person.handle)")
                        .ateText(.rowTitle)
                        .foregroundStyle(palette.fg)
                        .lineLimit(1)
                        .truncationMode(.tail)
                    if let name, name.isEmpty == false {
                        Text(name)
                            .ateText(.meta)
                            .foregroundStyle(palette.muted)
                            .lineLimit(1)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                if isSelected {
                    AteIcon.check.view(size: AteWithKitMetrics.checkGlyph)
                        .foregroundStyle(palette.inverted)
                        .frame(width: AteWithKitMetrics.check, height: AteWithKitMetrics.check)
                        .background(palette.solid, in: .circle)
                }
            }
            .frame(minHeight: AtePlaceRowMetrics.height)
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .frame(maxWidth: .infinity)
        .overlay(alignment: .top) {
            if isFirst == false { AteHairline() }
        }
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(isSelected ? [.isButton, .isSelected] : .isButton)
        .accessibilityIdentifier("with.person.\(person.handle)")
    }
}

enum AteWithKitMetrics {
    /// The key's glyph: `data-s="17"`.
    static let keyGlyph: CGFloat = 17
    /// One person fills the key: `.a30`.
    static let keyAvatar: CGFloat = 30
    /// Two people overlap inside the 40: two 24s, 8 apart from the centre, ringed in the key's fill.
    static let keyPairAvatar: CGFloat = 24
    static let keyPairOffset: CGFloat = 7
    /// The ring that parts two overlapping avatars (`box-shadow:0 0 0 3px` on the cluster, at this size 2).
    static let ring: CGFloat = 2
    /// Two byline avatars overlap by 10 on the entry's line.
    static let avatarOverlap: CGFloat = 10
    /// A handle is the byline's 28 tall; a finger gets 44.
    static let handleHit = AteHitOutset(height: AteMetrics.avatar)
    /// Under the place line: the artboard's `gap:10px` between its two rows, less what the place
    /// line's 44pt row already holds below its words (`padding-top:14px` above, 18 tall) — the
    /// "with" row starts 2 inside the place line's frame.
    static let underPlace: CGFloat = -2
    /// A word space at 13pt, between "with" and each handle.
    static let wordSpace: CGFloat = 3.5
    /// The pick row's check: `.chk{width:28px}`, its glyph 16.
    static let check: CGFloat = 28
    static let checkGlyph: CGFloat = 16
}
