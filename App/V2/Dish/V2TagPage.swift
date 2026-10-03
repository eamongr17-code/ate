import AteKit
import SwiftUI

/// **One tag's dishes.** A stub: today's placeholder, until its flow replaces this body. Keep the type name and
/// initialiser — ``V2Destinations`` builds it.
struct V2TagPage: View {
    let tag: DishTagRoute
    let context: V2PageContext

    init(tag: DishTagRoute, context: V2PageContext) {
        self.tag = tag
        self.context = context
    }

    var body: some View {
        PagePlaceholder(title: tag.label)
    }
}
