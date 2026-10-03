import AteKit
import SwiftUI

/// **Every page the rebuilt app pushes**, behind one switch — declared once, in ``TabShell``. Each
/// case hands its route's payload and the ``V2PageContext`` to its flow's page; a flow builds the
/// page in its own folder and never edits this file.
struct V2Destinations: View {
    let route: Route
    let context: V2PageContext

    var body: some View {
        switch route {
        case .entry(let entry): V2EntryPage(entry, context: context)
        case .suggestions: V2SuggestionsPage(context: context)
        case .profile(let userID): V2ProfilePage(userID: userID, context: context)
        case .place(let placeID): V2PlacePage(placeID: placeID, context: context)
        case .dish(let dishID): V2DishPage(dishID: dishID, context: context)
        case .tag(let tag): V2TagPage(tag: tag, context: context)
        case .ratings(let score): V2RatingsPage(score: score, context: context)
        case .settings(let page): V2SettingsPage(page: page, context: context)
        // Monthly statements are not in V1 of the rebuild.
        case .statement: PagePlaceholder(title: "Statement")
        }
    }
}
