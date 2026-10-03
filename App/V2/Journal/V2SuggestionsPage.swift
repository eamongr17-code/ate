import AteKit
import SwiftUI
import UIKit

/// **From your photos** — the camera roll's recent meals, each sitting a row to write up: the day,
/// the time, the photos as a tilted cluster, and the ink pen that opens the composer holding them.
///
/// A row carries **photos and a time and nothing else**: no place is guessed from a photo's
/// location, and none is attached when the composer opens. The permission is asked here, when the
/// page opens, and nowhere else. Tap to enter, ✕ to dismiss, gone after — a dismissed sitting never
/// comes back, here or in the Journal's count (``PhotoSuggestionDismissals``).
struct V2SuggestionsPage: View {
    let context: V2PageContext

    init(context: V2PageContext) {
        self.context = context
    }

    private enum Phase: Equatable {
        case loading, ready, empty, denied
    }

    @State private var phase: Phase = .loading
    @State private var clusters: [PhotoSuggestionCluster] = []
    @State private var dismissals: PhotoSuggestionDismissals?
    @State private var hasAsked = false
    @Environment(\.openURL) private var openURL
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var library: any AtePhotoLibrary { context.services.photos }

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 0) {
                switch phase {
                case .loading:
                    ForEach(0..<SuggestionMetrics.skeletons, id: \.self) { index in
                        SuggestionSkeletonRow(photos: index == SuggestionMetrics.skeletons - 1 ? 1 : 2)
                    }
                case .ready:
                    ForEach(clusters) { cluster in
                        row(cluster)
                            .transition(.opacity)
                    }
                case .empty:
                    emptyBand(AteEmptyState(line: "Nothing\nto write up."))
                case .denied:
                    emptyBand(AteEmptyState(line: "Photos\nare off.", pill: ("Allow photos", { openSettings() })))
                        .accessibilityIdentifier("suggestions.denied")
                }
            }
            .padding(.horizontal, AteMetrics.gutter)
            .padding(.bottom, AteMetrics.section)
        }
        .scrollIndicators(.hidden)
        .scrollEdgeEffectStyle(.soft, for: .top)
        .accessibilityIdentifier("v2.page.suggestions")
        .ateGround()
        .ateInlineTitle("From your photos")
        .task { await load() }
        // Back from Settings with the permission given: read the roll without another tap.
        .onChange(of: scenePhase) { _, now in
            guard now == .active, phase == .denied, library.isAuthorized else { return }
            Task { await load() }
        }
    }

    private func emptyBand(_ state: AteEmptyState) -> some View {
        state.containerRelativeFrame(.vertical)
    }

    // MARK: - A row

    private func row(_ cluster: PhotoSuggestionCluster) -> some View {
        VStack(alignment: .leading, spacing: AteMetrics.snug) {
            HStack(spacing: AteMetrics.snug) {
                Text(PhotoSuggestions.title(for: cluster.date))
                    .ateText(.control)
                    .foregroundStyle(AtePalette.automatic.fg)
                    .frame(maxWidth: .infinity, alignment: .leading)
                Text(PhotoSuggestions.time(for: cluster.date))
                    .ateText(.meta)
                    .foregroundStyle(AtePalette.automatic.muted)
                dismissButton(cluster)
            }
            HStack(spacing: AteMetrics.snug) {
                SuggestionPhotos(library: library, ids: cluster.items.map(\.id))
                Spacer(minLength: 0)
                AteGlassDisc(icon: .edit, label: "Write up", role: .primary, identifier: "suggestions.write") {
                    write(cluster)
                }
            }
        }
        .padding(.vertical, AteMetrics.loose)
        .overlay(alignment: .top) { AteHairline() }
        .contentShape(.rect)
        // Tap to enter. The ✕ and the pen are real buttons inside the row, so they take their taps first.
        .onTapGesture { write(cluster) }
        .accessibilityElement(children: .contain)
        .accessibilityAction(named: "Write up") { write(cluster) }
        .accessibilityIdentifier("suggestions.row")
    }

    /// The row's ✕ — muted, at the corner, its 44 target hanging past the row's own lines.
    private func dismissButton(_ cluster: PhotoSuggestionCluster) -> some View {
        Button {
            dismissRow(cluster)
        } label: {
            AteIcon.close.view(size: SuggestionMetrics.dismissGlyph)
                .frame(width: AteMetrics.hit, height: AteMetrics.hit)
                .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .foregroundStyle(AtePalette.automatic.muted)
        .frame(width: SuggestionMetrics.dismissGlyph, height: SuggestionMetrics.dismissGlyph)
        .accessibilityLabel("Dismiss")
        .accessibilityIdentifier("suggestions.dismiss")
    }

    // MARK: - Doing things

    /// The pen: the composer, holding these photos and no place.
    private func write(_ cluster: PhotoSuggestionCluster) {
        guard context.gate.permitsWrite(.compose) else { return }
        AteHaptics.key()
        context.app.compose(ComposerPresentation(
            origin: .photoSuggestion,
            assetIdentifiers: cluster.items.map(\.id)
        ))
    }

    private func dismissRow(_ cluster: PhotoSuggestionCluster) {
        dismissals?.dismiss(cluster)
        context.services.analytics(SuggestionEvents.dismissed(photos: cluster.items.count))
        withAnimation(reduceMotion ? nil : .easeOut(duration: SuggestionMetrics.dismissDuration)) {
            clusters.removeAll { $0.id == cluster.id }
            if clusters.isEmpty { phase = .empty }
        }
    }

    private func openSettings() {
        context.services.analytics(SuggestionEvents.photoAccessSettingsOpened())
        guard let url = URL(string: UIApplication.openSettingsURLString) else { return }
        openURL(url)
    }

    // MARK: - Loading

    private func load() async {
        if dismissals == nil {
            dismissals = PhotoSuggestionDismissals(store: UserDefaultsStore(), owner: context.services.photoOwner)
        }
        if library.isAuthorized == false {
            // Asked once, here and nowhere else. A refusal — now or from an earlier launch — is
            // the denied state, with the one door out of it.
            guard hasAsked == false else {
                phase = .denied
                return
            }
            hasAsked = true
            guard await library.requestAuthorization() else {
                phase = .denied
                return
            }
        }
        if clusters.isEmpty { phase = .loading }
        // Each sitting appears as its photos are confirmed as food, newest first. Leaving the page
        // cancels this task, which stops the looking.
        for await food in library.recentProgressively() {
            clusters = dismissals?.clusters(food) ?? PhotoSuggestions.cluster(food)
            if clusters.isEmpty == false { phase = .ready }
        }
        guard Task.isCancelled == false else { return }
        phase = clusters.isEmpty ? .empty : .ready
    }
}

