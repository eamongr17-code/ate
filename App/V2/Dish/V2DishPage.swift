import AteKit
import SwiftUI

/// **One dish: its aggregate, and everything anybody has said about it.** A stub: today's placeholder, until its flow
/// replaces this body. Keep the type name and initialiser — ``V2Destinations`` builds it.
struct V2DishPage: View {
    let dishID: UUID
    let context: V2PageContext

    init(dishID: UUID, context: V2PageContext) {
        self.dishID = dishID
        self.context = context
    }

    var body: some View {
        PagePlaceholder(title: "Tagliatelle al ragù")
    }
}
