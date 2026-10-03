import AteKit
import SwiftUI

/// **Settings and the pages that hang off it.** A stub: today's placeholder, until its flow replaces this body. Keep
/// the type name and initialiser — ``V2Destinations`` builds it.
struct V2SettingsPage: View {
    let page: SettingsPage
    let context: V2PageContext

    init(page: SettingsPage, context: V2PageContext) {
        self.page = page
        self.context = context
    }

    var body: some View {
        SettingsPlaceholder(app: context.app)
    }
}
