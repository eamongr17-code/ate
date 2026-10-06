import AteKit
import SwiftUI

/// **Notifications** (`lists-notifications.html` E1–E3) — pushed from the Journal's bell, the tab
/// bar staying. Two groups on one page: **Ate with** first (somebody is waiting on you), then **From
/// your photos**. A group with nothing in it is not shown; both empty is the one empty line.
///
/// Ate with: one row type (``AteNotificationRow``), newest first — a tap opens the tag's scoring
/// sheet, the X clears the row (the tag stays), a swipe declines (asked once).
/// From your photos: each sitting a ``PhotoSuggestionRow``; nearby places as chips where the photos
/// carry a location (``PhotoPlaceChips``), attached only on a tap.
///
/// Opening the page asks for push (once ever), and only if that prompt did not appear, for the camera
/// roll (once ever): never two system prompts in one visit. Without photo access the photos group is
/// simply absent.
struct V2NotificationsPage: View {
    let context: V2PageContext

    @State private var isCollapsed = false
    @State private var declining: AteNotification?
    @State private var photos: PhotoSuggestionsModel
    @State private var pickedChip: String?
    @State private var hasLoggedOpen = false
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    init(context: V2PageContext) {
        self.context = context
        _photos = State(initialValue: PhotoSuggestionsModel(services: context.services))
    }

    private var store: NotificationsStore { context.app.notifications }
    private var places: PhotoPlaceChips { PhotoPlaceChipsSession.shared(context.services) }

    private var tagsLoading: Bool { context.app.hasSession && store.phase == .loading }
    private var tagRows: [AteNotification] {
        context.app.hasSession && store.phase == .ready ? store.rows : []
    }
    private var tagsFailed: Bool { context.app.hasSession && store.phase == .failed }
    private var showsPhotos: Bool { photos.phase == .ready && photos.clusters.isEmpty == false }
    private var photosLoading: Bool { photos.phase == .loading }

    /// The band between the title and the tab bar, so the one line sits centred in the page, not
    /// stacked under the title (Eamon, build 95).
    private var emptyBand: CGFloat {
        let band = pageHeight - NotificationsMetrics.titleBand - AteMetrics.tabBarScrollInset
        return max(band, NotificationsMetrics.emptyMinimum)
    }

    /// The list's own height: the empty line is centred in what the title leaves of it. (A List
    /// row's container is the row, so `containerRelativeFrame` cannot measure the page here.)
    @State private var pageHeight: CGFloat = 0

    var body: some View {
        List {
            AtePageTitle(title: NotificationsCopy.title)
                .plainRow()
            content
        }
        .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { pageHeight = $0 }
        .listStyle(.plain)
        .scrollContentBackground(.hidden)
        .scrollIndicators(.hidden)
        .contentMargins(.bottom, AteMetrics.tabBarScrollInset, for: .scrollContent)
        .atePageCollapse($isCollapsed)
        .ateGround()
        .ateCollapsingTitle(NotificationsCopy.title, isCollapsed: isCollapsed)
        .ateAnimation(AteMotion.fillIn, value: store.rows.map(\.id))
        .ateAnimation(AteMotion.fillIn, value: photos.clusters.map(\.id))
        .refreshable { await store.refresh() }
        .task { await open() }
        .onDisappear { logOpened() }
        // Photos allowed elsewhere (Settings, or the Summary's ask) while the page was up: read the roll.
        .onChange(of: scenePhase) { _, now in
            guard now == .active, photos.phase == .off, photos.library.isAuthorized else { return }
            Task { await photos.load(mayAsk: false) }
        }
        .onChange(of: context.app.isComposing) { _, isComposing in
            if isComposing == false { pickedChip = nil }
        }
        .confirmationDialog(
            declining.map { NotificationsCopy.declineTitle(handle: $0.actor.username) } ?? "",
            isPresented: Binding(get: { declining != nil }, set: { if $0 == false { declining = nil } }),
            titleVisibility: .visible,
            presenting: declining
        ) { row in
            Button(NotificationsCopy.decline, role: .destructive) { decline(row) }
        }
        .accessibilityIdentifier("notifications.page")
    }

    // MARK: - The groups

