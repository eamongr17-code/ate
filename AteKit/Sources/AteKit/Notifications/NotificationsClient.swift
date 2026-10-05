import Foundation
import PostgREST
import Supabase

/// **The live notifications, tag and push-token calls** — one client for the three seams, all thin
/// RPCs. Rows decode with ``PostgRESTDate/decoder`` (microsecond timestamps make the keyset exact).
public struct NotificationsClient: NotificationsReading, AteWithResponding, PushTokenRegistering {
    private let api: AteAPIClient

    public init(api: AteAPIClient) {
        self.api = api
    }

    // MARK: - The list

    public func notifications(after cursor: PageCursor?, limit: Int) async throws -> NotificationPage {
        let clamped = min(PageRequest.maximumLimit, max(1, limit))
        let parameters: [String: AnyJSON] = [
            "p_limit": .integer(clamped),
            // Both halves of the keyset, or neither.
            "p_cursor_created_at": cursor.map { .string(PostgRESTTimestamp.string(from: $0.createdAt)) } ?? .null,
            "p_cursor_id": cursor.map { .string($0.id.uuidString.lowercased()) } ?? .null
        ]
        let data = try await api.supabase.rpc("my_notifications", params: parameters).execute().data
        let rows = try PostgRESTDate.decoder.decode([AteNotification].self, from: data)
        return NotificationPage(items: rows, requestedLimit: clamped)
    }

    public func unreadCount() async throws -> Int {
        try await api.rpc("unread_notification_count", decoding: Int.self)
    }

    public func dismiss(notificationID: UUID) async throws {
        try await api.callRPC(
            "dismiss_notification", parameters: ["p_id": .string(notificationID.uuidString.lowercased())]
        )
    }

    // MARK: - Answering

    public func prefill(companionID: UUID) async throws -> AteWithPrefill {
        try await mapped {
            let parameters = ["p_companion_id": AnyJSON.string(companionID.uuidString.lowercased())]
            let data = try await api.supabase
                .rpc("ate_with_prefill", params: parameters)
                .execute()
                .data
            return try PostgRESTDate.decoder.decode(AteWithPrefill.self, from: data)
        }
    }

    public func respond(companionID: UUID, entryID: UUID, items: [AteWithItem], body: String) async throws
        -> EntryCard {
        try await mapped {
            let lines: [AnyJSON] = items.map { item in
                var line: [String: AnyJSON] = ["dish_id": .string(item.dishID.uuidString.lowercased())]
                if let score = item.score { line["score"] = .double(score.value) }
                return .object(line)
            }
            let parameters: [String: AnyJSON] = [
                "p_companion_id": .string(companionID.uuidString.lowercased()),
                "p_entry_id": .string(entryID.uuidString.lowercased()),
                "p_items": .array(lines),
                "p_body": .string(body)
            ]
            let data = try await api.supabase.rpc("respond_ate_with", params: parameters).execute().data
            let rows = try PostgRESTDate.decoder.decode([EntryCard].self, from: data)
            guard let card = rows.first else { throw AteWithError.unreachable }
            return card
        }
    }

    public func decline(companionID: UUID) async throws {
        try await mapped {
            try await api.callRPC(
                "decline_ate_with", parameters: ["p_companion_id": .string(companionID.uuidString.lowercased())]
            )
        }
    }

    // MARK: - Push

    public func register(token: String, environment: APNsEnvironment) async throws {
        try await api.callRPC(
            "register_push_token",
            parameters: ["p_token": .string(token), "p_apns_env": .string(environment.rawValue)]
        )
    }

    public func unregister(token: String) async throws {
        try await api.callRPC("unregister_push_token", parameters: ["p_token": .string(token)])
    }

    /// The server's refusals as ``AteWithError``; anything that is not a PostgREST error is the
    /// network's.
    private func mapped<T>(_ call: () async throws -> T) async throws -> T {
        do {
            return try await call()
        } catch let error as PostgrestError {
            throw AteWithError(code: error.code, message: error.message)
        } catch let error as AteWithError {
            throw error
        } catch {
            throw AteWithError.unreachable
        }
    }
}
