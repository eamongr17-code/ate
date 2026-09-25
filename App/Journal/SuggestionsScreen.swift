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
                        SuggestionCluster(library: library, ids: cluster.items.map(\.id))
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

/// A suggestion's photos: the slip's tilted, overlapping cluster at 88pt (`padding:4px 0 4px 6px`,
/// `margin-left:-12px`, `rotate(-5/4/-2deg)`) — the same mess a written-up entry wears, so the photos
/// already look like the entry they are about to become.
///
/// Three at most, like a slip: a fourth would run into the pencil on a 390pt phone, and the rest are
/// all still in the composer when the row is tapped.
struct SuggestionCluster: View {
    let library: any AtePhotoLibrary
    let ids: [String]

    @State private var images: [String: Image] = [:]

    private static let side = AteMetrics.clusterPhotoSuggestion
    private static let maximumPhotos = 3

    private var shown: [String] { Array(ids.prefix(Self.maximumPhotos)) }

    var body: some View {
        PhotoCluster(
            photos: shown.enumerated().map { AtePhoto(id: Self.photoID($0), image: images[$1]) },
            side: Self.side,
            surface: AtePalette.automatic.ground,
            topPadding: AteMetrics.tight,
            bottomPadding: AteMetrics.tight
        )
        .task(id: shown) {
            for id in shown where images[id] == nil {
                images[id] = await library.thumbnail(id: id, side: Self.side)
            }
        }
    }

    /// A tile's identity is its position in the row: the row's assets never reorder, so the tiles
    /// keep their place (and their tilt) as the images arrive.
    private static func photoID(_ position: Int) -> UUID {
        UUID(uuidString: String(format: "00000000-0000-4000-8000-%012X", position)) ?? UUID()
    }
}
