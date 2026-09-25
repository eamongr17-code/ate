import Foundation

/// **`Settings`** — the state behind the nine rows.
///
/// Three of them are server facts (handle, photo, blocked people), one is a local preference
/// (appearance), one is a page of words (AI), two are documents, and two end the session. The model's whole
/// job is that each row reports what is actually true: the handle row shows the handle the server
/// holds, not the one this device last typed, and the delete row does not report success until the
/// RPC did.
@MainActor
@Observable
public final class SettingsModel {
    /// The handle in the row's right-hand column, `@`-prefixed. Nil until the profile has loaded —
    /// the row draws no value rather than a placeholder (design rule 1: no helper copy).
    public private(set) var handle: String?
    public private(set) var avatarURL: URL?
    public private(set) var userID: UUID?
    /// True while the avatar is being uploaded.
    public private(set) var isUploadingAvatar = false
    /// True from the moment Delete is confirmed until the session is gone.
    public private(set) var isDeleting = false
    /// Set when a write was refused. The row reverts; the flag is what lets the screen say so.
    public private(set) var didFail = false
    /// …and the one refusal the screen has to put into words: Delete account did nothing.
    public private(set) var didFailToDelete = false

    @ObservationIgnored public let preferences: AtePreferences
    @ObservationIgnored private let account: any AccountServing
    @ObservationIgnored private let analytics: AnalyticsRecorder
    @ObservationIgnored private var hasLoaded = false

    public init(
        account: any AccountServing,
        preferences: AtePreferences,
        analytics: @escaping AnalyticsRecorder = { _ in }
    ) {
        self.account = account
        self.preferences = preferences
        self.analytics = analytics
    }

    /// The `@eamon` in the Handle row.
    public var displayHandle: String? { handle.map(HandleName.display) }

    // MARK: - The row that is a preference

    /// Appearance — System / Light / Dark.
    public var appearance: AteAppearance {
        get { preferences.appearance }
        set {
            guard newValue != preferences.appearance else { return }
            preferences.appearance = newValue
            analytics(AccountEvents.appearanceChanged(newValue))
        }
    }

    // MARK: - Rows that are the server

    /// Read once per appearance of the screen, not once per body. A settings page that refetched on
    /// every redraw would make five requests to draw one handle.
    public func loadIfNeeded() async {
        guard hasLoaded == false else { return }
        hasLoaded = true
        analytics(AccountEvents.settingsViewed())
        await reload()
    }

    /// Re-read the profile — after the handle screen wrote a new one, or a pull to refresh.
    public func reload() async {
        guard let profile = try? await account.account() else { return }
        userID = profile.id
        handle = profile.username
        avatarURL = profile.avatarURL
    }

    /// The page came back into view — from the handle page, most often. The first appearance is
    /// ``loadIfNeeded()``'s; this is every one after it.
    public func reloadIfLoaded() async {
        guard hasLoaded else { return }
        await reload()
    }

    /// The handle screen came back with a new handle. Applied locally rather than re-read, so the
    /// row is right the instant the push pops.
    public func handleChanged(to newHandle: String) {
        handle = newHandle
    }

    /// Photo.
    public func setAvatar(_ image: AvatarUpload) async {
        isUploadingAvatar = true
        didFail = false
        defer { isUploadingAvatar = false }
        do {
            avatarURL = try await account.setAvatar(image)
        } catch {
            didFail = true
        }
    }

    /// The failure has been shown.
    public func acknowledgeFailure() {
        didFail = false
        didFailToDelete = false
    }

    // MARK: - Rows that end the session

    public func signOut() async {
        analytics(AccountEvents.signedOut())
        try? await account.signOut()
    }

    /// Delete account: your photos, then `delete_account`, then the session.
    ///
    /// The sign-out happens whenever the server took the data — including the half-deletion where
    /// the login survived, because staying signed into a scrubbed account helps nobody — but only a
    /// complete deletion is reported as ``AccountDeletionOutcome/deleted``. A refusal changes
    /// nothing and keeps the session.
    @discardableResult
    public func deleteAccount() async -> AccountDeletionOutcome {
        guard isDeleting == false else { return .refused }
        isDeleting = true
        didFail = false
        didFailToDelete = false
        defer { isDeleting = false }
        let result: AccountDeletion
        do {
            result = try await account.deleteAccount()
        } catch {
            didFail = true
            didFailToDelete = true
            return .refused
        }
        guard result.ok else {
            didFail = true
            didFailToDelete = true
            return .refused
        }
        // Reported before the sign-out: afterwards there is no session, and an event sent from
        // nobody is an event about nobody. The half-deletion is in the same event, so it reaches us.
        analytics(AccountEvents.accountDeleted(authUserDeleted: result.authUserDeleted))
        try? await account.signOut()
        guard result.authUserDeleted else {
            didFailToDelete = true
            return .loginSurvived
        }
        return .deleted
    }
}

/// How Delete account ended.
public enum AccountDeletionOutcome: Sendable, Equatable {
    /// The account and everything in it is gone, and so is the session.
    case deleted
    /// The data is gone and the session ended, but the login survived (`auth_user_deleted = false`).
    /// Not the deletion that was asked for — the screen says so before it lets go.
    case loginSurvived
    /// Nothing happened. Still signed in.
    case refused

    /// Whether the session is over and the app should go back to `Welcome`.
    public var endsSession: Bool { self != .refused }
}
