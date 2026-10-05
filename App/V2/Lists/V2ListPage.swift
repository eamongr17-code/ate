import AteKit
import SwiftUI

/// **One of your lists** — pushed from the shelf.
struct V2ListPage: View {
    let route: ListRoute
    let context: V2PageContext

    init(_ route: ListRoute, context: V2PageContext) {
        self.route = route
        self.context = context
    }

    var body: some View {
        Color.clear.ateGround()
    }
}
