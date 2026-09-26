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
    let icon: AteIcon
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
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            CappedWidth(maxWidth: value == nil ? .infinity : Self.valueMaxWidth) {
                HStack(spacing: 5) {
                    icon.view(size: iconSize)
                    Text(value ?? title)
                        .ateText(.controlSmall)
                        .lineLimit(1)
                        .truncationMode(.tail)
                }
                .padding(.leading, 9)
                .padding(.trailing, value == nil ? 13 : 14)
                .frame(height: AteMetrics.keyHeight)
            }
            // Inverted is ink in both modes: `ComposerStars` draws an ink pill with butter lettering,
            // and the surface's own `fg` is cream in dark — butter on cream cannot be read.
            .background(isActive ? AteColor.ink : background, in: .capsule)
            .foregroundStyle(isActive ? background : foreground)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(value.map { "\(title): \($0)" } ?? title)
        .accessibilityIdentifier(identifier ?? "composer.key.\(title.lowercased())")
    }

    /// `max-width:150px` on a key holding a value.
    private static let valueMaxWidth: CGFloat = 150
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

/// **Done** — the ink pill both composer screens carry in the same corner. One component, so the key
/// that saves the entry looks and behaves the same whether you were typing or talking.
struct ComposerDoneButton: View {
    /// "Done", or "Try again" after a save that did not land.
    var title = "Done"
    var isEnabled: Bool
    var isBusy = false
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Text(title)
                .ateText(.control)
                .padding(.horizontal, 18)
                .frame(height: 38)
                .background(AtePalette.surface.fg, in: .capsule)
                .foregroundStyle(AtePalette.surface.inverted)
        }
        .buttonStyle(.plain)
        .disabled(isEnabled == false || isBusy)
        .opacity(isEnabled ? 1 : 0.4)
        .padding(.trailing, AteMetrics.regular)
    }
}

/// **The composer's toolbar** (`Composer.dc.html`): camera · library · mic on the left, Score and
/// Place on the right — `padding:8px 14px 8px 8px; gap:6px; justify-content:space-between`. There is
/// no third group: every entry is public (Eamon, 2026-09-25), so the visibility key is gone.
struct ComposerToolbar: View {
    let model: ComposerModel
    @Binding var pickedItems: [PhotosPickerItem]
    let analytics: AnalyticsRecorder
    let onCamera: () -> Void
    let onDictate: () -> Void

    var body: some View {
        HStack(spacing: Self.gap) {
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
                AteIconButton(icon: .voice, label: "Dictate", tint: AtePalette.surface.fg, action: onDictate)
                    .accessibilityIdentifier("composer.key.dictate")
            }
            Spacer(minLength: 0)
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
                    model.dismissScoring(refocus: false)
                    model.isPickingPlace = true
                }
            }
        }
        .padding(.vertical, AteMetrics.snug)
        .padding(.leading, AteMetrics.snug)
        .padding(.trailing, Self.trailing)
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
