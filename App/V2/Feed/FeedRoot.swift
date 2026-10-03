import AteKit
import SwiftUI

/// **The Feed tab's root.** A stub: today's placeholder, until the Feed flow replaces this body. Keep the type name and
/// initialiser — ``TabShell`` builds it.
struct FeedRoot: View {
    let router: TabRouter<V2FeedStores>
    let app: AppModel

    init(router: TabRouter<V2FeedStores>, app: AppModel) {
        self.router = router
        self.app = app
    }

    var body: some View {
        FeedRootPlaceholder(router: router)
    }
}
