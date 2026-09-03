import SwiftUI

/// **The design language's three open questions**, built both ways and decided on device rather than
/// in argument (design-language §9). Every one of them is a *look* the team can't call from a diff:
/// a tile style judged on a 40-row diary, a feed density judged with a thumb, a receipt composition
/// judged at thumbnail size in a real message thread.
///
/// Both sides of each toggle are fully shipped code — there is no "sketch" branch. Release is
/// hard-wired to the default, so none of these switches can exist in a shipped app.
enum DesignDebugSettings {
    static let dishTileStyleKey = "debug.design.dishTileStyle"
    static let feedRowLayoutKey = "debug.design.feedRowLayout"
    static let receiptBandOrderKey = "debug.design.receiptBandOrder"

    static var dishTileStyle: DishTileStyle { current(dishTileStyleKey) }
    static var feedRowLayout: FeedRowLayout { current(feedRowLayoutKey) }
    static var receiptBandOrder: ReceiptBandOrder { current(receiptBandOrderKey) }

    /// Debug reads the stored choice; Release always answers the default, so a Release build has no
    /// path to variant B at all.
    private static func current<Variant: DesignVariant>(_ key: String) -> Variant {
        #if DEBUG
        UserDefaults.standard.string(forKey: key).flatMap(Variant.init(rawValue:)) ?? .designDefault
        #else
        .designDefault
        #endif
    }
}

/// A two-sided design question. Everything a variant needs to be pickable, stored and defaulted.
protocol DesignVariant: RawRepresentable<String>, CaseIterable, Identifiable, Hashable {
    static var designDefault: Self { get }
    static var question: String { get }
    var title: String { get }
}

extension DesignVariant {
    var id: String { rawValue }
}

/// §3's tile question: does an imageless dish read better as its own name, over-scaled and clipped,
/// or as two letters on a tonal step?
enum DishTileStyle: String, DesignVariant {
    case typographic
    case monogram

    static let designDefault = DishTileStyle.typographic
    static let question = "Dish tile"

    var title: String {
        switch self {
        case .typographic: "Tile: typographic"
        case .monogram: "Tile: monogram"
        }
    }
}

/// §9's density-vs-imagery tension: a full-width 4:3 photo under the review, or a 72pt leading tile
/// that fits about twice as many reviews on a screen.
enum FeedRowLayout: String, DesignVariant {
    case photoBelow
    case photoLeading

    static let designDefault = FeedRowLayout.photoBelow
    static let question = "Feed row"

    var title: String {
        switch self {
        case .photoBelow: "Feed: photo below"
        case .photoLeading: "Feed: photo leading"
        }
    }
}

/// §4's composition question, judged at thumbnail size in a thread: media first, or the statement
/// first with the media bleeding off the bottom.
enum ReceiptBandOrder: String, DesignVariant {
    case mediaLed
    case statementLed

    static let designDefault = ReceiptBandOrder.mediaLed
    static let question = "Receipt bands"

    var title: String {
        switch self {
        case .mediaLed: "Receipt: media-led"
        case .statementLed: "Receipt: statement-led"
        }
    }
}

/// The three pickers, as one section of the existing debug menu. Compiled out of Release entirely.
struct DesignDebugSettingsSection: View {
    var body: some View {
        #if DEBUG
        Section("Design") {
            DesignVariantPicker<DishTileStyle>(key: DesignDebugSettings.dishTileStyleKey)
            DesignVariantPicker<FeedRowLayout>(key: DesignDebugSettings.feedRowLayoutKey)
            DesignVariantPicker<ReceiptBandOrder>(key: DesignDebugSettings.receiptBandOrderKey)
        }
        #else
        EmptyView()
        #endif
    }
}

#if DEBUG
/// One question, as a `Picker` bound to its `@AppStorage` key — which is what makes every screen
/// holding the same key re-lay out the moment the choice changes, with no restart.
private struct DesignVariantPicker<Variant: DesignVariant>: View {
    @AppStorage private var raw: String

    init(key: String) {
        _raw = AppStorage(wrappedValue: Variant.designDefault.rawValue, key)
    }

    var body: some View {
        Picker(Variant.question, selection: $raw) {
            ForEach(Array(Variant.allCases)) { variant in
                Text(variant.title).tag(variant.rawValue)
            }
        }
    }
}
#endif
