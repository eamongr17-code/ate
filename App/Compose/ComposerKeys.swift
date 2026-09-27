import AteKit
import PhotosUI
import SwiftUI

/// A composer toolbar key: **Score** (butter, an accent, so it carries ink) and **Place** (the field
/// colour, so it carries the surface's own foreground).
///
/// The foreground is a parameter for exactly that reason. Hard-wiring ink — which the spike did —
/// made the Place key near-invisible in dark mode: ink text on a plum pill.
struct ComposerKey: View {
    let title: String
    /// `nil` for a lettered pill with no icon — the diet row's codes.
    let icon: AteIcon?
    /// The artboards size the two keys' icons differently: the Score star is 15, the Place pin 16.
    var iconSize: CGFloat = 15
    let background: Color
    let foreground: Color
    /// Inverted, the way `ComposerStars` draws the Score key while its slider is open: the pill
    /// becomes ink and the lettering becomes the colour the pill used to be.
    var isActive = false
    /// What the key holds, printed in place of its title — the Place key's chosen place
    /// (`ComposerPlaceB`: "Tipo 00", `max-width:150px; padding:0 14px 0 9px`, truncating).
    var value: String?
    /// What the drive reaches for, fixed whatever the key is showing.
    var identifier: String?
    /// The icon alone, in a 40pt circle of the same fill — the Diet key.
    var iconOnly = false
    let action: () -> Void

    var body: some View {
        Button(action: action) { label.ateHitArea(hitOutset) }
            .buttonStyle(.plain)
            .ateHitFootprint(hitOutset)
            .accessibilityLabel(value.map { "\(title): \($0)" } ?? title)
            .accessibilityIdentifier(identifier ?? "composer.key.\(title.lowercased())")
    }

    /// The key's face.
    @ViewBuilder
    var label: some View {
        if iconOnly, let icon {
            icon.view(size: iconSize)
                .frame(width: AteMetrics.keyHeight, height: AteMetrics.keyHeight)
                .background(isActive ? AteColor.ink : background, in: .circle)
                .foregroundStyle(isActive ? background : foreground)
                .contentShape(.circle)
        } else {
            CappedWidth(maxWidth: value == nil ? .infinity : Self.valueMaxWidth) {
                HStack(spacing: 5) {
                    icon?.view(size: iconSize)
                    Text(value ?? title)
                        .ateText(.controlSmall)
                        .lineLimit(1)
                        .truncationMode(.tail)
                }
                // A lettered pill is balanced: the key's trailing inset on both sides.
                .padding(.leading, icon == nil ? 13 : 9)
                .padding(.trailing, value == nil ? 13 : 14)
                .atePillHeight(AteMetrics.keyHeight)
            }
            // Inverted is ink in both modes: `ComposerStars` draws an ink pill with butter lettering,
            // and the surface's own `fg` is cream in dark — butter on cream cannot be read.
            .background(isActive ? AteColor.ink : background, in: .capsule)
            .foregroundStyle(isActive ? background : foreground)
            .contentShape(.capsule)
        }
    }

    /// `max-width:150px` on a key holding a value.
    private static let valueMaxWidth: CGFloat = 150

    /// A 40 key reaches 44 to a finger; the icon-only Diet key is 40 across as well.
    var hitOutset: AteHitOutset { iconOnly ? .keyDisc : .key }
}

/// CSS `max-width` as SwiftUI does not have it: shrink-to-fit up to a cap, truncating past it. A
/// `.frame(maxWidth:)` is greedy — it would stretch a short "Tipo 00" pill out to 150.
private struct CappedWidth: Layout {
    let maxWidth: CGFloat

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let width = min(proposal.width ?? .infinity, maxWidth)
        return subviews.first?.sizeThatFits(ProposedViewSize(width: width, height: proposal.height)) ?? .zero
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        subviews.first?.place(
            at: bounds.origin,
            proposal: ProposedViewSize(width: bounds.width, height: bounds.height)
        )
    }
}

