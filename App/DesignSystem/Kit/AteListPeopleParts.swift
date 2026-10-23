import AteKit
import SwiftUI

// **A list's cover and people** (`list-cover-edit.html`, approved 18 Oct; the cover sheet redone as
// `list-cover-sheet.html` A, 23 Oct) — the few parts the cover sheet, the list's byline and the
// Notifications page's invites draw.

/// **One choice on the Change cover sheet** (`list-cover-sheet.html` A, approved 23 Oct) — the
/// Add dishes row with the radio mark: a 56 picture (the cover it would make, or the dish's photo),
/// the name over its meta line, and the mark at the end. A tap is the answer. While an upload goes
/// up, its row holds a spinner where the mark is. Ruled at the top by a hairline except the first.
struct AteCoverChoiceRow<Picture: View>: View {
    let title: String
    var subtitle: String?
    /// The dish rows name a dish (the heading voice); Automatic and the upload are controls.
    var titleStyle: AteTextStyle = .rowTitle
    let isOn: Bool
    var isBusy = false
    var isFirst = false
    var identifier: String?
    @ViewBuilder let picture: Picture
    let action: () -> Void

    @Environment(\.atePalette) private var palette

    var body: some View {
        Button(action: action) {
            HStack(spacing: AtePickRowMetrics.gap) {
                picture
                    .frame(width: AteListPeopleMetrics.picture, height: AteListPeopleMetrics.picture)
                VStack(alignment: .leading, spacing: AtePickRowMetrics.lineGap) {
                    Text(title)
                        .ateText(titleStyle)
                        .foregroundStyle(palette.fg)
                        .lineLimit(1)
                    if let subtitle {
                        Text(subtitle)
                            .ateText(.meta)
                            .foregroundStyle(palette.muted)
                            .lineLimit(1)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                if isBusy {
                    ProgressView()
                        .frame(width: AtePickRowMetrics.tick, height: AtePickRowMetrics.tick)
                } else {
                    AteRadioMark(isSelected: isOn)
                }
            }
            .frame(maxWidth: .infinity, minHeight: AtePickRowMetrics.height)
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .overlay(alignment: .top) {
            if isFirst == false { AteHairline() }
        }
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(isOn ? [.isButton, .isSelected] : .isButton)
        .accessibilityIdentifier(identifier ?? "cover.choice")
    }
}

/// **Everyone on a list, overlapped** (screens 6 and 9, `.stack`) — the byline's 28 avatars, each
/// ringed in the ground, 6 over the one before.
struct AteAvatarStack: View {
    let people: [ListPerson]

    @Environment(\.atePalette) private var palette

    var body: some View {
        HStack(spacing: -AteListPeopleMetrics.stackOverlap) {
            ForEach(people) { person in
                AteAvatar(
                    userID: person.id, handle: person.username,
                    url: person.avatarURL.flatMap(URL.init(string:))
                )
                .padding(AteListPeopleMetrics.ring)
                .background(palette.ground, in: .circle)
            }
        }
        .padding(-AteListPeopleMetrics.ring)
        .accessibilityHidden(true)
    }
}

/// **A list invite** (screen 7) — the notification row's anatomy without its X: the owner's 36
/// avatar, "@eamon invited you to Date night", the count under it; then Decline (quiet) and Accept
/// under the words. A tap on the row previews the list.
struct AteListInviteRow: View {
    let owner: ListPerson
    let line: String
    var meta: String?
    let decline: String
    let accept: String
    var isFirst = false
    let onOpen: () -> Void
    let onDecline: () -> Void
    let onAccept: () -> Void

    @Environment(\.atePalette) private var palette

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Button(action: onOpen) {
                HStack(spacing: AteNotificationRowMetrics.gap) {
                    AteAvatar(
                        userID: owner.id, handle: owner.username, size: .review,
                        url: owner.avatarURL.flatMap(URL.init(string:))
                    )
                    VStack(alignment: .leading, spacing: AteNotificationRowMetrics.lineGap) {
                        Text(line)
                            .ateText(.rowTitle)
                            .foregroundStyle(palette.fg)
                            .lineLimit(2)
                        if let meta {
                            Text(meta)
                                .ateText(.meta)
                                .foregroundStyle(palette.muted)
                                .lineLimit(1)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .frame(minHeight: AteNotificationRowMetrics.height)
                .contentShape(.rect)
            }
            .buttonStyle(.plain)
            .accessibilityElement(children: .combine)
            .accessibilityAddTraits(.isButton)
            .accessibilityIdentifier("invite.row")
            HStack(spacing: AteListPeopleMetrics.answerGap) {
                AteInkPill(title: decline, size: .row, isQuiet: true, identifier: "invite.decline", action: onDecline)
                AteInkPill(title: accept, size: .row, identifier: "invite.accept", action: onAccept)
            }
            .padding(.leading, AteNotificationRowMetrics.avatar + AteNotificationRowMetrics.gap)
            .padding(.bottom, AteListPeopleMetrics.answerBottom)
        }
        .padding(.horizontal, AteMetrics.gutter)
        .background(palette.ground)
        .overlay(alignment: .top) {
            if isFirst == false { AteHairline().padding(.horizontal, AteMetrics.gutter) }
        }
    }
}

enum AteListPeopleMetrics {
    /// A cover choice's picture: the dish row's 56 (``AteThumb/Size/row``).
    static let picture: CGFloat = 56
    /// The ground's edge round each stacked avatar.
    static let ring: CGFloat = 2
    /// `.stack .av+.av{margin-left:-6px}`.
    static let stackOverlap: CGFloat = 6
    /// `.inv{gap:10px; padding:0 0 4px 48px}` — under the words, past the avatar.
    static let answerGap: CGFloat = 10
    static let answerBottom: CGFloat = 12
}