    @ViewBuilder
    private var content: some View {
        if tagsLoading && tagRows.isEmpty {
            ForEach(0..<NotificationsMetrics.skeletonRows, id: \.self) { index in
                AteNotificationRowSkeleton(isFirst: index == 0).plainRow()
            }
        } else {
            if tagRows.isEmpty == false {
                band(NotificationsCopy.ateWith, isFirst: true)
                tags
            }
            if showsPhotos {
                band(NotificationsCopy.fromPhotos, isFirst: tagRows.isEmpty)
                suggestions
            } else if photosLoading && tagRows.isEmpty {
                band(NotificationsCopy.fromPhotos, isFirst: true)
                ForEach(0..<SuggestionMetrics.skeletons, id: \.self) { index in
                    SuggestionSkeletonRow(photos: index == 0 ? 2 : 1).plainRow()
                }
            }
            if tagRows.isEmpty && showsPhotos == false && photosLoading == false {
                if tagsFailed {
                    AteEmptyState(
                        line: NotificationsCopy.unreachable, pill: (title: NotificationsCopy.retry, action: retry)
                    )
                        .frame(height: emptyBand)
                        .plainRow()
                        .accessibilityIdentifier("state.unreachable")
                } else {
                    AteEmptyState(line: NotificationsCopy.empty)
                        .frame(height: emptyBand)
                        .plainRow()
                        .accessibilityIdentifier("state.empty")
                }
            }
        }
    }

    /// A group's name — `.band{600 16px/1; min-height:44px}`, 14 above the first and 18 above the next.
    private func band(_ title: String, isFirst: Bool) -> some View {
        AteBandHeading(title: title)
            .frame(minHeight: AteMetrics.hit)
            .padding(.horizontal, AteMetrics.gutter)
            .padding(.top, isFirst ? NotificationsMetrics.firstBandTop : NotificationsMetrics.bandTop)
            .accessibilityAddTraits(.isHeader)
            .plainRow()
    }

    private var tags: some View {
        ForEach(Array(tagRows.enumerated()), id: \.element.id) { index, row in
            AteNotificationRow(
                userID: row.actor.id,
                handle: row.actor.username,
                line: NotificationsCopy.line(handle: row.actor.username),
                meta: NotificationsCopy.meta(row),
                isFirst: index == 0,
                onOpen: { open(row) },
                onClear: { Task { await store.dismiss(row) } }
            )
            .plainRow()
            .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                Button(NotificationsCopy.decline, role: .destructive) { declining = row }
                    .tint(AteColor.destructive)
            }
            .accessibilityAction(named: NotificationsCopy.decline) { declining = row }
            .onAppear {
                if row.id == store.rows.last?.id { Task { await store.loadMore() } }
            }
        }
    }

    private var suggestions: some View {
        ForEach(photos.clusters) { cluster in
            PhotoSuggestionRow(
                cluster: cluster,
                isFirst: cluster.id == photos.clusters.first?.id,
                library: photos.library,
                chips: places.chips(for: cluster.id),
                pickedChip: pickedChip,
                onWrite: { write(cluster, place: nil) },
                onDismiss: { dismiss(cluster) },
                onChip: { chip, rank in pick(chip, rank: rank, for: cluster) }
            )
            .plainRow()
            .onAppear {
                places.appeared(cluster.id, at: cluster.coordinate)
                Task { await places.drain() }
            }
            .onDisappear { places.disappeared(cluster.id) }
        }
    }

    // MARK: - Opening

    private func open() async {
        async let tags: Void = refreshTags()
        // Push first; the camera roll may ask only if push did not.
        let prompted = context.app.hasSession
            ? await AtePush.shared.askOnce(trigger: .notifications, services: context.services)
            : false
        await photos.load(mayAsk: prompted == false)
        await tags
        logOpened()
    }

    private func refreshTags() async {
        guard context.app.hasSession else { return }
        await store.refresh()
        context.services.analytics(NotificationEvents.notificationsOpened(unread: store.unreadCount))
    }

    /// `notifications_section_opened`, once a visit: when both groups have settled, or on leaving.
    private func logOpened() {
        guard hasLoggedOpen == false else { return }
        hasLoggedOpen = true
        context.services.analytics(NotificationEvents.notificationsSectionOpened(
            tags: tagRows.count, photos: photos.clusters.count
        ))
    }

    // MARK: - Doing things

    private func open(_ row: AteNotification) {
        guard let companionID = row.companionID, context.gate.permitsWrite(.compose) else { return }
        context.services.analytics(NotificationEvents.ateWithOpened(from: .list))
        context.app.compose(.respond(to: companionID))
    }

    /// The pen, or the row: the composer holding these photos — and a place only if a chip was tapped.
    private func write(_ cluster: PhotoSuggestionCluster, place: PlaceRef?) {
        guard context.gate.permitsWrite(.compose) else { return }
        AteHaptics.key()
        context.app.compose(ComposerPresentation(
            origin: .photoSuggestion,
            assetIdentifiers: cluster.items.map(\.id),
            place: place
        ))
    }

    /// A chip: inked at once, its place made real (free for a place we hold), then the composer
    /// holding the photos and that place. A failed resolve opens it without one, silently.
    private func pick(_ chip: PlaceSuggestion, rank: Int, for cluster: PhotoSuggestionCluster) {
        guard pickedChip == nil, context.gate.permitsWrite(.compose) else { return }
        pickedChip = chip.id
        context.services.analytics(NotificationEvents.photoPlaceChipTapped(rank: rank))
        let directory = context.services.places
        Task {
            let place = try? await directory.resolve(chip)
            write(cluster, place: place?.id == nil ? nil : place)
        }
    }

    private func dismiss(_ cluster: PhotoSuggestionCluster) {
        withAnimation(reduceMotion ? nil : .easeOut(duration: SuggestionMetrics.dismissDuration)) {
            photos.dismiss(cluster)
        }
    }

    private func decline(_ row: AteNotification) {
        declining = nil
        guard let companionID = row.companionID else { return }
        let services = context.services
        store.finished(companionID: companionID)
        services.analytics(NotificationEvents.notificationDismissed(how: .decline))
        Task {
            do {
                try await services.ateWith.decline(companionID: companionID)
            } catch AteWithError.gone {
                // Already withdrawn: the row was right to go.
            } catch {
                await store.refresh()
            }
        }
    }

    private func retry() {
        Task { await store.refresh() }
    }
}

