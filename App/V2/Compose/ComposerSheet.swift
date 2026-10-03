import AteKit
import SwiftUI

/// **The composer**, presented as a sheet by ``TabShell`` over whichever tab is up. A stub: today's
/// placeholder, until the Compose flow replaces this body. Keep the type name and initialiser.
/// `app.isComposing = false` closes it.
struct ComposerSheet: View {
    let app: AppModel

    init(app: AppModel) {
        self.app = app
    }

    var body: some View {
        ComposerSheetPlaceholder()
    }
}
