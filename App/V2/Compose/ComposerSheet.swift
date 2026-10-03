import AteKit
import SwiftUI

/// **The composer**, presented as a sheet by ``TabShell`` over whichever tab is up. A stub: today's
/// placeholder, until the Compose flow replaces this body. Keep the type name and initialiser.
/// `app.isComposing = false` closes it. `app.composing` says how it was opened (origin, photos, the
/// entry being edited); open it from anywhere with `app.compose(_:)`.
struct ComposerSheet: View {
    let app: AppModel

    init(app: AppModel) {
        self.app = app
    }

    var body: some View {
        ComposerSheetPlaceholder()
    }
}
