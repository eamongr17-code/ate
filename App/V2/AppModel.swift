import AteKit
import AuthenticationServices
import SwiftUI

/// **What the whole rebuilt app shares** — and nothing else: the session, the sign-in gate, the
/// save action, the handle a first run still owes, the outbox worked on every return to the app,
/// and links into an entry. Tabs, stacks and stores belong to ``TabShell`` and its routers.
///
/// It drives the AteKit pieces (`SessionGate`, `AppleSignIn`, `FirstRun`, `EntryOutbox`,
/// `EntryLinkInbox`).
@MainActor
@Observable
final class AppModel {
    let services: AteServices
    let gate: SessionGate
    /// The save, wherever it is made — one of it, so a dish saved on the Feed is saved on every
    /// page that shows it (AGENTS.md rule 2). Every root and page reaches it through here.
    let saves: SaveAction
    /// The Saved shelf the save action keeps stale-marked; the Journal's Saved reads it.
    let savedDishes: SavedDishesStore
    /// Your own saved dishes — one shelf, so a dish shared in or eaten is current on Saved at once.
    let ownSaves: OwnSavesStore
    /// "Ate with": the bell's count and the notifications list — one of it, so a tag answered in the
    /// composer is gone from the list and the count in the same turn.
    let notifications: NotificationsStore
    /// Your lists — one shelf, so a list changed on its own page or from Add to a list is current on
    /// the Journal's Lists shelf in the same turn.
    let lists: ListsStore
    /// Other people's lists waiting on Accept or Decline (0073) — the Notifications page's group, and
    /// a list's own preview, answer through this one.
    let listInvites: ListInvitesStore
    /// Your diet — one of it, so a change in Settings is lit in the composer and on a place's chips
    /// in the same turn.
    let diet: DietStore
    /// A tapped list-invite push, waiting for the shell to open Notifications.
    var linkedInvites = false
    private(set) var hasSession: Bool
    private(set) var isSigningIn = false
    /// Apple's display name, first sign-in only: the handle screen's suggestion.
    private(set) var firstRunName: String?
    /// The signed-in person's handle — a receipt is signed, so it is loaded once, here.
    private(set) var handle: String?
    /// The composer is up over the shell. Held here, not by the shell, because a waiting link reads
    /// it: a push made under the composer would be lost. Open it with ``compose(_:)``; setting this
    /// to `false` closes it and forgets what it was opened with.
    var isComposing = false {
        didSet { if !isComposing { composing = nil } }
    }
    /// What the composer was opened with — its origin (the funnel's first step), any photos it
    /// opens holding, and the entry it is editing. `nil` while the composer is down.
    private(set) var composing: ComposerPresentation?
    /// An entry a link asked for, waiting for the shell to push it on the current tab.
    var linkedEntry: UUID?
    /// Bumped whenever the outbox lands something, so the Journal can refresh under it.
    private(set) var outboxLanded = 0

    /// Opens the composer. The one way in for every affordance: the tab bar's +, the empty
    /// Journal, a photo suggestion's pen, an entry's Edit. The caller has already asked the gate.
    func compose(_ presentation: ComposerPresentation) {
        // A new entry with no place yet: read the rooms around the phone now, quietly, so the Place
        // key opens on them. Never asks for the permission — that stays with the place sheet.
        if presentation.place == nil, presentation.editing == nil, presentation.respondingTo == nil,
           presentation.ateOwnSave == nil {
            services.nearbyPlaces.warm()
        }
        composing = presentation
        isComposing = true
    }
    /// Signed out, or deleted: the root throws this model and its shell away and builds clean ones.
    @ObservationIgnored private let onSessionEnded: () -> Void

