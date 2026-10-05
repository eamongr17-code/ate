import AteKit
import SwiftUI

/// **The Lists shelf** — your lists as colour cards under Journal | Lists.
struct ListsShelf: View {
    let app: AppModel
    let router: TabRouter<JournalStores>
    @Binding var isCollapsed: Bool
    @Binding var isNaming: Bool

    var body: some View {
        ScrollView { Color.clear }
            .ateRootCollapse($isCollapsed)
    }
}
