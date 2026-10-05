import Foundation

/// **The notifications list and its badge** (0058). Signed in only.
public protocol NotificationsReading: Sendable {
    /// `my_notifications` — newest first, keyset `(created_at, id)`: BOTH halves of the last row's
    /// cursor, or neither (one alone is `22023`).
    func notifications(after cursor: PageCursor?, limit: Int) async throws -> NotificationPage
    /// `unread_notification_count()` — the bell's number.
    func unreadCount() async throws -> Int
    /// `dismiss_notification(p_id)` — the X. The tag stays; only the row goes.
    func dismiss(notificationID: UUID) async throws
}

/// **Answering an "Ate with" tag** (0058): the live prefill, the person's own entry, or no.
public protocol AteWithResponding: Sendable {
    /// `ate_with_prefill(p_companion_id)`. Marks its notification read. Throws ``AteWithError``.
    func prefill(companionID: UUID) async throws -> AteWithPrefill
    /// `respond_ate_with` — posts the person's OWN entry: same place, the tagger's visit time, their
    /// lines. `entryID` is minted once by the caller, so a retry returns the same card.
    func respond(companionID: UUID, entryID: UUID, items: [AteWithItem], body: String) async throws -> EntryCard
    /// `decline_ate_with` — off the tagger's entry. The tagger is not told.
    func decline(companionID: UUID) async throws
}

/// **This phone's APNs token** (0058), registered for whoever is signed in.
public protocol PushTokenRegistering: Sendable {
    func register(token: String, environment: APNsEnvironment) async throws
    func unregister(token: String) async throws
}

public extension NotificationsReading {
    static var defaultPageSize: Int { 30 }
}