/// The nearby-place chips' answers, kept for the session (one planner for the app's life), so a
/// sitting is asked about once however often the page is opened.
@MainActor
enum PhotoPlaceChipsSession {
    private static var planner: PhotoPlaceChips?

    static func shared(_ services: AteServices) -> PhotoPlaceChips {
        if let planner { return planner }
        let directory = services.places
        let made = PhotoPlaceChips { try await directory.nearby(latitude: $0.latitude, longitude: $0.longitude) }
        planner = made
        return made
    }
}

private extension View {
    /// A row of the page's plain list: edge to edge on the ground, no system separator (the rows draw
    /// their own hairline).
    func plainRow() -> some View {
        listRowInsets(EdgeInsets())
            .listRowSeparator(.hidden)
            .listRowBackground(Color.clear)
    }
}

enum NotificationsCopy {
    static let title = "Notifications"
    static let empty = "Nothing new"
    static let unreachable = "Couldn't reach Ate."
    static let retry = "Try again"
    static let decline = "Decline"
    static let ateWith = "Ate with"
    static let fromPhotos = "From your photos"

    static func line(handle: String) -> String { "@\(handle) ate with you" }

    static func declineTitle(handle: String) -> String { "Remove yourself from @\(handle)'s entry?" }

    /// Where and when: "Tipo 00, Sat 19 Sep". A place that has gone is not guessed at.
    static func meta(_ row: AteNotification) -> String? {
        let day = row.visitedAt.map { RelativeAge.day($0) }
        let parts = [row.place?.name, day].compactMap { $0 }
        return parts.isEmpty ? nil : parts.joined(separator: ", ")
    }
}

enum NotificationsMetrics {
    static let skeletonRows = 4
    /// `.band` padding-top: 14 above the page's first group, 18 above the next.
    static let firstBandTop: CGFloat = 14
    static let bandTop: CGFloat = 18
    /// What the page title row takes of the list's height, bar to the first band: measured on the
    /// iPhone 17 Pro at the default type size.
    static let titleBand: CGFloat = 150
    /// The empty band never drops below this, so the line keeps clear of the title.
    static let emptyMinimum: CGFloat = 260
}
