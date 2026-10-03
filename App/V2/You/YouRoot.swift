import AteKit
import SwiftUI

/// **The You tab's root.** A stub: today's placeholder, until the You flow replaces this body. Keep the type name and
/// initialiser — ``TabShell`` builds it.
struct YouRoot: View {
    let router: TabRouter<YouStores>
    let app: AppModel

    init(router: TabRouter<YouStores>, app: AppModel) {
        self.router = router
        self.app = app
    }

    var body: some View {
        YouRootPlaceholder(router: router)
    }
}
