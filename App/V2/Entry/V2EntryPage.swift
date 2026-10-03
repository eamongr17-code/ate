import AteKit
import SwiftUI

/// **One entry, yours or somebody else's.** A stub: today's placeholder, until its flow replaces this body. Keep the
/// type name and initialiser — ``V2Destinations`` builds it.
struct V2EntryPage: View {
    let entry: EntryRoute
    let context: V2PageContext

    init(_ entry: EntryRoute, context: V2PageContext) {
        self.entry = entry
        self.context = context
    }

    var body: some View {
        PagePlaceholder(title: "Tipo 00", subtitle: "Sat 19 Sep")
    }
}
