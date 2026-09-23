import SwiftUI

/// **A photo, full screen.** Tapping one of an entry's photos opens this and nothing else happens:
/// black, the picture whole, swipe between them, one way out.
///
/// Deliberately the system's own shape rather than the app's — this is the one place in Ate that is
/// not paper. There is no chrome beyond the close button (design rule 1), no caption, no counter
/// beyond the page dots a multi-photo entry already earns, and no editing: the entry is where a photo
/// is managed, this is only where it is looked at.
struct AtePhotoViewer: View {
    let photos: [AtePhoto]
    /// Which one was tapped.
    @State var index: Int

    @Environment(\.dismiss) private var dismiss

    var body: some View {
        TabView(selection: $index) {
            ForEach(Array(photos.enumerated()), id: \.element.id) { position, photo in
                AtePhotoContent(photo: photo, contentMode: .fit)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .tag(position)
                    .accessibilityLabel("Photo \(position + 1) of \(photos.count)")
            }
        }
        .tabViewStyle(.page(indexDisplayMode: photos.count > 1 ? .always : .never))
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        // The black is the only thing that runs under the notch: the close button stays inside the
        // safe area, where a thumb expects it.
        .background(Color.black.ignoresSafeArea())
        .overlay(alignment: .topLeading) {
            AteIconButton(icon: .close, label: "Close", size: 24, tint: .white) { dismiss() }
                .padding(.leading, AteMetrics.snug)
        }
        .statusBarHidden()
        .accessibilityIdentifier("entry.photoViewer")
    }
}

#if DEBUG
#Preview("Photo viewer") {
    AtePhotoViewer(photos: AtePhoto.swatches, index: 1)
}
#endif