/// **Post** — the ink pill both composer screens carry in the same corner. One component, so the key
/// that saves the entry looks and behaves the same whether you were typing or talking.
///
/// Round 5: "Post" for a new entry, and "Posting…" while the sorter works behind it — the pill holds
/// the word, full strength, until the Summary takes the screen (``PostHold``). An edit keeps "Done":
/// the entry is already posted.
struct ComposerPostButton: View {
    /// "Post", "Posting…" while it holds, "Done" on an edit, or "Try again" after a save that did not land.
    var title = "Post"
    var isEnabled: Bool
    var isBusy = false
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Text(title)
                .ateText(.control)
                .padding(.horizontal, 18)
                .atePillHeight(Self.height)
                .background(AtePalette.surface.fg, in: .capsule)
                .foregroundStyle(AtePalette.surface.inverted)
                .ateHitArea(Self.hitOutset)
        }
        .buttonStyle(.plain)
        .ateHitFootprint(Self.hitOutset)
        // Busy is not off: "Posting…" holds at full strength, it just takes no second tap.
        .disabled(isEnabled == false)
        .allowsHitTesting(isBusy == false)
        .opacity(isEnabled ? 1 : 0.4)
        .padding(.trailing, AteMetrics.regular)
    }

    /// The pill is drawn 38 tall; a finger gets 44.
    private static let height: CGFloat = 38
    private static let hitOutset = AteHitOutset(height: height)
}

/// **The composer's toolbar** (`Composer.dc.html`): camera · library on the left, Score, Place and
/// Diet on the right — `padding:8px 14px 8px 8px; gap:6px; justify-content:space-between`. There is
/// no third group: every entry is public (Eamon, 2026-09-25), so the visibility key is gone.
///
/// **No mic key** (round 4): voice mode is parked (``VoiceParking``). The keyboard's own dictation is
/// the voice path, and a score said through it becomes a pill like a typed one (``ScorePhrase``).
///
/// **The Diet key swaps the toolbar** for a row of the five codes behind a back arrow (round 4 —
/// the system menu is gone): a code goes in after the nearest dish to its left, and the ordinary
/// toolbar comes straight back.
struct ComposerToolbar: View {
    let model: ComposerModel
    @Binding var pickedItems: [PhotosPickerItem]
    let analytics: AnalyticsRecorder
    let onCamera: () -> Void

    @State private var isChoosingDiet = false
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    var body: some View {
        Group {
            if isChoosingDiet {
                dietRow
                    .transition(.opacity)
            } else {
                keys
                    .transition(.opacity)
            }
        }
        .ateAnimation(.easeInOut(duration: 0.15), value: isChoosingDiet)
        .padding(.vertical, AteMetrics.snug)
        .padding(.leading, AteMetrics.snug)
        .padding(.trailing, Self.trailing)
    }

