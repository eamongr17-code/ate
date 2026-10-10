import AteKit
import SwiftUI

/// **The onboarding** (`design/rebuild/first-run.html`, steps 3–5) — straight after Handle, once.
///
/// 1. **The one ask**: "Your last meals are already in your photos.", one ink pill (Find them), and
///    Not now. The only permission first run asks for, and the system's own prompt does the asking.
/// 2. **What it found**: the From your photos rows exactly as Notifications draws them — sitting,
///    time, cluster, nearby place chips, the pen. A pen or a chip opens the composer on that meal over
///    the Journal; the close keeps every meal in Notifications.
///
/// Not now, a refusal, or an empty roll lands on the Journal as it always has. Nothing is written
/// without the person writing it.
struct V2Onboarding: View {
    let app: AppModel

    @State private var photos: PhotoSuggestionsModel
    @State private var isFinding = false
    @State private var hasFound = false
    @State private var pickedChip: String?
    /// Made once, so the two photos keep their identity across redraws.
    @State private var askPhotos = AteWelcomeCardMetrics.photos.map { AtePhoto(image: Image($0)) }
    @Environment(\.atePalette) private var palette

    init(app: AppModel) {
        self.app = app
        _photos = State(initialValue: PhotoSuggestionsModel(services: app.services))
    }

    private var places: PhotoPlaceChips { PhotoPlaceChipsSession.shared(app.services) }

    var body: some View {
        NavigationStack {
            Group {
                if hasFound {
                    found
                } else {
                    ask
                }
            }
            .ateGround()
        }
        .task { app.services.analytics(OnboardingEvents.asked()) }
    }

    // MARK: - The one ask

