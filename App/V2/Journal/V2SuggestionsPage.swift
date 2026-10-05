import AteKit
import SwiftUI
import UIKit

/// The old **From your photos** route. The page folded into Notifications on 5 Oct
/// (`lists-notifications.html` E1): the route stays so nothing that pushes it breaks, and it opens
/// the one page.
struct V2SuggestionsPage: View {
    let context: V2PageContext

    init(context: V2PageContext) {
        self.context = context
    }

    var body: some View {
        V2NotificationsPage(context: context)
    }
}

/// **From your photos, as data** — the camera roll's recent meals grouped into sittings, newest
/// first, a dismissed sitting gone for good (``PhotoSuggestionDismissals``). Owned by the
/// Notifications page, which decides whether this visit may ask for the camera roll: the push
/// prompt comes first, and a visit never shows two system prompts.
@MainActor
@Observable
final class PhotoSuggestionsModel {
    enum Phase: Equatable {
        /// Not looked yet, or looking with nothing found so far.
        case loading
        case ready
        case empty
        /// No permission (refused, or not asked this visit): the group is simply not shown.
        case off
    }

    private(set) var phase: Phase = .loading
    private(set) var clusters: [PhotoSuggestionCluster] = []

    @ObservationIgnored private let services: AteServices
    @ObservationIgnored private var dismissals: PhotoSuggestionDismissals?

    init(services: AteServices) {
        self.services = services
    }

    var library: any AtePhotoLibrary { services.photos }
    var isSettled: Bool { phase != .loading }

    /// Reads the roll. `mayAsk`: the system's photo prompt may appear (never asked before, and no
    /// other prompt this visit). Each sitting appears as its photos are confirmed as food; leaving
    /// the page cancels the task, which stops the looking.
    func load(mayAsk: Bool) async {
        if dismissals == nil {
            dismissals = PhotoSuggestionDismissals(store: UserDefaultsStore(), owner: services.photoOwner)
        }
        if library.isAuthorized == false {
            guard mayAsk, library.canAsk, await library.requestAuthorization() else {
                phase = .off
                return
            }
        }
        for await food in library.recentProgressively() {
            clusters = dismissals?.clusters(food) ?? PhotoSuggestions.cluster(food)
            if clusters.isEmpty == false { phase = .ready }
        }
        guard Task.isCancelled == false else { return }
        phase = clusters.isEmpty ? .empty : .ready
    }

    func dismiss(_ cluster: PhotoSuggestionCluster) {
        dismissals?.dismiss(cluster)
        services.analytics(SuggestionEvents.dismissed(photos: cluster.items.count))
        clusters.removeAll { $0.id == cluster.id }
        if clusters.isEmpty { phase = .empty }
    }
}

/// **A sitting to write up** — the day, the time, the muted ✕, the photos as a tilted cluster and
/// the ink pen; under it, where the photos carry a location, up to three nearby places as chips.
/// Tap the row (or the pen) for the composer holding the photos and no place; tap a chip for the
/// composer holding the photos and that place. Nothing is attached without that tap.
struct PhotoSuggestionRow: View {
    let cluster: PhotoSuggestionCluster
    /// The group's first sitting sits under its band: no hairline, 4 above (`.sug.first`).
    var isFirst = false
    let library: any AtePhotoLibrary
    let chips: [PlaceSuggestion]
    /// The chip being opened with, inked while its place resolves.
    var pickedChip: String?
    let onWrite: () -> Void
    let onDismiss: () -> Void
    let onChip: (PlaceSuggestion, Int) -> Void

    @Environment(\.atePalette) private var palette

    var body: some View {
        VStack(alignment: .leading, spacing: SuggestionMetrics.gap) {
            HStack(spacing: AteMetrics.snug) {
                Text(PhotoSuggestions.title(for: cluster.date))
                    .ateText(.control)
                    .foregroundStyle(palette.fg)
                    .frame(maxWidth: .infinity, alignment: .leading)
                Text(PhotoSuggestions.time(for: cluster.date))
                    .ateText(.meta)
                    .foregroundStyle(palette.muted)
                dismissButton
            }
            HStack(spacing: AteMetrics.snug) {
                SuggestionPhotos(library: library, ids: cluster.items.map(\.id))
                Spacer(minLength: 0)
                AteGlassDisc(icon: .edit, label: "Write up", role: .primary, identifier: "suggestions.write") {
                    onWrite()
                }
            }
            if chips.isEmpty == false {
                AtePlaceChipRow {
                    ForEach(Array(chips.enumerated()), id: \.element.id) { index, chip in
                        AtePlaceChip(name: chip.name, isOn: pickedChip == chip.id, identifier: "suggestions.place") {
                            onChip(chip, index + 1)
                        }
                    }
                }
                .transition(.opacity)
            }
        }
        .padding(.horizontal, AteMetrics.gutter)
        .padding(.top, isFirst ? SuggestionMetrics.firstTop : AteMetrics.loose)
        .padding(.bottom, AteMetrics.loose)
        .overlay(alignment: .top) { if isFirst == false { AteHairline() } }
        .contentShape(.rect)
        // Tap to enter. The ✕, the pen and the chips are real buttons, so they take their taps first.
        .onTapGesture { onWrite() }
        .accessibilityElement(children: .contain)
        .accessibilityAction(named: "Write up") { onWrite() }
        .accessibilityIdentifier("suggestions.row")
    }

    /// The row's ✕ — muted, at the corner, its 44 target hanging past the row's own lines.
    private var dismissButton: some View {
        Button(action: onDismiss) {
            AteIcon.close.view(size: SuggestionMetrics.dismissGlyph)
                .frame(width: AteMetrics.hit, height: AteMetrics.hit)
                .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .foregroundStyle(palette.muted)
        .frame(width: SuggestionMetrics.dismissGlyph, height: SuggestionMetrics.dismissGlyph)
        .accessibilityLabel("Dismiss")
        .accessibilityIdentifier("suggestions.dismiss")
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
struct SuggestionSkeletonRow: View {
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
        .padding(.horizontal, AteMetrics.gutter)
        .padding(.vertical, AteMetrics.loose)
        .overlay(alignment: .top) { AteHairline().padding(.horizontal, AteMetrics.gutter) }
        .ateBreathing()
        .accessibilityHidden(true)
    }
}

enum SuggestionMetrics {
    static let skeletons = 2
    static let maximumPhotos = 3
    static let dismissGlyph: CGFloat = 16
    static let dismissDuration = 0.25
    static let titleBar: CGFloat = 112
    static let timeBar: CGFloat = 52
    static let bar: CGFloat = 14
    static let firstTop: CGFloat = 4
    /// `.sug{gap:10px}`.
    static let gap: CGFloat = 10

    /// A tile's identity is its place in the row: a sitting's photos never reorder, so the tiles
    /// keep their place (and their tilt) as the images arrive.
    static func photoID(_ position: Int) -> UUID {
        UUID(uuidString: String(format: "00000000-0000-4000-8000-%012X", position)) ?? UUID()
    }
}
