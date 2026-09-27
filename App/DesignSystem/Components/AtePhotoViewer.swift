import AteKit
import SwiftUI

// MARK: - Opening it

/// **Open a photo** — the one way anything in the app shows a photo large. Read it from the
/// environment and call it with the photos and the one that was tapped:
///
/// ```swift
/// @Environment(\.atePhotoViewer) private var showPhotos
/// PhotoCluster(photos: photos, onTap: { showPhotos(photos, at: $0) })
/// ```
///
/// The shell hosts it (``SwiftUICore/View/atePhotoViewerHost()``), so a slip in the journal, a card
/// in the feed, the entry page and the dish page all open the same preview, the same way.
struct AtePhotoViewerAction: Sendable {
    fileprivate var present: (@MainActor @Sendable ([AtePhoto], Int) -> Void)?

    @MainActor
    func callAsFunction(_ photos: [AtePhoto], at index: Int) {
        present?(photos, index)
    }
}

extension EnvironmentValues {
    @Entry var atePhotoViewer = AtePhotoViewerAction()
}

extension View {
    /// Hosts the photo preview for everything beneath this view: the photo floats over the page,
    /// which blurs behind it (``AtePhotoFloat``, round 5 — Eamon picked B).
    func atePhotoViewerHost() -> some View {
        modifier(AtePhotoViewerHost())
    }
}

/// What the preview is showing: every photo of one entry (or one dish), where it opened, and — when
/// a tile opened it — where each photo sits on the page, so it can grow out of it and shrink back.
private struct AtePhotoViewing: Identifiable {
    let id = UUID()
    let photos: [AtePhoto]
    let index: Int
    var origin: AtePhotoOrigin?
}

private struct AtePhotoViewerHost: ViewModifier {
    @State private var viewing: AtePhotoViewing?
    @State private var relay = AtePhotoOriginRelay()

    func body(content: Content) -> some View {
        let viewingBinding = $viewing
        let relay = relay
        content
            .environment(\.atePhotoOriginRelay, relay)
            .environment(\.atePhotoViewer, AtePhotoViewerAction { photos, index in
                guard photos.isEmpty == false else { return }
                AteTelemetry.record(BrowseEvents.photoPreviewOpened(photoCount: photos.count))
                viewingBinding.wrappedValue = AtePhotoViewing(
                    photos: photos,
                    index: min(max(0, index), photos.count - 1),
                    origin: relay.take()
                )
            })
            // Over the page, not a cover: the page stays where it is, blurred behind the photo.
            .overlay {
                if let viewing {
                    AtePhotoFloat(
                        photos: viewing.photos,
                        index: viewing.index,
                        origin: viewing.origin,
                        onClose: { viewingBinding.wrappedValue = nil }
                    )
                    .id(viewing.id)
                }
            }
    }
}
