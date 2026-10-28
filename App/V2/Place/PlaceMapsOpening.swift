import AteKit
import SwiftUI
import UIKit

/// **Opening a place in Maps**, the one way every page does it (AGENTS.md rule 2): Apple Maps
/// straight away, or the which-app sheet when Google Maps is on the phone too. The place page's and
/// the dish page's map cards both open through here.
struct PlaceMapsOpening: ViewModifier {
    @Binding var choice: PlaceMapLink?
    /// `place` or `dish`: the page the card was on, for `place_map_opened`.
    let surface: String
    let analytics: AnalyticsRecorder

    @Environment(\.openURL) private var openURL

    func body(content: Content) -> some View {
        content
            .sheet(isPresented: Binding(get: { choice != nil }, set: { if $0 == false { choice = nil } })) {
                if let link = choice {
                    AteMapsSheet(title: link.name) { app in open(link, app: app) }
                }
            }
    }

    private func open(_ link: PlaceMapLink, app: AteMapsSheet.Choice) {
        analytics(DetailEvents.placeMapOpened(app: app.rawValue, hasPoint: link.coordinate != nil, surface: surface))
        openURL(app == .apple ? link.appleMapsURL : link.googleMapsURL)
    }
}

extension View {
    /// The sheet that asks which maps app, opened by ``PlaceMaps/show(_:choice:surface:analytics:openURL:)``.
    func placeMapsOpening(
        _ choice: Binding<PlaceMapLink?>, surface: String, analytics: @escaping AnalyticsRecorder
    ) -> some View {
        modifier(PlaceMapsOpening(choice: choice, surface: surface, analytics: analytics))
    }
}

enum PlaceMaps {
    /// A map was tapped: ask which app when Google Maps is on the phone, else open Apple Maps.
    @MainActor
    static func show(
        _ link: PlaceMapLink,
        choice: Binding<PlaceMapLink?>,
        surface: String,
        analytics: AnalyticsRecorder,
        openURL: OpenURLAction
    ) {
        AteHaptics.key()
        if UIApplication.shared.canOpenURL(PlaceMapLink.googleMapsProbe) {
            choice.wrappedValue = link
        } else {
            analytics(DetailEvents.placeMapOpened(app: AteMapsSheet.Choice.apple.rawValue,
                                                  hasPoint: link.coordinate != nil, surface: surface))
            openURL(link.appleMapsURL)
        }
    }
}
