import AteKit
import AuthenticationServices
import SwiftUI

/// **What the whole rebuilt app shares** — and nothing else: the session, the sign-in gate, the
/// handle a first run still owes, the outbox worked on every return to the app, and links into an
/// entry. Tabs, stacks and stores belong to ``TabShell`` and its routers.
///
/// It drives the same AteKit pieces the current app's shell does (`SessionGate`, `AppleSignIn`,
/// `FirstRun`, `EntryOutbox`, `EntryLinkInbox`) with the same behaviour; the current shell keeps
/// its own copy until cutover deletes it.
@MainActor
@Observable
final class AppModel {
    let services: AteServices
    let gate: SessionGate
    private(set) var hasSession: Bool
    private(set) var isSigningIn = false
    /// Apple's display name, first sign-in only: the handle screen's suggestion.
    private(set) var firstRunName: String?
    /// The signed-in person's handle — a receipt is signed, so it is loaded once, here.
    private(set) var handle: String?
    /// The composer is up over the shell. Held here, not by the shell, because a waiting link reads
    /// it: a push made under the composer would be lost.
    var isComposing = false
    /// An entry a link asked for, waiting for the shell to push it on the current tab.
    var linkedEntry: UUID?
    /// Bumped whenever the outbox lands something, so the Journal can refresh under it.
    private(set) var outboxLanded = 0
    /// Signed out, or deleted: the root throws this model and its shell away and builds clean ones.
    @ObservationIgnored private let onSessionEnded: () -> Void

    init(services: AteServices, onSessionEnded: @escaping () -> Void = {}) {
        self.services = services
        self.onSessionEnded = onSessionEnded
        self.gate = SessionGate(analytics: services.analytics)
        self.hasSession = services.hasSession
    }

    // MARK: - Where the person is

    /// Signed in and still owing a handle — a first sign-in that has not pressed Continue yet,
    /// including one that was killed on the handle screen.
    var owesHandle: Bool {
        hasSession && services.preferences.owesHandle(signedInAs: services.api.currentUserID)
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

    /// Continue on the first-run handle: written or kept, first run is over for this person.
    func handleChosen(_ chosen: String) {
        services.preferences.handleChosen(by: services.api.currentUserID)
        firstRunName = nil
        handle = chosen
    }

    // MARK: - The outbox

    /// An entry that could not be sent is still the person's: worked on every return to the app.
    func drainOutbox() async {
        let landed = await services.outbox.run()
        if landed.isEmpty == false { outboxLanded += 1 }
    }

    // MARK: - Getting out

    /// Sign out, or a deleted account — as the current shell does it: the person's draft and queued
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

    /// Back to the current app, from the new one's Settings. The root redraws on the preference.
    func switchToCurrentApp() {
        services.analytics(ShellEvents.appSwitched(to: .current, from: .newSettings))
        services.preferences.opensNewApp = false
    }
}
