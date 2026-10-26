import AteKit
import SwiftUI

/// **Notifications** (`lists-notifications.html` E1–E3, rows refined in `notifications-refined.html`,
/// 25 Oct, groups by kind) — pushed from the Journal's bell, the tab bar staying. Three groups on one
/// page: **List invites** (`list-cover-edit.html` 7), then **Ate with** (somebody is waiting on you),
/// then **From your photos**. A group with nothing in it is not shown; all empty is the one empty line.
///
/// Invites and tags are one row (``AteNotificationRow``): a sentence, Decline and the answer as pills
/// under it, the picture at the right, a coral dot while it is new.
/// List invites: "@eamon invited you to Date night", the count, the list's cover. A tap on the row
/// previews the list; Accept puts it on your Lists shelf; Decline clears it, untold.
/// Ate with: "@jess ate with you at Tipo 00", the day, the tagger's photo; newest first. A tap or
/// "Add yours" opens the tag's scoring sheet; Decline asks once; a swipe's Clear takes the row (the
/// tag stays).
/// From your photos: the newest two sittings, each a ``PhotoSuggestionRow``; with more, the heading
/// carries the count and opens them all (``Route/suggestions``, this page with only that group).
/// Nearby places show as chips where the photos carry a location (``PhotoPlaceChips``), attached
/// only on a tap.
///
/// Opening the page asks for push (once ever), and only if that prompt did not appear, for the camera
/// roll (once ever): never two system prompts in one visit. Without photo access the photos group is
/// simply absent.
struct V2NotificationsPage: View {
    let context: V2PageContext
    /// Every photo sitting and nothing else: the photos group's heading, opened.
    var photosOnly = false

    @State private var isCollapsed = false
    /// Where the header's name ends: the bar takes it once the page has scrolled past.
    @State private var titleBottom: CGFloat = 0
    @State private var declining: AteNotification?
    @State private var photos: PhotoSuggestionsModel
    @State private var pickedChip: String?
    @State private var hasLoggedOpen = false
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    init(context: V2PageContext, photosOnly: Bool = false) {
        self.context = context
        self.photosOnly = photosOnly
        _photos = State(initialValue: PhotoSuggestionsModel(services: context.services))
    }

    private var store: NotificationsStore { context.app.notifications }
    private var places: PhotoPlaceChips { PhotoPlaceChipsSession.shared(context.services) }

