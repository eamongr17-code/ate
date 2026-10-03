import AteKit
import SwiftUI

/// **The Search tab's root.** A stub: today's placeholder, until the Search flow replaces this body. Keep the type name
/// and initialiser — ``TabShell`` builds it.
struct SearchRoot: View {
    let router: TabRouter<SearchStores>
    let app: AppModel

    init(router: TabRouter<SearchStores>, app: AppModel) {
        self.router = router
        self.app = app
    }

    var body: some View {
        SearchRootPlaceholder(router: router)
    }
}