/// A sitting's photos: the slip's tilted, overlapping cluster — the same mess a written-up entry
/// wears, so the photos already look like the entry they are about to become. Three at most; the
/// rest are all in the composer when the row is tapped.
private struct SuggestionPhotos: View {
    let library: any AtePhotoLibrary
    let ids: [String]

    @State private var images: [String: Image] = [:]

    private var shown: [String] { Array(ids.prefix(SuggestionMetrics.maximumPhotos)) }

    var body: some View {
        AtePhotoCluster(
            photos: shown.enumerated().map { AtePhoto(id: SuggestionMetrics.photoID($0), image: images[$1]) },
            size: .composer,
            surface: AtePalette.automatic.ground
        )
        .task(id: shown) {
            for id in shown where images[id] == nil {
                images[id] = await library.thumbnail(id: id, side: AtePhotoClusterMetrics(.composer).side)
            }
        }
    }
}

/// A row before the roll has been read — its shape, never a spinner.
private struct SuggestionSkeletonRow: View {
    let photos: Int

    var body: some View {
        VStack(alignment: .leading, spacing: AteMetrics.snug) {
            HStack {
                AteSkeletonBar(width: SuggestionMetrics.titleBar, height: SuggestionMetrics.bar, palette: .automatic)
                Spacer(minLength: 0)
                AteSkeletonBar(width: SuggestionMetrics.timeBar, height: SuggestionMetrics.bar, palette: .automatic)
            }
            .frame(minHeight: AteMetrics.hit)
            AtePhotoCluster(
                photos: (0..<photos).map { AtePhoto(id: SuggestionMetrics.photoID($0)) },
                size: .composer,
                surface: AtePalette.automatic.ground
            )
        }
        .padding(.vertical, AteMetrics.loose)
        .overlay(alignment: .top) { AteHairline() }
        .ateBreathing()
        .accessibilityHidden(true)
    }
}

private enum SuggestionMetrics {
    static let skeletons = 3
    static let maximumPhotos = 3
    static let dismissGlyph: CGFloat = 16
    static let dismissDuration = 0.25
    static let titleBar: CGFloat = 112
    static let timeBar: CGFloat = 52
    static let bar: CGFloat = 14

    /// A tile's identity is its place in the row: a sitting's photos never reorder, so the tiles
    /// keep their place (and their tilt) as the images arrive.
    static func photoID(_ position: Int) -> UUID {
        UUID(uuidString: String(format: "00000000-0000-4000-8000-%012X", position)) ?? UUID()
    }
}
