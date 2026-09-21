import Foundation

/// The signed-in person, as the app needs them: a UUID and a handle.
///
/// The handle is load-bearing beyond the You screen — a receipt is signed `@eamon`, and printing one
/// without its signature would be a receipt from nobody.
public struct ViewerProfile: Sendable, Hashable, Codable, Identifiable {
    public let id: UUID
    /// `profiles.username` — `citext UNIQUE`. A display string, never an identifier.
    public let username: String
    public let name: String?
    public let city: String?

    public init(id: UUID, username: String, name: String? = nil, city: String? = nil) {
        self.id = id
        self.username = username
        self.name = name
        self.city = city
    }
}

/// Reading the viewer's own profile row.
///
/// A plain `profiles` select rather than `profile_summary` (integration-design's You header call):
/// the RPC lands with 0023 and the totals it carries are a milestone-2 screen, while the handle is
/// needed by the receipt today. Swapping the implementation is one method.
public protocol ViewerProfileReading: Sendable {
    func viewer() async throws -> ViewerProfile
}

public struct ViewerProfileClient: ViewerProfileReading {
    private let api: AteAPIClient

    public init(api: AteAPIClient) {
        self.api = api
    }

    public func viewer() async throws -> ViewerProfile {
        let id = try await api.requireCurrentUserID()
        let rows: [ViewerProfile] = try await api.supabase
            .from("profiles")
            .select("id,username,name,city")
            .eq("id", value: id.uuidString)
            .limit(1)
            .execute()
            .value
        guard let row = rows.first else { throw AteAPIError.notFound(table: "profiles", id: id) }
        return row
    }
}
