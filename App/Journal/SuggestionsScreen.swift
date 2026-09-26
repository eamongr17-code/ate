import AteKit
import SwiftUI
import UIKit

/// **`Suggestions`** — "From your photos". The camera roll's recent sittings, each one a row you can
/// write up: the day, the time, the photos, and a pencil.
///
/// Design rule 8 survives intact. A row carries **photos and a time and nothing else** — no place is
/// guessed from a photo's location, and none is attached when the composer opens. The permission is
/// asked for here, when the screen opens, and nowhere else.
///
/// Eamon's rule for a row like this: **tap to enter, X to dismiss, gone after.** The X sits at the
/// row's top-right corner, and a dismissed sitting's photos never come back — not on this screen,
/// not after a relaunch, and not in the journal header's count (``PhotoSuggestionDismissals``).
///
/// Four states, none of them with a line of explanation (design rule 1): the rows' skeleton while
/// the roll is read, the rows, one line when there is nothing to write up, and one line with an
/// "Allow photos" pill when the permission was refused.
struct SuggestionsScreen: View {
    let library: any AtePhotoLibrary
    /// Whose dismissals these are.
    var owner: UUID?
    var analytics: AnalyticsRecorder = { _ in }
    let onWrite: (PhotoSuggestionCluster) -> Void
    /// A row was dismissed — the journal header's badge counts again.
    var onDismissed: () -> Void = {}

    private enum Phase: Equatable {
        case loading
        case ready
        case empty
        case denied
    }

    @State private var phase: Phase = .loading
    @State private var clusters: [PhotoSuggestionCluster] = []
    @State private var dismissals: PhotoSuggestionDismissals?
    @State private var hasAsked = false
    @Environment(\.dismiss) private var dismiss
    @Environment(\.openURL) private var openURL
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                switch phase {
                case .loading:
                    SuggestionsSkeleton()
                case .ready:
                    ForEach(clusters) { cluster in
                        row(cluster)
                            .transition(.opacity)
                    }
                case .empty:
                    centred(AteEmptyState(title: "Nothing to\nwrite up."))
                case .denied:
                    centred(AteEmptyState(title: "Photos\nare off.", actionTitle: "Allow photos") {
                        analytics(SuggestionEvents.photoAccessSettingsOpened())
                        guard let url = URL(string: UIApplication.openSettingsURLString) else { return }
                        openURL(url)
                    })
                    .accessibilityIdentifier("suggestions.denied")
                }
            }
            .padding(.horizontal, AteMetrics.gutter)
            .padding(.top, AteMetrics.snug)
            .padding(.bottom, AteMetrics.tabBarScrollInset)
        }
        .scrollIndicators(.hidden)
        .safeAreaInset(edge: .top, spacing: 0) { topBar }
        .task { await load() }
        // Back from Settings with the permission given: read the roll without another tap.
        .onChange(of: scenePhase) { _, now in
            guard now == .active, phase == .denied, library.isAuthorized else { return }
            Task { await load() }
        }
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

    /// The one rule for a state with nothing under it (``AteEmptyPlacement``): centred on the same
    /// screen line as every other empty state.
    private func centred(_ state: some View) -> some View {
        state.ateEmptyPlacement(top: SuggestionsScreen.headerBottom)
    }

    /// Where the list begins on the page: the 60 content top, the 44 back arrow, the list's 8.
    private static let headerBottom: CGFloat = AteMetrics.contentTop + AteMetrics.hit + AteMetrics.snug

    // MARK: - A row

    private func row(_ cluster: PhotoSuggestionCluster) -> some View {
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
                    dismissButton(cluster)
                }
                HStack(spacing: AteMetrics.snug) {
                    SuggestionCluster(library: library, ids: cluster.items.map(\.id))
                    Spacer(minLength: 0)
                    AteIcon.edit.view(size: 18)
                        .frame(width: AteMetrics.hit, height: AteMetrics.hit)
                        .background(AtePalette.automatic.fg, in: .circle)
                        .foregroundStyle(AtePalette.automatic.inverted)
                        .accessibilityHidden(true)
                }
            }
            .padding(.vertical, AteMetrics.loose)
        }
        .contentShape(.rect)
        // Tap to enter. The X is a real button inside the row, so it takes its own taps first.
        .onTapGesture { onWrite(cluster) }
        .accessibilityElement(children: .contain)
        .accessibilityAction(named: "Write up") { onWrite(cluster) }
        .accessibilityIdentifier("suggestions.row")
    }

    /// The row's X — muted, at the corner, the size of the time beside it. Its 44pt hit area hangs
    /// past the row's own lines so the title row keeps the artboard's height.
    private func dismissButton(_ cluster: PhotoSuggestionCluster) -> some View {
        Button {
            dismissRow(cluster)
        } label: {
            AteIcon.close.view(size: SuggestionsScreen.dismissGlyph)
                .frame(width: AteMetrics.hit, height: AteMetrics.hit)
                .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .foregroundStyle(AtePalette.automatic.muted)
        .frame(width: SuggestionsScreen.dismissGlyph, height: SuggestionsScreen.dismissGlyph)
        .accessibilityLabel("Dismiss")
        .accessibilityIdentifier("suggestions.dismiss")
    }

    private static let dismissGlyph: CGFloat = 16

    private func dismissRow(_ cluster: PhotoSuggestionCluster) {
        dismissals?.dismiss(cluster)
        analytics(SuggestionEvents.dismissed(photos: cluster.items.count))
        withAnimation(reduceMotion ? nil : .easeOut(duration: 0.25)) {
            clusters.removeAll { $0.id == cluster.id }
            if clusters.isEmpty { phase = .empty }
        }
        onDismissed()
    }

    // MARK: - Loading

    private func load() async {
        if dismissals == nil {
            dismissals = PhotoSuggestionDismissals(store: UserDefaultsStore(), owner: owner)
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
        // Each sitting appears as its photos are confirmed as food, newest first. Leaving the screen
        // cancels this task, which stops the looking.
        for await food in library.recentProgressively() {
            clusters = dismissals?.clusters(food) ?? PhotoSuggestions.cluster(food)
            if clusters.isEmpty == false { phase = .ready }
        }
        guard Task.isCancelled == false else { return }
        phase = clusters.isEmpty ? .empty : .ready
    }
}

/// The rows before the roll has been read — their shape, never a spinner.
private struct SuggestionsSkeleton: View {
    private static let side = AteMetrics.clusterPhotoSuggestion

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(0..<3, id: \.self) { index in
                VStack(alignment: .leading, spacing: 0) {
                    AteHairline()
                    VStack(alignment: .leading, spacing: 10) {
                        HStack {
                            RoundedRectangle(cornerRadius: 6, style: .continuous)
                                .fill(AtePalette.automatic.hairline)
                                .frame(width: 112, height: 15)
                            Spacer(minLength: 0)
                            RoundedRectangle(cornerRadius: 5, style: .continuous)
                                .fill(AtePalette.automatic.hairline)
                                .frame(width: 52, height: 12)
                        }
                        HStack(spacing: -AteMetrics.clusterOverlap) {
                            ForEach(0..<(index == 2 ? 1 : 2), id: \.self) { _ in
                                RoundedRectangle(
                                    cornerRadius: AteMetrics.photoRadius(side: Self.side), style: .continuous
                                )
                                .fill(AtePalette.automatic.hairline)
                                .frame(width: Self.side, height: Self.side)
                            }
                        }
                        .padding(.vertical, AteMetrics.tight)
                        .padding(.leading, 6)
                    }
                    .padding(.vertical, AteMetrics.loose)
                }
            }
        }
        .accessibilityHidden(true)
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
