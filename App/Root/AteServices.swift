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
    /// Entries that have not finished landing. Worked on every foreground.
    let outbox: EntryOutbox
    /// The camera roll, behind a seam — `Suggestions` and the composer's photo staging.
    let photos: any AtePhotoLibrary
    /// Present in Debug and Beta pointed at staging; `nil` everywhere else. Sign in with Apple is
    /// milestone 2 — until it lands this is the only way into a session.
    let debugSignIn: DebugStagingSignIn?
    /// True when the loop is running against the in-memory service rather than a backend.
    let isPreviewData: Bool

    init(environment: AteEnvironment) {
        let api = AteAPIClient(environment: environment)
        self.environment = environment
        self.api = api
        self.analytics = AteTelemetry.record
        self.drafts = EntryDraftStore()
        self.debugSignIn = DebugStagingSignIn.make(for: environment, api: api)

        let preview = Self.previewServices()
        self.isPreviewData = preview != nil
        self.entries = preview?.entries ?? SupabaseEntryService(api: api)
        self.places = preview?.places ?? PlaceDirectoryClient(api: api)
        self.photos = preview?.photos ?? SystemPhotoLibrary()
        self.feed = preview?.social ?? EntryFeedClient(api: api)
        self.saves = preview?.social ?? SaveClient(api: api)
        self.profiles = preview?.social ?? ProfileClient(api: api)
        self.outbox = EntryOutbox(entries: self.entries, analytics: AteTelemetry.record)
    }

    /// The save path, as one value: insert, photos, sort, with the outbox behind it.
    var submission: EntrySubmission {
        EntrySubmission(entries: entries, outbox: outbox, analytics: analytics)
    }

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
        /// One object standing in for the feed, saves and profiles — they share state (a dish saved
        /// in the feed is on the shelf), so in memory they are one thing.
        let social: InMemorySocialService
    }

    private static func previewServices() -> PreviewServices? {
        #if DEBUG
        let arguments = ProcessInfo.processInfo.arguments
        guard arguments.contains(InMemoryEntryService.launchArgument) else { return nil }
        // `-ate-preview-empty` is the first-day journal: signed in, nothing written. The one state
        // that cannot be reached by writing something.
        let service = arguments.contains(InMemoryEntryService.emptyLaunchArgument)
            ? InMemoryEntryService()
            : InMemoryEntryService.seeded()
        return PreviewServices(
            entries: service, places: InMemoryPlaceDirectory(), photos: PreviewPhotoLibrary(),
            social: InMemorySocialService()
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
