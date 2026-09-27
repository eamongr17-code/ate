import AteKit
import SwiftUI

/// **What the Feed is about** (round 5, Eamon: "by default it should be set to 'near me' and be
/// based on the user's location, not showing them anything outside a logical area … but they should
/// be able to set the location to other cities").
///
/// Two layouts are on the table (``JSExplore/feedLocation``):
/// - **A, chip** — "Feed" stays the title; the chip beside it says where: the Near me mark with
///   "Near me" and the city it resolved to, or a pin and the city; its sheet is radio rows;
/// - **B, title** — the city is the page's title with a chevron, and a small line over it says
///   "Near me" (or "Feed"); its sheet is a wrap of pills.
struct FeedLocationHeader: View {
    let model: FeedAreaModel?
    let onTap: () -> Void

    private let variant = JSExplore.feedLocation
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    var body: some View {
        switch variant {
        case .b: titleLayout
        default: chipLayout
        }
    }

    // MARK: - A

    private var chipLayout: some View {
        // At the accessibility sizes the chip goes under the title rather than breaking beside it.
        let stacks = dynamicTypeSize.isAccessibilitySize
        let layout = stacks
            ? AnyLayout(VStackLayout(alignment: .leading, spacing: AteMetrics.snug))
            : AnyLayout(HStackLayout())
        return layout {
            Text("Feed").ateTextLine(.screenTitle)
            if stacks == false { Spacer(minLength: AteMetrics.snug) }
            Button(action: onTap) {
                HStack(spacing: AteMetrics.snug - 2) {
                    (isNear ? AteIcon.navigation : AteIcon.place).view(size: isNear ? 14 : 16)
                    if isNear {
                        Text("Near me").ateText(.controlSmall)
                        Text(title)
                            .ateText(.controlSmall)
                            .foregroundStyle(AtePalette.automatic.muted)
                    } else {
                        Text(title).ateText(.controlSmall)
                    }
                }
                .lineLimit(1)
                .padding(.leading, 12)
                .padding(.trailing, 14)
                .atePillHeight(40)
                .background(AtePalette.automatic.chip, in: .capsule)
                .foregroundStyle(AtePalette.automatic.fg)
                .ateHitArea(AteHitOutset(height: 40))
            }
            .buttonStyle(.plain)
            .ateHitFootprint(AteHitOutset(height: 40))
            .disabled(model == nil)
            .accessibilityLabel("Location")
            .accessibilityValue(isNear ? "Near me, \(title)" : title)
            .accessibilityIdentifier("feed.area")
        }
    }

    // MARK: - B

    private var titleLayout: some View {
        Button(action: onTap) {
            VStack(alignment: .leading, spacing: 0) {
                HStack(spacing: AteMetrics.tight + 1) {
                    if isNear { AteIcon.navigation.view(size: 12) }
                    Text(isNear ? "Near me" : "Feed").ateText(.meta)
                }
                .foregroundStyle(AtePalette.automatic.muted)
                HStack(alignment: .center, spacing: AteMetrics.snug) {
                    Text(title)
                        .ateTextLine(.screenTitle)
                        .lineLimit(1)
                        .minimumScaleFactor(0.7)
                    AteIcon.chevron.view(size: 22)
                        .rotationEffect(.degrees(90))
                        .foregroundStyle(AtePalette.automatic.fg)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .disabled(model == nil)
        .accessibilityLabel("Location")
        .accessibilityValue(isNear ? "Near me, \(title)" : title)
        .accessibilityIdentifier("feed.area")
    }

    private var isNear: Bool { model?.isNearMe ?? false }
    private var title: String { model?.locationTitle ?? "Everywhere" }
}

/// **Where the Feed is about** — the sheet behind the control: Near me, Everywhere, then every city
/// with food, busiest first. The one city picker (``AteCityPicker``); a pick closes it.
struct FeedLocationSheet: View {
    let model: FeedAreaModel
    let onChoose: (FeedLocation) -> Void

    @Environment(\.dismiss) private var dismiss
    private let variant = JSExplore.feedLocation

    var body: some View {
        AteSheet(title: "Where?") {
            AteCityPicker(
                options: options,
                selection: selection,
                style: variant == .b ? .pills : .rows,
                title: nil
            ) { option in
                onChoose(Self.location(of: option))
                dismiss()
            }
            .padding(.bottom, AteMetrics.loose)
        }
        .task { await model.loadCities() }
    }

    private static let nearMeID = "@near-me"

    private var options: [AteCityOption] {
        let nearMe = AteCityOption(
            id: Self.nearMeID,
            title: "Near me",
            // The city it resolved to — only when the phone really is in it.
            subtitle: model.nearMe?.isNearby == true ? model.nearMe?.name : nil,
            icon: .navigation
        )
        var cities = model.cities
        // A remembered city that has since lost its food is still the reader's, and still ticked.
        if case .city(let slug) = model.location, cities.contains(where: { $0.city == slug }) == false {
            cities.append(AteCity(city: slug, name: model.locationTitle))
        }
        return [nearMe, .everywhere] + cities.map { AteCityOption(id: $0.city, title: $0.name, subtitle: $0.region) }
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
