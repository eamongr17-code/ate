import AteKit
import SwiftUI

/// **A place: what to order there, and the visits written at it.** A stub: today's placeholder, until its flow replaces
/// this body. Keep the type name and initialiser — ``V2Destinations`` builds it.
struct V2PlacePage: View {
    let placeID: UUID
    let context: V2PageContext

    init(placeID: UUID, context: V2PageContext) {
        self.placeID = placeID
        self.context = context
    }

    var body: some View {
        PagePlaceholder(title: "Tipo 00")
    }
}
