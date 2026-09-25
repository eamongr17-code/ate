import AteKit
import SwiftUI

/// **Everything the shell hands down.** One value, built once at the root, so every screen shares one
/// `AteAPIClient` — and therefore one URLSession and one auth session. A second client would mean the
/// sign-in path reached only half the app.
///
/// It is a struct of seams, not a container: each screen takes the one thing it needs.
@MainActor
struct AteServices {
    let environment: AteEnvironment
    let api: AteAPIClient
    let analytics: AnalyticsRecorder
    /// The entry write and read path. A protocol, so previews, tests and a simulator drive can run
    /// the whole loop against memory with no backend at all (`-ate-preview-data`).
    let entries: any EntryService
    /// One draft, on disk. Shared, because the composer and anything that resumes it must be looking
    /// at the same file.
    let drafts: any EntryDraftStoring
    /// Finding, resolving and creating places — the Place key and the entry's place correction.
    let places: any PlaceDirectory
    /// Everyone else's entries. Read-only, and its own seam: the feed never writes.
    let feed: any EntryFeedReading
    /// The feed's one action, and the shelf it fills.
    let saves: any DishSaving
    /// Somebody else's page, and the two things you can do about them.
    let profiles: any ProfileReading
    /// What the You tab gives back: the histogram, a bar's dishes, and the monthly statements.
    let stats: any StatsReading
    /// The place page's three reads. Its own seam and not `places` above — that one finds and
    /// creates places for the composer, and this one only ever reads one.
    let placePages: any PlacePageReading
    /// The dish page's reads.
    let dishPages: any DishPageReading
    /// The one place a bookmark's new state is announced. Everything that draws one listens, so a
    /// save made on an entry page is already true on the feed and the profile underneath it.
    let savedDishes = SavedDishBroadcast()
    /// Entries that have not finished landing. Worked on every foreground.
    let outbox: EntryOutbox
    /// The camera roll, behind a seam — `Suggestions` and the composer's photo staging.
    let photos: any AtePhotoLibrary
    /// Your own account: the handle, the photo, the blocked list, sign out and delete.
    let account: any AccountServing
    /// The phone's own preferences — the appearance, and who still owes a handle. One object for
    /// the whole app, so the root that paints the appearance and the page that changes it agree.
    let preferences: AtePreferences
    /// Present in Debug and Beta pointed at staging; `nil` everywhere else. The seeded demo account,
    /// for drives and for internal builds while staging has no Apple provider.
    let debugSignIn: DebugStagingSignIn?
    /// True when the loop is running against the in-memory service rather than a backend.
    let isPreviewData: Bool

    init(environment: AteEnvironment) {
        let api = AteAPIClient(environment: environment)
        self.environment = environment
        self.api = api
        self.analytics = AteTelemetry.record
        self.debugSignIn = DebugStagingSignIn.make(for: environment, api: api)

        let preview = Self.previewServices()
        self.isPreviewData = preview != nil
        // Whose draft and whose queued entries: the signed-in user, read at every use, so nothing one
        // person leaves on this phone is resumed or posted as the next one. The preview drive has no
        // session, so it is one fixed person.
        let owner: @Sendable () -> UUID?
        if preview == nil {
            owner = { [api] in api.currentUserID }
        } else {
            let fixed = Self.previewOwner
            owner = { fixed }
        }
        let drafts = EntryDraftStore(owner: owner)
        self.drafts = drafts
        self.entries = preview?.entries ?? SupabaseEntryService(api: api)
        self.places = preview?.places ?? PlaceDirectoryClient(api: api)
        self.photos = preview?.photos ?? SystemPhotoLibrary()
        self.feed = preview?.feed ?? EntryFeedClient(api: api)
        self.saves = preview?.saves ?? SaveClient(api: api)
        self.profiles = preview?.profiles ?? ProfileClient(api: api)
        self.stats = preview?.stats ?? StatsClient(api: api)
        self.placePages = preview?.placePages ?? PlacePageClient(api: api)
        self.dishPages = preview?.dishPages ?? DishPageClient(api: api)
        self.account = preview?.account ?? AccountClient(api: api)
        self.preferences = AtePreferences.standard
        self.outbox = EntryOutbox(entries: self.entries, analytics: AteTelemetry.record, owner: owner)
        if api.isSignedIn || preview != nil { drafts.adoptUnownedDraft() }
    }

    /// The save path, as one value: insert, photos, sort, with the outbox behind it.
    var submission: EntrySubmission {
        EntrySubmission(entries: entries, outbox: outbox, analytics: analytics)
    }

    /// The one person a `-ate-preview-data` drive is signed in as.
    nonisolated static let previewOwner = UUID(uuidString: "00000000-0000-4000-8000-00000000A7E0")!

    /// True when there is a session token on hand. Cheap and synchronous — it may be expired, which
    /// the first real request resolves.
    var hasSession: Bool { isPreviewData || api.isSignedIn }

    /// `-ate-preview-data` swaps the live services for in-memory ones carrying the design's own
    /// fixtures, so the whole loop can be driven on a simulator before staging has the new tables.
    /// Debug only, in both directions: the types do not exist in a shipped binary, and a launch
    /// argument cannot be set on an installed app.
    /// The seams `-ate-preview-data` swaps at once.
    private struct PreviewServices {
        let entries: any EntryService
        let places: any PlaceDirectory
        let photos: any AtePhotoLibrary
        // One object stands in for all three in memory — they share state (a dish saved in the
        // feed is on the shelf) — but it is held as its three protocols, so this struct still
        // type-checks in a build where the in-memory types do not exist at all.
        let feed: any EntryFeedReading
        let saves: any DishSaving
        let profiles: any ProfileReading
        let stats: any StatsReading
        /// The place and dish pages are *derived* from the same in-memory entries, so a preview
        /// drive cannot show a dish page that disagrees with the feed it was opened from.
        let placePages: any PlacePageReading
        let dishPages: any DishPageReading
        let account: any AccountServing
    }

    private static func previewServices() -> PreviewServices? {
        #if DEBUG
        let arguments = ProcessInfo.processInfo.arguments
        guard arguments.contains(InMemoryEntryService.launchArgument) else { return nil }
        // The feed owns everyone else's entries, and the entry service reads through to it — so a
        // slip opened from the feed lands on a page that agrees about what has been saved.
        let social = InMemorySocialService()
        // `-ate-preview-empty` is the first-day journal: signed in, nothing written. The one state
        // that cannot be reached by writing something.
        let service = arguments.contains(InMemoryEntryService.emptyLaunchArgument)
            ? InMemoryEntryService(others: social)
            : InMemoryEntryService.seeded(others: social)
        return PreviewServices(
            entries: service, places: InMemoryPlaceDirectory(), photos: PreviewPhotoLibrary(),
            feed: social, saves: social, profiles: social, stats: InMemoryStatsService(),
            placePages: social, dishPages: social, account: InMemoryAccountService()
        )
        #else
        return nil
        #endif
    }

    /// Which backend this build talks to. Debug only — a Release build must never display it, and
    /// this is the one place that decides that.
    var environmentFootnote: String? {
        #if DEBUG
        BuildStamp(environment: environment.name).summary(supabaseHost: environment.supabaseURL.host())
        #else
        nil
        #endif
    }
}
