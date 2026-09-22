#if DEBUG || BETA
import SwiftUI

/// How the gallery is reached from inside the running app.
///
/// The menu item only *asks*; the root presents. A `fullScreenCover` hung off a toolbar menu is a
/// coin flip — the menu's content is not a reliable presentation context — so the request travels as
/// a notification and the cover lives on the app's root view, which is always in the hierarchy.
extension Notification.Name {
    static let ateShowDesignSystemGallery = Notification.Name("ate.debug.showDesignSystemGallery")
}

/// The row that opens the gallery, for the existing debug menu.
struct DesignSystemGalleryMenuItem: View {
    var body: some View {
        Button("Design system gallery") {
            NotificationCenter.default.post(name: .ateShowDesignSystemGallery, object: nil)
        }
    }
}

extension View {
    /// Applied once, at the root: listens for the request and puts the gallery over everything.
    func designSystemGalleryPresenter() -> some View {
        modifier(DesignSystemGalleryPresenter())
    }
}

private struct DesignSystemGalleryPresenter: ViewModifier {
    @State private var isPresented = false

    func body(content: Content) -> some View {
        content
            .onReceive(NotificationCenter.default.publisher(for: .ateShowDesignSystemGallery)) { _ in
                isPresented = true
            }
            .fullScreenCover(isPresented: $isPresented) {
                DesignSystemGallery()
                    .overlay(alignment: .topTrailing) {
                        Button {
                            isPresented = false
                        } label: {
                            Image(systemName: "xmark.circle.fill")
                                .font(.system(size: 28))
                                .symbolRenderingMode(.hierarchical)
                                .padding(AteMetrics.regular)
                        }
                        .accessibilityLabel("Close gallery")
                    }
            }
    }
}
#endif
