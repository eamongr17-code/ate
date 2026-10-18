import AteKit
import SwiftUI

// **A list's cover and people** (`list-cover-edit.html`, approved 18 Oct) — the few parts the cover
// sheet, the list's byline and the Notifications page's invites draw.

/// **Upload from Photos** (screen 2, `.opt`) — a 40 field-coloured tile holding the image glyph, the
/// words, and the ink tick when the cover is an upload. 58 high.
struct AteCoverUploadRow: View {
    let title: String
    let isOn: Bool
    var identifier = "cover.upload"
    let action: () -> Void

    @Environment(\.atePalette) private var palette

    var body: some View {
        Button(action: action) {
            HStack(spacing: AteListPeopleMetrics.optionGap) {
                AteIcon.library.view(size: AteListPeopleMetrics.optionGlyph)
                    .foregroundStyle(palette.fg)
                    .frame(width: AteListPeopleMetrics.optionTile, height: AteListPeopleMetrics.optionTile)
                    .background(
                        palette.field,
                        in: .rect(cornerRadius: AteListPeopleMetrics.optionRadius, style: .continuous)
                    )
                Text(title)
                    .ateText(.rowTitle)
                    .foregroundStyle(palette.fg)
                    .frame(maxWidth: .infinity, alignment: .leading)
                AteTickMark(isOn: isOn)
            }
            .frame(minHeight: AteListPeopleMetrics.optionHeight)
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(isOn ? [.isButton, .isSelected] : .isButton)
        .accessibilityIdentifier(identifier)
    }
}

/// **One of the list's photos, to pick as its cover** (screen 2, `.cell-ph`) — square at 12, and when
/// picked an ink ring outside a white one, with the tick in its corner.
struct AteCoverPhotoCell: View {
    let url: String
    /// The dish, for VoiceOver.
    let name: String
    let isOn: Bool
    let action: () -> Void

    @Environment(\.atePalette) private var palette

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: AteListPeopleMetrics.cellRadius, style: .continuous)
        Button(action: action) {
            Color.clear
                .aspectRatio(1, contentMode: .fit)
                .overlay { AtePhotoContent(photo: .remote(url), size: .thumbnail) }
                .clipShape(shape)
                .overlay(alignment: .bottomTrailing) {
                    if isOn {
                        AteTickMark(isOn: true)
                            .overlay { Circle().strokeBorder(AteColor.overPhoto, lineWidth: AteListPeopleMetrics.ring) }
                            .padding(AteListPeopleMetrics.cellTickInset)
                    }
                }
                .padding(isOn ? AteListPeopleMetrics.ringGap : 0)
                .overlay {
                    if isOn {
                        RoundedRectangle(
                            cornerRadius: AteListPeopleMetrics.cellRadius + AteListPeopleMetrics.ringGap,
                            style: .continuous
                        )
                        .strokeBorder(palette.solid, lineWidth: AteListPeopleMetrics.pickRing)
                    }
                }
                .contentShape(shape)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(name)
        .accessibilityAddTraits(isOn ? [.isButton, .isSelected] : .isButton)
        .accessibilityIdentifier("cover.photo")
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
    /// `.opt{gap:12px; min-height:58px}`, `.opt .ic{width:40px; border-radius:10px}`, its glyph 22.
    static let optionGap: CGFloat = 12
    static let optionHeight: CGFloat = 58
    static let optionTile: CGFloat = 40
    static let optionRadius: CGFloat = 10
    static let optionGlyph: CGFloat = 22
    /// `.grid{repeat(3,1fr); gap:8px}`, `.cell-ph{border-radius:12px}`, its tick `right:6px; bottom:6px`.
    static let columns = 3
    static let cellGap: CGFloat = 8
    static let cellRadius: CGFloat = 12
    static let cellTickInset: CGFloat = 6
    /// `.cell-ph.on{box-shadow:0 0 0 3px #fff, 0 0 0 5.5px ink}`: a 3 gap, then 2.5 of ink.
    static let ringGap: CGFloat = 3
    static let pickRing: CGFloat = 2.5
    /// The white edge round a tick over a photo, and round each stacked avatar.
    static let ring: CGFloat = 2
    /// `.stack .av+.av{margin-left:-6px}`.
    static let stackOverlap: CGFloat = 6
    /// `.inv{gap:10px; padding:0 0 4px 48px}` — under the words, past the avatar.
    static let answerGap: CGFloat = 10
    static let answerBottom: CGFloat = 12
}
