import AteKit
import SwiftUI

/// **One bar of your own histogram, opened: the dishes you gave that score.** A stub: today's placeholder, until its
/// flow replaces this body. Keep the type name and initialiser — ``V2Destinations`` builds it.
struct V2RatingsPage: View {
    let score: Double
    let context: V2PageContext

    init(score: Double, context: V2PageContext) {
        self.score = score
        self.context = context
    }

    var body: some View {
        PagePlaceholder(title: "Your ratings")
    }
}