    private var keys: some View {
        // At the accessibility sizes the keys' lettering needs the whole width — side by side with
        // the media keys, "Score" truncated to "Sco…" and the place to nothing. The keys take a
        // line of their own under the media keys instead.
        let stacks = dynamicTypeSize.isAccessibilitySize
        let layout = stacks
            ? AnyLayout(VStackLayout(alignment: .leading, spacing: Self.gap))
            : AnyLayout(HStackLayout(spacing: Self.gap))
        return layout {
            HStack(spacing: 0) {
                AteIconButton(icon: .camera, label: "Camera", tint: AtePalette.surface.fg) {
                    // The camera takes the keyboard's place: close the slider without raising it.
                    model.dismissScoring(refocus: false)
                    onCamera()
                }
                PhotosPicker(
                    selection: $pickedItems,
                    // Picks append to what is staged, so the picker offers only what is left.
                    maxSelectionCount: max(1, EntryDraft.photoLimit - model.photos.count),
                    selectionBehavior: .ordered,
                    matching: .images,
                    // `.current`: the picker hands back the original as it is (no transcode), which
                    // is most of the wait between a pick and the photo in the cluster.
                    preferredItemEncoding: .current,
                    photoLibrary: .shared()
                ) {
                    AteIcon.library.view(size: 22)
                        .frame(width: AteMetrics.hit, height: AteMetrics.hit)
                        .contentShape(.rect)
                }
                .foregroundStyle(AtePalette.surface.fg)
                .disabled(model.canAddPhotos == false)
                .simultaneousGesture(TapGesture().onEnded { model.dismissScoring(refocus: false) })
                .accessibilityLabel("Photo library")
            }
            .fixedSize()
            // No spacer: its two extra gaps were the Place key's last 12 points. The keys push
            // right on their own, as `justify-content:space-between` does.
            HStack(spacing: Self.gap) {
                ComposerKey(
                    title: "Score",
                    icon: .starFilled,
                    background: AteColor.butter,
                    foreground: AteColor.ink,
                    // `ComposerStars`: while the slider is open the Score key inverts — ink pill,
                    // butter lettering. The Place key never does.
                    isActive: model.scoring != nil
                ) {
                    AteHaptics.key()
                    // The key is inverted while the panel is up, and pressing it again puts it away.
                    if model.scoring != nil {
                        model.dismissScoring()
                    } else {
                        analytics(model.insertScore())
                    }
                }
                // `ComposerPlaceB`: the key holds the place — its name, truncating at 150 — and opens
                // the place sheet. The words never carry it.
                ComposerKey(
                    title: "Place",
                    icon: .place,
                    iconSize: 16,
                    background: ComposerKeyColor.place,
                    foreground: AteColor.ink,
                    value: model.place.flatMap { $0.name.isEmpty ? nil : $0.name },
                    identifier: "composer.key.place"
                ) {
                    AteHaptics.key()
                    model.dismissScoring(refocus: false)
                    model.isPickingPlace = true
                }
                // The place gives way first: Score and Diet keep their size, the name truncates.
                .layoutPriority(-1)
                ComposerKey(
                    title: "Diet",
                    icon: .diet,
                    iconSize: 16,
                    background: ComposerKeyColor.place,
                    foreground: AteColor.ink,
                    iconOnly: true
                ) {
                    AteHaptics.key()
                    model.dismissScoring(refocus: false)
                    isChoosingDiet = true
                }
                .fixedSize()
            }
            .frame(maxWidth: .infinity, alignment: .trailing)
        }
    }

    /// The five codes, each the same linen pill as the Place key, behind a back arrow.
    private var dietRow: some View {
        HStack(spacing: Self.gap) {
            AteIconButton(icon: .back, label: "Back", tint: AtePalette.surface.fg) {
                isChoosingDiet = false
            }
            .accessibilityIdentifier("composer.diet.back")
            ForEach(DietTag.allCases, id: \.self) { tag in
                ComposerKey(
                    title: tag.label,
                    icon: nil,
                    background: ComposerKeyColor.place,
                    foreground: AteColor.ink,
                    identifier: "composer.diet.\(tag.rawValue)"
                ) {
                    pick(tag)
                }
                .accessibilityLabel(tag.spokenName)
                .fixedSize()
            }
            Spacer(minLength: 0)
        }
    }

    /// A chip belongs to the dish on its left; with none there, nothing goes in and the pill says so
    /// under the finger; the ordinary toolbar comes back either way. Either way nothing is written about it.
    private func pick(_ tag: DietTag) {
        model.dismissScoring(refocus: false)
        isChoosingDiet = false
        guard let added = model.insertTag(tag) else {
            AteHaptics.refused()
            return
        }
        AteHaptics.key()
        analytics(added)
    }

    /// `gap:6px`, between the groups and between the two keys.
    private static let gap: CGFloat = 6
    /// `padding-right:14px` — the keys sit in from the edge, where the visibility key used to be.
    private static let trailing: CGFloat = 14
}

/// The composer keys' fills. The Score key is butter in both modes; the Place key is the linen
/// field it is drawn in (`Composer.dc.html`: `--field:#E4DED4`), **also in both modes** — in dark,
/// the surface's own field (ink `#17111B` on the plum surface) read as a hole in the toolbar
/// (Eamon, round 3). Like the Score key it carries ink either way.
enum ComposerKeyColor {
    static let place = AteColor.linenField
}