    init(services: AteServices, onSessionEnded: @escaping () -> Void = {}) {
        self.services = services
        self.onSessionEnded = onSessionEnded
        let gate = SessionGate(analytics: services.analytics)
        let shelf = SavedDishesStore(saves: services.saves)
        self.gate = gate
        self.savedDishes = shelf
        self.ownSaves = OwnSavesStore(service: services.ownSaves, analytics: services.analytics)
        self.notifications = NotificationsStore(reads: services.notifications, analytics: services.analytics)
        let lists = ListsStore(service: services.lists, analytics: services.analytics)
        self.lists = lists
        self.listInvites = ListInvitesStore(service: services.lists, shelf: lists, analytics: services.analytics)
        self.diet = DietStore(account: services.account, analytics: services.analytics)
        self.saves = SaveAction(
            saves: services.saves,
            analytics: services.analytics,
            shelf: shelf,
            broadcast: services.savedDishes,
            gate: gate
        )
        self.hasSession = services.hasSession
    }

    // MARK: - Where the person is

    /// Signed in and still owing a handle — a first sign-in that has not pressed Continue yet,
    /// including one that was killed on the handle screen.
    var owesHandle: Bool {
        hasSession && services.preferences.owesHandle(signedInAs: services.api.currentUserID)
    }

    /// Past Handle and still to see the onboarding — the photo ask and the meals it found
    /// (``V2Onboarding``).
    var owesOnboarding: Bool {
        hasSession && services.preferences.owesOnboarding(signedInAs: services.api.currentUserID)
    }

    /// Past the door: signed in, or reading signed out.
    var isInside: Bool { hasSession || gate.isBrowsing }

    /// Where the app is, as far as a waiting link cares. The page's own covers (sheets) and whether
    /// the tabs are up are folded in by the link host (``SwiftUICore/View/ateEntryLinks(_:open:)``).
    var linkSituation: EntryLinkInbox.Situation {
        EntryLinkInbox.Situation(
            hasSession: hasSession,
            isBrowsing: gate.isBrowsing,
            owesHandle: owesHandle,
            isCovered: isComposing || gate.isAsking,
            isShellUp: false
        )
    }

    // MARK: - Signing in

    /// Sign in with Apple: what Apple's button came back with, then the token exchanged for a
    /// Supabase session. Returns false when it failed in a way the person must be told about — a
    /// closed sheet is not one of those.
    @discardableResult
    func signInWithApple(_ result: Result<ASAuthorization, any Error>, nonce: String) async -> Bool {
        services.analytics(AccountEvents.signInStarted(provider: .apple))
        isSigningIn = true
        defer { isSigningIn = false }
        let credential: AppleSignIn.Credential
        do {
            credential = try AppleSignIn.credential(from: result, nonce: nonce)
        } catch let error as AppleSignInError {
            services.analytics(AccountEvents.signInFailed(provider: .apple, reason: error.reason))
            return error.reason == .cancelled
        } catch {
            services.analytics(AccountEvents.signInFailed(provider: .apple, reason: .authorization))
            return false
        }
        let signedIn: AppleSignIn.SignedIn
        do {
            signedIn = try await AppleSignIn.exchange(credential, with: services.api)
        } catch {
            services.analytics(AccountEvents.signInFailed(provider: .apple, reason: .exchange))
            return false
        }
        if FirstRun.isNewAccount(
            isFirstAuthorization: credential.isFirstAuthorization,
            createdAt: signedIn.accountCreatedAt
        ) {
            services.preferences.noteOwesHandle(signedIn.userID)
            firstRunName = credential.fullName
        }
        if let name = credential.fullName {
            let account = services.account
            Task { try? await account.setName(name) }
        }
        services.analytics(AccountEvents.signInCompleted(provider: .apple))
        didSignIn()
        return true
    }

    /// The seeded staging account — Debug and Beta only (`debugSignIn` is nil everywhere else).
    func signInToStaging() async {
        guard let debugSignIn = services.debugSignIn else { return }
        services.analytics(AccountEvents.signInStarted(provider: .debugStaging))
        isSigningIn = true
        await debugSignIn.signIn()
        isSigningIn = false
        guard services.hasSession else {
            services.analytics(AccountEvents.signInFailed(provider: .debugStaging, reason: .exchange))
            return
        }
        services.analytics(AccountEvents.signInCompleted(provider: .debugStaging))
        didSignIn()
    }

    func autoSignInIfRequested() async {
        guard hasSession == false, let debugSignIn = services.debugSignIn,
              debugSignIn.isAutoSignInRequested else { return }
        await signInToStaging()
    }

