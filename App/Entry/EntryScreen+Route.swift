import AteKit
import SwiftUI

extension EntryScreen {
    /// The entry page, as the shell pushes it.
    init(route: EntryRoute, context: RouteContext) {
        self.init(
            route: route,
            services: context.services,
            saves: context.saves,
            onChange: context.entryChanged,
            onEdit: { context.compose(.edit($0)) },
            onProfile: { context.open(.profile($0)) },
            onPlace: { context.open(.place($0), from: .entry) },
            onDish: { context.open(.dish($0), from: .entry) },
            // The person is gone from every read the server serves; the lists on this device
            // catch up now rather than on the next launch.
            onBlocked: { context.blocked(nil) }
        )
    }
}
