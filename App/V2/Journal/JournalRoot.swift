import AteKit
import SwiftUI

/// **The Journal tab's root.** A stub: today's placeholder, until the Journal flow replaces this body. Keep the type
/// name and initialiser — ``TabShell`` builds it.
struct JournalRoot: View {
    let router: TabRouter<JournalStores>
    let app: AppModel

    init(router: TabRouter<JournalStores>, app: AppModel) {
        self.router = router
        self.app = app
    }

    var body: some View {
        JournalRootPlaceholder(router: router)
    }
}
