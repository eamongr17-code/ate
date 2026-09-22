import AteKit
import SwiftUI

/// **`Suggestions`** — "From your photos". The camera roll's recent sittings, each one a row you can
/// write up: the day, the time, the photos, and a pencil.
///
/// Design rule 8 survives intact. A row carries **photos and a time and nothing else** — no place is
/// guessed from a photo's location, and none is attached when the composer opens. The permission is
/// asked for here, when the screen opens, and nowhere else.
struct SuggestionsScreen: View {
    let library: any AtePhotoLibrary
    let onWrite: (PhotoSuggestionCluster) -> Void

    @State private var clusters: [PhotoSuggestionCluster] = []
    @State private var hasAsked = false
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                ForEach(clusters) { cluster in
                    row(cluster)
                }
            }
            .padding(.horizontal, AteMetrics.gutter)
            .padding(.top, AteMetrics.snug)
            .padding(.bottom, AteMetrics.tabBarScrollInset)
        }
        .scrollIndicators(.hidden)
        .safeAreaInset(edge: .top, spacing: 0) { topBar }
        .task { await load() }
    }

    private var topBar: some View {
        HStack(spacing: 2) {
            AteIconButton(icon: .back, label: "Back", size: 24) { dismiss() }
            Text("From your photos")
                .ateText(.pageTitle)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.horizontal, AteMetrics.regular)
        .ateContentTop()
        .background(AtePalette.automatic.ground)
    }

    private func row(_ cluster: PhotoSuggestionCluster) -> some View {
        Button {
            onWrite(cluster)
        } label: {
            VStack(alignment: .leading, spacing: 0) {
                AteHairline()
                VStack(alignment: .leading, spacing: 10) {
                    HStack(spacing: AteMetrics.snug) {
                        Text(PhotoSuggestions.title(for: cluster.date))
                            .ateText(.control)
                            .frame(maxWidth: .infinity, alignment: .leading)
                        Text(PhotoSuggestions.time(for: cluster.date))
                            .ateText(.meta)
                            .foregroundStyle(AtePalette.automatic.muted)
                    }
                    HStack(spacing: AteMetrics.snug) {
                        ForEach(cluster.items) { item in
                            SuggestionThumbnail(library: library, id: item.id)
                        }
                        Spacer(minLength: 0)
                        AteIcon.edit.view(size: 18)
                            .frame(width: AteMetrics.hit, height: AteMetrics.hit)
                            .background(AtePalette.automatic.fg, in: .circle)
                            .foregroundStyle(AtePalette.automatic.inverted)
                    }
                }
                .padding(.vertical, AteMetrics.loose)
            }
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("suggestions.row")
    }

    private func load() async {
        if library.isAuthorized == false, hasAsked == false {
            hasAsked = true
            _ = await library.requestAuthorization()
        }
        clusters = PhotoSuggestions.cluster(await library.recent())
    }
}

/// A suggestion's photo: 74pt, straight, 16pt corners, no ring — design rule 6, nothing in a list
/// tilts.
struct SuggestionThumbnail: View {
    let library: any AtePhotoLibrary
    let id: String

    @State private var image: Image?

    private static let side: CGFloat = 74

    var body: some View {
        AteThumbnail(photo: AtePhoto(image: image), side: Self.side)
            .task {
                image = await library.thumbnail(id: id, side: Self.side)
            }
    }
}
