import AteKit
import SwiftUI

/// §2.6's A/B, decided on device rather than in argument.
///
/// Both placements are fully built. Variant A puts the rating on the dish card (fewer screens, but
/// the gesture arrives with a card full of other affordances); Variant B gives the rating its own
/// focused step right after picking the dish (one thing on screen, but one more screen). Which one
/// hits the 30-second budget is an empirical question, so it ships as a toggle and
/// `log_rating_set(variant:)` answers it.
///
/// Debug-only: Release builds are hard-wired to A, so the switch cannot exist in a shipped app.
enum LogDebugSettings {
    static let ratingPlacementKey = "debug.log.ratingPlacement"

    static var ratingPlacement: RatingPlacementVariant {
        #if DEBUG
        UserDefaults.standard.string(forKey: ratingPlacementKey)
            .flatMap(RatingPlacementVariant.init(rawValue:)) ?? .inlineOnCard
        #else
        .inlineOnCard
        #endif
    }

    static func setRatingPlacement(_ variant: RatingPlacementVariant) {
        UserDefaults.standard.set(variant.rawValue, forKey: ratingPlacementKey)
    }
}

/// The switch itself, as a toolbar menu on the log sheet. Compiled out of Release entirely.
struct LogDebugMenu: View {
    @AppStorage(LogDebugSettings.ratingPlacementKey) private var raw = RatingPlacementVariant.inlineOnCard.rawValue

    var body: some View {
        #if DEBUG
        menu
        #else
        EmptyView()
        #endif
    }

    #if DEBUG
    private var menu: some View {
        Menu {
            Picker("Rating placement", selection: $raw) {
                ForEach(RatingPlacementVariant.allCases) { variant in
                    Text(variant.title).tag(variant.rawValue)
                }
            }
            // Repeated here, not duplicated: the same three `@AppStorage` keys the diary's menu
            // writes. The receipt's band order has to be flippable while a receipt is on screen,
            // and the log sheet covers the diary's toolbar.
            DesignDebugSettingsSection()
        } label: {
            Image(systemName: "ladybug")
        }
        .accessibilityLabel("Debug options")
    }
    #endif
}
