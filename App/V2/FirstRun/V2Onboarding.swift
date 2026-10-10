import AteKit
import SwiftUI

/// **The onboarding** (`design/rebuild/onboarding-v2.html`) — straight after Handle, once.
///
/// 1. **A photo of you** (``OnboardingPhotoStep``): the avatar, Apple's picker, Not now.
/// 2. **The four cards** (``OnboardingCards``): one sample entry built up — words, photos, scores,
///    the receipt it shares as.
/// 3. **Start with your last meal**: Find it in my photos (the system's own prompt does the asking),
///    Write one now (a blank composer), or Later (the empty Journal). Nothing assumes the roll has
///    food in it.
/// 4. **What it found**: the From your photos rows exactly as Notifications draws them. A pen or a
///    chip opens the composer on that meal over the Journal; the close keeps every meal in
///    Notifications.
/// 5. **Nothing found**, or photos refused: said once, with Write one now and Later.
///
/// Nothing is written without the person writing it.
struct V2Onboarding: View {
    let app: AppModel

    enum Step: Equatable {
        case photo, cards, start, found
        /// The roll had no meals, or access was refused.
        case nothing(refused: Bool)
    }

    @State private var step: Step = .photo
    @State private var photos: PhotoSuggestionsModel
    @State private var isFinding = false
    @State private var pickedChip: String?
    @Environment(\.atePalette) private var palette

    init(app: AppModel) {
        self.app = app
        _photos = State(initialValue: PhotoSuggestionsModel(services: app.services))
    }

    private var places: PhotoPlaceChips { PhotoPlaceChipsSession.shared(app.services) }

    var body: some View {
        NavigationStack {
            Group {
                switch step {
                case .photo:
                    OnboardingPhotoStep(app: app) { answer in
                        app.services.analytics(OnboardingEvents.photo(answer))
                        go(.cards)
                    }
                case .cards:
                    OnboardingCards(onDone: { reached, skipped in
                        app.services.analytics(OnboardingEvents.cards(reached: reached, skipped: skipped))
                        go(.start)
                    }, handle: app.handle ?? "")
                case .start:
                    start
                case .found:
                    found
                case .nothing(let refused):
                    nothing(refused: refused)
                }
            }
            .ateGround()
        }
    }

    private func go(_ next: Step) {
        withAnimation(AteMotion.fillIn) { step = next }
    }

    // MARK: - Start with your last meal

    private var start: some View {
        door(
            title: OnboardingCopy.start,
            identifier: "v2.onboarding.start"
        ) {
            AteInkPill(
                title: OnboardingCopy.find, isEnabled: isFinding == false, identifier: "onboarding.find"
            ) {
                app.services.analytics(OnboardingEvents.started(.photos))
                findThem()
            }
            AteInkPill(title: OnboardingCopy.write, isQuiet: true, identifier: "onboarding.write") {
                app.services.analytics(OnboardingEvents.started(.write))
                writeBlank()
            }
            AteWelcomeLink(title: OnboardingCopy.later, colour: palette.fg, identifier: "onboarding.later") {
                app.services.analytics(OnboardingEvents.started(.later))
                finish(.skipped)
            }
        }
        .task { app.services.analytics(OnboardingEvents.asked()) }
    }

    private func nothing(refused: Bool) -> some View {
        door(
            title: refused ? OnboardingCopy.refused : OnboardingCopy.nothing,
            identifier: "v2.onboarding.nothing"
        ) {
            AteInkPill(title: OnboardingCopy.write, identifier: "onboarding.nothing.write", action: writeBlank)
            AteWelcomeLink(title: OnboardingCopy.later, colour: palette.fg, identifier: "onboarding.nothing.later") {
                finish(refused ? .skipped : .nothingFound)
            }
        }
    }

    /// One centred line over the doors at the foot: the start screen and nothing-found.
    private func door<Doors: View>(
        title: String, identifier: String, @ViewBuilder doors: () -> Doors
    ) -> some View {
        VStack(spacing: 0) {
            Spacer(minLength: AteMetrics.section)
            AteTitle(text: title, style: .handleTitle)
                .padding(.horizontal, OnboardingMetrics.titleInset)
            Spacer(minLength: AteMetrics.section)
            VStack(spacing: OnboardingMetrics.doorsGap) {
                doors()
            }
            .padding(.horizontal, AteMetrics.gutter)
            .ateContentBottom(AteWelcomeCardMetrics.doorsBottom)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .accessibilityIdentifier(identifier)
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
            guard allowed else { return go(.nothing(refused: true)) }
            NotificationCenter.default.post(name: .atePhotoAccessGranted, object: nil)
            go(.found)
        }
    }

    /// Write one now: the blank composer, over the Journal.
    private func writeBlank() {
        AteHaptics.key()
        finish(.wrote, writing: ComposerPresentation(origin: .onboarding))
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
            if photos.clusters.isEmpty { go(.nothing(refused: photos.phase == .off)) }
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
                .frame(maxWidth: .infinity)
                .accessibilityHidden(true)
        } else {
            AteTitle(text: OnboardingCopy.found(photos.clusters.count), style: .handleTitle)
                .frame(maxWidth: .infinity)
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
    static let photo = "Add a photo of you."
    static let choosePhoto = "Choose a photo"
    static let chooseAnother = "Choose another"
    static let notNow = "Not now"
    static let skip = "Skip"
    static let next = "Next"
    static let start = "Start with your last meal."
    static let find = "Find it in my photos"
    static let write = "Write one now"
    static let later = "Later"
    static let nothing = "No meals in your photos yet."
    static let refused = "No photos, no problem."

    static func found(_ meals: Int) -> String {
        meals == 1 ? "1 meal in your photos." : "\(meals) meals in your photos."
    }
}

enum OnboardingMetrics {
    /// `onboarding-v2.html`: every title centred, 32 in from each edge, wrapping on its own.
    static let titleInset: CGFloat = 32
    /// Step 2: the avatar 176 across, the camera disc ringed in the ground on its edge.
    static let avatar: CGFloat = 176
    static let avatarToTitle: CGFloat = 50
    static let badgeIcon: CGFloat = 20
    static let badgeRing: CGFloat = 4
    static let badgeInset: CGFloat = 2
    /// The cards: the art 16 under the bar, the dots 18 over Next.
    static let artTop: CGFloat = 16
    static let dot: CGFloat = 8
    static let dotsToPill: CGFloat = 18
    /// The share card: the story at half size where it fits, the row's disc and two-line label.
    static let storyScale: CGFloat = 0.5
    static let shareRowHeight: CGFloat = 84
    /// Start: the two pills and the link, 10 apart.
    static let doorsGap: CGFloat = 10
    static let titleBar: CGFloat = 220
    static let titleBarHeight: CGFloat = 36
}
