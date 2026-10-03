import AteKit
import SwiftUI

/// **Somebody else's page.** A stub: today's placeholder, until its flow replaces this body. Keep the type name and
/// initialiser — ``V2Destinations`` builds it.
struct V2ProfilePage: View {
    let userID: UUID
    let context: V2PageContext

    init(userID: UUID, context: V2PageContext) {
        self.userID = userID
        self.context = context
    }

    var body: some View {
        PagePlaceholder(title: "@jessw")
    }
}
