import AteKit
import SwiftUI

/// **What the Feed is about** (round 5, Eamon: "by default it should be set to 'near me' and be
/// based on the user's location, not showing them anything outside a logical area … but they should
/// be able to set the location to other cities"; his pick: the chip).
///
/// "Feed" stays the title; the chip beside it says where — the Near me mark with "Near me" and the
/// city it resolved to, or a pin and the city (or Everywhere). It opens ``FeedLocationSheet``.
struct FeedLocationHeader: View {
    let model: FeedAreaModel?
    let onTap: () -> Void

    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    /// `height:42px` (round 8, `Main.dc.html`).
    static let chipHeight: CGFloat = 42

    var body: some View {
        // At the accessibility sizes the chip goes under the title rather than breaking beside it.
        // Beside it, the two share a bottom line (`align-items:flex-end`).
        let stacks = dynamicTypeSize.isAccessibilitySize
        let layout = stacks
            ? AnyLayout(VStackLayout(alignment: .leading, spacing: AteMetrics.snug))
            : AnyLayout(HStackLayout(alignment: .bottom, spacing: 10))
        return layout {
            Text("Feed").ateTextLine(.feedTitle)
            if stacks == false { Spacer(minLength: AteMetrics.snug) }
            FeedLocationChip(model: model, onTap: onTap)
        }
    }
}

/// The chip that says where the Feed is about — the big header's and the compact header's (round 6)
/// one control, the same button in both.
struct FeedLocationChip: View {
    let model: FeedAreaModel?
    let onTap: () -> Void

    var body: some View {
        let hit = AteHitOutset(height: FeedLocationHeader.chipHeight)
        return Button(action: onTap) {
            // `gap:7px; padding:0 15px`, the navigation mark at 15 and `stroke-width:2.2`.
            HStack(spacing: 7) {
                if isNear || isResolving {
                    AteIcon.navigation.view(size: 15, lineWidth: 2.2 * AteIconShape.opticalScale)
                } else {
                    AteIcon.place.view(size: 16)
                }
                if isNear {
                    Text("Near me").ateText(.feedControl)
                    // Two values side by side, never " · " (design rule 2).
                    Text(title)
                        .ateText(.feedControl)
                        .foregroundStyle(AtePalette.automatic.muted)
                } else {
                    Text(title).ateText(.feedControl)
                }
            }
            .lineLimit(1)
            .padding(.horizontal, 15)
            .atePillHeight(FeedLocationHeader.chipHeight)
            .background(AtePalette.automatic.raised, in: .capsule)
            .foregroundStyle(AtePalette.automatic.fg)
            .ateHitArea(hit)
        }
        .buttonStyle(.plain)
        .ateHitFootprint(hit)
        .disabled(model == nil)
        .accessibilityLabel("Location")
        .accessibilityValue(isNear ? "Near me, \(title)" : title)
        .accessibilityIdentifier("feed.area")
    }

    private var isNear: Bool { model?.isNearMe ?? false }
    private var isResolving: Bool { model?.isResolvingNearMe ?? false }
    private var title: String { model?.locationTitle ?? "Everywhere" }
}

/// **Where the Feed is about** — the sheet behind the chip: Near me, Everywhere, then every city with
/// food, busiest first, as the one city picker's pills (``AteCityPicker``, the filter sheet's own).
/// A pick closes it.
struct FeedLocationSheet: View {
    let model: FeedAreaModel
    let onChoose: (FeedLocation) -> Void

    @Environment(\.dismiss) private var dismiss

    var body: some View {
        AteSheet(title: "Where?", isLoading: model.hasLoadedCities == false) {
            AteCityPicker(
                options: options, selection: selection, title: nil, isLoading: model.hasLoadedCities == false
            ) { option in
                onChoose(Self.location(of: option))
                dismiss()
            }
            .padding(.bottom, AteMetrics.loose)
        }
    }

    private static let nearMeID = "@near-me"

    private var options: [AteCityOption] {
        let nearMe = AteCityOption(id: Self.nearMeID, title: "Near me", icon: .navigation)
        let slug: String? = if case .city(let slug) = model.location { slug } else { nil }
        return [nearMe] + AteCityOption.cities(model.cities, keeping: slug, named: model.locationTitle)
    }

    private var selection: String {
        switch model.location {
        case .nearMe: Self.nearMeID
        case .everywhere: AteCityOption.everywhereID
        case .city(let slug): slug
        }
    }

    private static func location(of option: AteCityOption) -> FeedLocation {
        switch option.id {
        case nearMeID: .nearMe
        case AteCityOption.everywhereID: .everywhere
        default: .city(option.id)
        }
    }
}