    private var title: String { photosOnly ? NotificationsCopy.fromPhotos : NotificationsCopy.title }
    private var hasPeople: Bool { context.app.hasSession && photosOnly == false }
    private var tagsLoading: Bool { hasPeople && store.phase == .loading }
    private var tagRows: [AteNotification] {
        hasPeople && store.phase == .ready ? store.rows : []
    }
    private var tagsFailed: Bool { hasPeople && store.phase == .failed }
    private var invites: [ListInvite] { hasPeople ? context.app.listInvites.invites : [] }
    /// The sittings this page lists: all of them on the photos page, the newest two here.
    private var shownClusters: [PhotoSuggestionCluster] {
        photosOnly ? photos.clusters : Array(photos.clusters.prefix(NotificationsMetrics.photosShown))
    }
    private var morePhotos: Bool { photosOnly == false && photos.clusters.count > NotificationsMetrics.photosShown }
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
            AtePageTitle(title: title, titleBottom: $titleBottom)
                .plainRow()
            content
        }
        .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { pageHeight = $0 }
        .listStyle(.plain)
        .scrollContentBackground(.hidden)
        .scrollIndicators(.hidden)
        .contentMargins(.bottom, AteMetrics.tabBarScrollInset, for: .scrollContent)
        .ateTitleCollapse($isCollapsed, after: titleBottom)
        .ateGround()
        .ateCollapsingTitle(title, isCollapsed: isCollapsed)
        .ateAnimation(AteMotion.fillIn, value: store.rows.map(\.id))
        .ateAnimation(AteMotion.fillIn, value: invites.map(\.id))
        .ateAnimation(AteMotion.fillIn, value: photos.clusters.map(\.id))
        .refreshable {
            guard hasPeople else { return }
            async let waiting: Void = context.app.listInvites.refresh()
            await store.refresh()
            await waiting
        }
        .task { await open() }
        // Back from the photos page: what was written up or dismissed there leaves here too.
        .onAppear { if photos.phase == .ready { photos.photosWrittenUp() } }
        .onDisappear { logOpened() }
        // Photos allowed elsewhere (Settings, or the Summary's ask) while the page was up: read the roll.
        .onChange(of: scenePhase) { _, now in
            guard now == .active, photos.phase == .off, photos.library.isAuthorized else { return }
            Task { await photos.load(mayAsk: false) }
        }
        .onReceive(NotificationCenter.default.publisher(for: .ateSuggestionPhotosWrittenUp)) { _ in
            photos.photosWrittenUp()
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
            if invites.isEmpty == false {
                band(ListsCopy.listInvites, isFirst: true)
                inviteRows
            }
            if tagRows.isEmpty == false {
                band(NotificationsCopy.ateWith, isFirst: invites.isEmpty)
                tags
            }
            if showsPhotos {
                if photosOnly {
                    Color.clear.frame(height: NotificationsMetrics.firstBandTop).plainRow()
                } else {
                    photosBand(isFirst: tagRows.isEmpty && invites.isEmpty)
                }
                suggestions
            } else if photosLoading && tagRows.isEmpty {
                if photosOnly == false { band(NotificationsCopy.fromPhotos, isFirst: invites.isEmpty) }
                ForEach(0..<SuggestionMetrics.skeletons, id: \.self) { index in
                    SuggestionSkeletonRow(photos: index == 0 ? 2 : 1).plainRow()
                }
            }
            if tagRows.isEmpty && invites.isEmpty && showsPhotos == false && photosLoading == false {
                if tagsFailed {
                    AteEmptyState(
                        line: NotificationsCopy.unreachable, art: .unplugged,
                        pill: (title: NotificationsCopy.retry, action: retry)
                    )
                        .frame(height: emptyBand)
                        .plainRow()
                        .accessibilityIdentifier("state.unreachable")
                } else {
                    AteEmptyState(line: NotificationsCopy.empty, art: .bell)
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

    /// "From your photos", and with more sittings than are shown, the count and the way to them all.
    @ViewBuilder
    private func photosBand(isFirst: Bool) -> some View {
        if morePhotos {
            AteBandHeading(
                title: NotificationsCopy.fromPhotos, count: photos.clusters.count,
                identifier: "notifications.photos.all"
            ) {
                context.services.analytics(NotificationEvents.photoSuggestionsAllOpened(count: photos.clusters.count))
                context.open(.suggestions, from: .journal)
            }
            .frame(minHeight: AteMetrics.hit)
            .padding(.horizontal, AteMetrics.gutter)
            .padding(.top, isFirst ? NotificationsMetrics.firstBandTop : NotificationsMetrics.bandTop)
            .plainRow()
        } else {
            band(NotificationsCopy.fromPhotos, isFirst: isFirst)
        }
    }

    private var tags: some View {
        ForEach(Array(tagRows.enumerated()), id: \.element.id) { index, row in
            AteNotificationRow(
                userID: row.actor.id,
                handle: row.actor.username,
                avatarURL: row.actor.avatarURL.flatMap(URL.init(string:)),
                sentence: NotificationsCopy.sentence(row),
                detail: NotificationsCopy.day(row),
                isUnread: row.isUnread,
                decline: NotificationsCopy.decline,
                primary: NotificationsCopy.addYours,
                isFirst: index == 0,
                onOpen: { open(row, from: .list) },
                onDecline: { declining = row },
                onPrimary: { open(row, from: .pill) },
                trailing: {
                    if let photo = row.photoURL {
                        AteThumb(photo: .remote(photo))
                    }
                }
            )
            .plainRow()
            .swipeActions(edge: .trailing, allowsFullSwipe: true) {
                Button(NotificationsCopy.clear) { Task { await store.dismiss(row) } }
            }
            .accessibilityAction(named: NotificationsCopy.clear) { Task { await store.dismiss(row) } }
            .onAppear {
                if row.id == store.rows.last?.id { Task { await store.loadMore() } }
            }
        }
    }

    private var inviteRows: some View {
        ForEach(Array(invites.enumerated()), id: \.element.id) { index, invite in
            AteNotificationRow(
                userID: invite.owner.id,
                handle: invite.owner.username,
                avatarURL: invite.owner.avatarURL.flatMap(URL.init(string:)),
                sentence: ListsCopy.invited(by: invite.owner.username, to: invite.name),
                detail: ListsCopy.dishes(invite.itemCount),
                // Unanswered until it leaves the page: every invite here is waiting on you.
                isUnread: true,
                decline: ListsCopy.decline,
                primary: ListsCopy.accept,
                isFirst: index == 0,
                identifier: "invite.row",
                onOpen: { context.open(.list(ListRoute(id: invite.listID)), from: .journal) },
                onDecline: { answer(invite, accept: false) },
                onPrimary: { answer(invite, accept: true) },
                trailing: {
                    AteListCover(
                        id: invite.listID, name: invite.name, covers: invite.covers, cover: invite.coverURL,
                        style: .row
                    )
                }
            )
            .plainRow()
        }
    }

    private var suggestions: some View {
        ForEach(shownClusters) { cluster in
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
        guard photosOnly == false else {
            // Reached from the photos group's heading: the roll is already allowed.
            await photos.load(mayAsk: false)
            return
        }
        async let tags: Void = refreshTags()
        async let waiting: Void = refreshInvites()
        // Push first; the camera roll may ask only if push did not.
        let prompted = context.app.hasSession
            ? await AtePush.shared.askOnce(trigger: .notifications, services: context.services)
            : false
        await photos.load(mayAsk: prompted == false)
        await tags
        await waiting
        logOpened()
    }

    private func refreshTags() async {
        guard context.app.hasSession else { return }
        await store.refresh()
        context.services.analytics(NotificationEvents.notificationsOpened(unread: store.unreadCount))
    }

    private func refreshInvites() async {
        guard context.app.hasSession else { return }
        await context.app.listInvites.refresh()
    }

    /// `notifications_section_opened`, once a visit: when both groups have settled, or on leaving.
    private func logOpened() {
        guard hasLoggedOpen == false, photosOnly == false else { return }
        hasLoggedOpen = true
        context.services.analytics(NotificationEvents.notificationsSectionOpened(
            tags: tagRows.count, photos: photos.clusters.count
        ))
    }

    // MARK: - Doing things

    private func open(_ row: AteNotification, from source: NotificationEvents.Source) {
        guard let companionID = row.companionID, context.gate.permitsWrite(.compose) else { return }
        context.services.analytics(NotificationEvents.ateWithOpened(from: source))
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

    /// Accept or Decline: the row goes at once, the bell's count with it.
    private func answer(_ invite: ListInvite, accept: Bool) {
        guard context.gate.permitsWrite(.journal) else { return }
        AteHaptics.key()
        Task {
            await context.app.listInvites.respond(to: invite, accept: accept)
            await store.refreshCount()
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
    static let empty = "Nothing new."
    static let unreachable = "Couldn't\nreach Ate."
    static let retry = "Try again"
    static let decline = "Decline"
    static let addYours = "Add yours"
    static let clear = "Clear"
    static let ateWith = "Ate with"
    static let fromPhotos = "From your photos"

    /// "**@jess** ate with you at **Tipo 00**". A place that has gone is not guessed at.
    static func sentence(_ row: AteNotification) -> [AteNotificationRun] {
        var runs: [AteNotificationRun] = [.strong("@\(row.actor.username)"), .plain(" ate with you")]
        if let place = row.place?.name { runs += [.plain(" at "), .strong(place)] }
        return runs
    }

    /// The visit's day, after the sentence: "Sat 19 Sep".
    static func day(_ row: AteNotification) -> String? {
        row.visitedAt.map { RelativeAge.day($0) }
    }

    static func declineTitle(handle: String) -> String { "Remove yourself from @\(handle)'s entry?" }
}

enum NotificationsMetrics {
    static let skeletonRows = 4
    /// The photo sittings on the page itself; the heading opens the rest.
    static let photosShown = 2
    /// `.band` padding-top: 14 above the page's first group, 18 above the next.
    static let firstBandTop: CGFloat = 14
    static let bandTop: CGFloat = 18
    /// What the page title row takes of the list's height, bar to the first band: measured on the
    /// iPhone 17 Pro at the default type size.
    static let titleBand: CGFloat = 150
    /// The empty band never drops below this, so the line keeps clear of the title.
    static let emptyMinimum: CGFloat = 260
}
