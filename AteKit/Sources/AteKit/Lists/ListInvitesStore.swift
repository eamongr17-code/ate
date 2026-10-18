import Foundation
import Observation

/// **List invites** (0073) — the Notifications page's group: someone's list, waiting on Accept or
/// Decline. Answering is optimistic: the row leaves at once and comes back on a refusal, except an
/// invitation withdrawn meanwhile, which simply stays gone. An accepted list joins the shelf on top.
@MainActor
@Observable
public final class ListInvitesStore {
    public private(set) var invites: [ListInvite] = []
    public private(set) var hasLoaded = false
    /// The last refusal, until ``clearFailure()``.
    public private(set) var failure: ListsError?

    @ObservationIgnored private let service: any ListsServing
    @ObservationIgnored private weak var shelf: ListsStore?
    @ObservationIgnored private let analytics: AnalyticsRecorder
    @ObservationIgnored private let now: () -> Date

    public init(
        service: any ListsServing,
        shelf: ListsStore? = nil,
        analytics: @escaping AnalyticsRecorder = { _ in },
        now: @escaping () -> Date = Date.init
    ) {
        self.service = service
        self.shelf = shelf
        self.analytics = analytics
        self.now = now
    }

    public func clearFailure() { failure = nil }

    /// Quietly keeps what it had when the read fails: the group is simply absent until it works.
    public func refresh() async {
        guard let fresh = try? await service.invites() else { return }
        invites = fresh
        hasLoaded = true
    }

    @discardableResult
    public func respond(to invite: ListInvite, accept: Bool) async -> Bool {
        // From the list's own preview the group may not have been read yet: answer it all the same.
        let index = invites.firstIndex { $0.id == invite.id }
        if let index { invites.remove(at: index) }
        do {
            try await service.respond(toInvite: invite.listID, accept: accept)
            analytics(ListEvents.inviteAnswered(accepted: accept))
            if accept { shelf?.accepted(invite.summary(acceptedAt: now())) }
            return true
        } catch {
            let refusal = ListsError.of(error)
            if let index, refusal != .inviteNotFound { invites.insert(invite, at: min(index, invites.count)) }
            failure = refusal
            return false
        }
    }
}