    /// "See what everyone's eating" — or, when Welcome is the sign-in ask, Not Now. True when the
    /// shell should land on the Feed.
    func browse(isPrompt: Bool) -> Bool {
        if isPrompt {
            gate.isAsking = false
            return false
        }
        gate.browse()
        return true
    }

    private func didSignIn() {
        gate.signedIn()
        // Replay first run: the person who asked for it is a new account again from here.
        services.preferences.signedIn(services.api.currentUserID)
        hasSession = services.hasSession
        // A draft from before drafts had owners goes to the person who just signed in.
        services.drafts.adoptUnownedDraft()
    }

    // MARK: - The handle

    /// The handle receipts are signed with — and, if it is still the one the server made up, the
    /// person owes one.
    func loadHandle() async {
        guard hasSession, handle == nil else { return }
        handle = await services.entries.currentHandle()
        if let handle, HandleName.isPlaceholder(handle), let userID = services.api.currentUserID {
            services.preferences.noteOwesHandle(userID)
        }
    }

    /// The diet the composer and a place's chips read — once a session, signed in only.
    func loadDiet() async {
        guard hasSession else { return }
        await diet.loadIfNeeded()
    }

    /// Continue on the first-run handle: written or kept, first run is over for this person.
    func handleChosen(_ chosen: String) {
        services.preferences.handleChosen(by: services.api.currentUserID)
        firstRunName = nil
        handle = chosen
    }

    /// A new handle from Settings: what receipts are signed with from now on. Unlike
    /// ``handleChosen(_:)`` it owes nothing — first run was over long ago.
    func handleRenamed(_ renamed: String) {
        handle = renamed
    }

    // MARK: - The onboarding

    /// The onboarding ended, however it ended: never again for this person. A meal picked opens the
    /// composer on it, over the Journal the shell comes up on.
    func finishOnboarding(_ exit: OnboardingEvents.Exit, writing presentation: ComposerPresentation? = nil) {
        services.analytics(OnboardingEvents.finished(exit))
        services.preferences.onboardingFinished()
        if let presentation { compose(presentation) }
    }

    // MARK: - The outbox

    /// An entry that could not be sent is still the person's: worked on every return to the app.
    func drainOutbox() async {
        let landed = await services.outbox.run()
        if landed.isEmpty == false { outboxLanded += 1 }
        // Tags follow their entries: one that just landed takes its people with it.
        await services.companionTags.run()
        await services.feedback.flush()
    }

    /// **The receipt finishes in the background** (receipt fallback): the outbox is worked the moment
    /// the connection comes back, and once a minute while the app is open — so an entry saved
    /// offline, or one whose sort failed, prints without anybody pressing anything. Every run is a
    /// no-op on an empty queue.
    func keepOutboxMoving() async {
        let restorations = Task { [weak self] in
            for await _ in ConnectivityWatch.restorations() { await self?.drainOutbox() }
        }
        defer { restorations.cancel() }
        while Task.isCancelled == false {
            try? await Task.sleep(for: Self.outboxInterval)
            guard Task.isCancelled == false else { return }
            await drainOutbox()
        }
    }

    private static let outboxInterval = Duration.seconds(60)

    // MARK: - Share to Ate

    /// What the share extension left in the app group while the app was away: its events, sent now
    /// with the app's own session, and — when a dish was saved from another app — Saved read again,
    /// so it is at the top of Saved the moment the app is open.
    func receiveShares() async {
        let inbox = ShareInbox()
        for event in inbox.takeEvents() {
            services.analytics(event)
        }
        guard inbox.takeOwnSavesChanged(), hasSession else { return }
        await ownSaves.refresh()
    }

    // MARK: - Getting out

    /// Sign out, or a deleted account: the person's draft and queued
    /// entries are kept for them, a deleted person's are destroyed, and the root builds a clean app.
    func endSession(deleting deletedUserID: UUID? = nil) {
        services.preferences.pendingHandleUserID = nil
        services.drafts.discardUnowned()
        if let deletedUserID {
            services.drafts.discardDrafts(of: deletedUserID)
            let outbox = services.outbox
            Task { await outbox.discard(authoredBy: deletedUserID) }
        }
        onSessionEnded()
    }
}
