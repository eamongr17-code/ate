import AteKit
import SwiftUI

/// **Getting in, and getting out.** Welcome, Sign in with Apple, the signed-out feed, the first-run
/// handle, and the end of a session — out of the shell's own file so the shell stays a shell.
extension AteShell {

    // MARK: - Screens

    /// `Welcome`. The same screen twice: the front door, and — over the signed-out feed — the ask
    /// that comes up when a browser tries to write, where its link means Not Now.
    func welcome(isPrompt: Bool) -> some View {
        var debugDoor: (() async -> Void)?
        if services.debugSignIn != nil {
            debugDoor = { await signInToStaging() }
        }
        return WelcomeScreen(
            onSignIn: { await signInWithApple() },
            onBrowse: { browse(isPrompt: isPrompt) },
            onDebugSignIn: debugDoor,
            isBusy: isSigningIn
        )
    }

    /// "See what everyone's eating" — or, when Welcome is the ask, Not Now.
    private func browse(isPrompt: Bool) {
        if isPrompt {
            gate.isAsking = false
        } else {
            gate.browse()
            tab = .feed
        }
    }

    /// Whether the signed-in person still owes a handle — a first sign-in that has not pressed
    /// Continue yet, including one that was killed on the handle screen.
    var owesHandle: Bool {
        #if DEBUG
        if SettingsDebugLaunch.opensFirstRunHandle { return true }
        #endif
        return services.preferences.owesHandle(signedInAs: services.api.currentUserID)
    }

    /// `Handle`, as the last step of a first sign-in. No way back: Continue is the only way on.
    var firstRunHandle: some View {
        FirstRunHandle(services: services, suggestion: firstRunName) { chosen in
            // Written or kept, first run is over for this person — never routed back here again.
            services.preferences.handleChosen(by: services.api.currentUserID)
            firstRunName = nil
            handle = chosen
        }
    }

    // MARK: - Signing in

    /// Sign in with Apple: Apple's sheet, then the token exchanged for a Supabase session.
    func signInWithApple() async {
        services.analytics(AccountEvents.signInStarted(provider: .apple))
        isSigningIn = true
        defer { isSigningIn = false }
        let credential: AppleSignIn.Credential
        do {
            credential = try await AppleSignIn.authorize()
        } catch let error as AppleSignInError {
            services.analytics(AccountEvents.signInFailed(provider: .apple, reason: error.reason))
            return
        } catch {
            services.analytics(AccountEvents.signInFailed(provider: .apple, reason: .authorization))
            return
        }
        let signedIn: AppleSignIn.SignedIn
        do {
            signedIn = try await AppleSignIn.exchange(credential, with: services.api)
        } catch {
            services.analytics(AccountEvents.signInFailed(provider: .apple, reason: .exchange))
            return
        }
        if FirstRun.isNewAccount(
            isFirstAuthorization: credential.isFirstAuthorization,
            createdAt: signedIn.accountCreatedAt
        ) {
            services.preferences.noteOwesHandle(signedIn.userID)
            firstRunName = credential.fullName
        }
        // The one sign-in Apple says who this is. The trigger could not hear it (the token has no
        // name claim), so it is written here — best effort: a failure leaves the placeholder name,
        // which the person never sees on their own pages.
        if let name = credential.fullName {
            Task { try? await services.account.setName(name) }
        }
        services.analytics(AccountEvents.signInCompleted(provider: .apple))
        didSignIn()
    }

    /// The seeded staging account — Debug and Beta only.
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

    /// There is a session. A browser stays where they were — on the feed they were reading, now
    /// with their own bookmarks in it — and nothing of the signed-out read survives.
    private func didSignIn() {
        let wasBrowsing = gate.isBrowsing
        gate.signedIn()
        hasSession = services.hasSession
        // A draft from before drafts had owners goes to the person who just signed in.
        services.drafts.adoptUnownedDraft()
        journal.invalidate()
        feedArea.reloadSelection()
        if wasBrowsing {
            Task { await feed.refresh() }
        }
    }

    // MARK: - While signed in

    /// Settings, and the pages it pushes.
    func settings(_ page: SettingsPage) -> some View {
        SettingsDestination(
            page: page,
            services: services,
            onOpen: { open(.settings($0)) },
            onHandleChanged: { handleChanged($0) },
            onSignedOut: { endSession() },
            onDeleted: { endSession(deleting: $0) }
        )
    }

    /// A new handle from Settings: receipts are signed with it from now on, and You shows it.
    func handleChanged(_ newHandle: String) {
        handle = newHandle
        Task { await you.refresh() }
    }

    /// Journal and You are yours. A browser tapping either is asked to sign in, and stays put.
    /// An entry page reads `entry_cards`, which a browser cannot (0034): the card stays, and the
    /// browser is asked to sign in.
    func mayOpen(_ route: Route) -> Bool {
        guard case .entry = route else { return true }
        return gate.permitsWrite(.entry)
    }

    func mayOpen(_ tapped: AteTab) -> Bool {
        switch tapped {
        case .journal: gate.permitsWrite(.journal)
        case .you: gate.permitsWrite(.you)
        case .feed, .search: true
        }
    }

    // MARK: - Getting out

    /// Sign out, or a deleted account. The session is already gone; this forgets whose phone it was
    /// and hands back to the root, which builds a clean shell on `Welcome` — every in-memory store
    /// (journal, shelf, feed, You, statements) is the shell's, so none of it reaches the next person.
    ///
    /// On disk, a signed-out person's draft and queued entries are **kept, and scoped to them**: they
    /// wait for that person, and nobody else can resume or push them (`EntryDraftStore`,
    /// `EntryOutbox`). A deleted person's are destroyed, because nobody can ever post them now.
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

/// The first-run handle screen, once it knows what the account was made with.
///
/// `handle_new_user` gives every sign-up a handle derived from its email — which, behind Apple's
/// private relay, is a string of letters nobody chose. So the field opens on Apple's own name for the
/// person when there is one (sanitised, and checked like anything typed), and on the derived handle
/// otherwise, which is theirs and needs no check.
private struct FirstRunHandle: View {
    let services: AteServices
    let suggestion: String?
    let onDone: (String) -> Void

    @State private var model: HandleModel?

    var body: some View {
        Group {
            if let model {
                HandleScreen(model: model, onDone: onDone)
            } else {
                Color.clear.ateGround()
            }
        }
        .task {
            guard model == nil else { return }
            let current = try? await services.account.account().username
            let made = HandleModel(
                account: services.account,
                analytics: services.analytics,
                current: current,
                isFirstRun: true
            )
            if let suggestion {
                let named = HandleName.sanitise(suggestion)
                if named.isEmpty == false, named != current { made.typed = named }
            }
            model = made
        }
    }
}