    private var ask: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Welcome's two photos, tilted together above the line: the same mess an entry wears.
            PhotoCluster(
                photos: askPhotos,
                side: OnboardingMetrics.photo,
                surface: palette.ground,
                topPadding: 0,
                bottomPadding: 0,
                overlap: AteWelcomeCardMetrics.overlap,
                angles: OnboardingMetrics.angles
            )
            .frame(maxWidth: .infinity)
            .padding(.top, OnboardingMetrics.askTop)
            .accessibilityHidden(true)
            AteTitle(text: OnboardingCopy.ask, style: .handleTitle, alignment: .leading)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, AteHandleFieldMetrics.pageInset)
                .padding(.top, OnboardingMetrics.photosToTitle)
            Spacer(minLength: AteMetrics.section)
            VStack(spacing: AteWelcomeCardMetrics.doorsGap) {
                AteInkPill(
                    title: OnboardingCopy.find, isEnabled: isFinding == false, identifier: "onboarding.find"
                ) {
                    findThem()
                }
                Button(action: notNow) {
                    Text(OnboardingCopy.notNow)
                        .ateText(.control)
                        .underline()
                        .frame(minHeight: AteMetrics.hit)
                        .contentShape(.rect)
                }
                .buttonStyle(.plain)
                .foregroundStyle(palette.fg)
                .accessibilityIdentifier("onboarding.notNow")
            }
            .padding(.horizontal, AteMetrics.gutter)
            .ateContentBottom(AteWelcomeCardMetrics.doorsBottom)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .accessibilityIdentifier("v2.onboarding.ask")
    }

    private func findThem() {
        isFinding = true
        let library = photos.library
        Task {
            var allowed = library.isAuthorized
            if allowed == false, library.canAsk {
                allowed = await library.requestAuthorization()
            }
            isFinding = false
            app.services.analytics(OnboardingEvents.answered(allowed ? .allowed : .denied))
            guard allowed else { return finish(.skipped) }
            NotificationCenter.default.post(name: .atePhotoAccessGranted, object: nil)
            hasFound = true
        }
    }

    private func notNow() {
        app.services.analytics(OnboardingEvents.answered(.skipped))
        finish(.skipped)
    }

    // MARK: - What it found

    private var found: some View {
        List {
            foundTitle
                .padding(.horizontal, AteMetrics.gutter)
                .padding(.bottom, AteMetrics.snug)
                .onboardingRow()
            if photos.clusters.isEmpty {
                ForEach(0..<SuggestionMetrics.skeletons, id: \.self) { index in
                    SuggestionSkeletonRow(photos: index == 0 ? 2 : 1).onboardingRow()
                }
            } else {
                ForEach(photos.clusters) { cluster in
                    PhotoSuggestionRow(
                        cluster: cluster,
                        isFirst: cluster.id == photos.clusters.first?.id,
                        library: photos.library,
                        chips: places.chips(for: cluster.id),
                        pickedChip: pickedChip,
                        onWrite: { write(cluster, place: nil) },
                        onDismiss: { photos.dismiss(cluster) },
                        onChip: { chip, rank in pick(chip, rank: rank, for: cluster) }
                    )
                    .onboardingRow()
                    .onAppear {
                        places.appeared(cluster.id, at: cluster.coordinate)
                        Task { await places.drain() }
                    }
                    .onDisappear { places.disappeared(cluster.id) }
                }
            }
        }
        .listStyle(.plain)
        .scrollContentBackground(.hidden)
        .scrollIndicators(.hidden)
        .ateAnimation(AteMotion.fillIn, value: photos.clusters.map(\.id))
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                AteGlassDisc(icon: .close, label: "Close", identifier: "onboarding.close") {
                    finish(.closed)
                }
            }
            .sharedBackgroundVisibility(.hidden)
        }
        .task {
            await photos.load(mayAsk: false)
            guard Task.isCancelled == false else { return }
            app.services.analytics(OnboardingEvents.found(meals: photos.clusters.count))
            if photos.clusters.isEmpty { finish(photos.phase == .off ? .skipped : .nothingFound) }
        }
        .accessibilityIdentifier("v2.onboarding.found")
    }

    /// "14 meals in your photos." — counting up as the roll is read; its shape until the first one.
    @ViewBuilder
    private var foundTitle: some View {
        if photos.clusters.isEmpty {
            AteSkeletonBar(
                width: OnboardingMetrics.titleBar, height: OnboardingMetrics.titleBarHeight, palette: .automatic
            )
                .ateSkeletonSweep()
                .accessibilityHidden(true)
        } else {
            AteTitle(text: OnboardingCopy.found(photos.clusters.count), style: .handleTitle, alignment: .leading)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    /// The pen, or the row: the composer holding these photos, over the Journal.
    private func write(_ cluster: PhotoSuggestionCluster, place: PlaceRef?) {
        AteHaptics.key()
        finish(.wrote, writing: ComposerPresentation(
            origin: .photoSuggestion,
            assetIdentifiers: cluster.items.map(\.id),
            place: place
        ))
    }

    /// A chip: inked at once, its place made real, then the composer holding the photos and that place.
    private func pick(_ chip: PlaceSuggestion, rank: Int, for cluster: PhotoSuggestionCluster) {
        guard pickedChip == nil else { return }
        pickedChip = chip.id
        app.services.analytics(NotificationEvents.photoPlaceChipTapped(rank: rank))
        let directory = app.services.places
        Task {
            let place = try? await directory.resolve(chip)
            write(cluster, place: place?.id == nil ? nil : place)
        }
    }

    private func finish(_ exit: OnboardingEvents.Exit, writing presentation: ComposerPresentation? = nil) {
        app.finishOnboarding(exit, writing: presentation)
    }
}

private extension View {
    /// A row of the found list: edge to edge on the ground, no system separator.
    func onboardingRow() -> some View {
        listRowInsets(EdgeInsets())
            .listRowSeparator(.hidden)
            .listRowBackground(Color.clear)
    }
}

enum OnboardingCopy {
    static let ask = "Your last\nmeals are\nalready in\nyour photos."
    static let find = "Find them"
    static let notNow = "Not now"

    static func found(_ meals: Int) -> String {
        meals == 1 ? "1 meal\nin your photos." : "\(meals) meals\nin your photos."
    }
}

enum OnboardingMetrics {
    /// `first-run.html` step 3: the cluster at `top:132px`, 112 a side, `-7` and `5`; the title 66 under it.
    static let askTop: CGFloat = 78
    static let photo: CGFloat = 112
    static let angles: [Double] = [-7, 5]
    static let photosToTitle: CGFloat = 66
    static let titleBar: CGFloat = 220
    static let titleBarHeight: CGFloat = 36
}
