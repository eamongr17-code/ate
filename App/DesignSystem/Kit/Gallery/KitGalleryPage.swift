import SwiftUI

/// **The component kit's gallery, as Settings pushes it.** The gallery exists in Debug and Beta
/// builds only; this is where that is decided, so no screen under `App/V2/` carries the `#if`.
struct KitGalleryPage: View {
    var body: some View {
        #if DEBUG || BETA
        KitGalleryScreen()
        #else
        EmptyView()
        #endif
    }
}
