import Foundation
import Supabase

/// One Google Places *session*: the autocomplete keystrokes plus the final `op=details` that
/// resolves the pick, billed by Google as a single session instead of one charge per keystroke
/// (BE-PLACES-3, the biggest cost lever in places-integration.md).
///
/// The picker mints one on appear, reuses it across every keystroke, and **retires it on resolve** —
/// reusing a token after its details call is what silently turns one session back into per-keystroke
/// billing.
public struct PlacesSessionToken: Sendable, Hashable {
    public let value: String

    public init() {
        self.value = UUID().uuidString
    }

    public init(value: String) {
        self.value = value
    }
}

/// The `places-search` edge function, as the client sees it. A protocol so the picker's model can be
/// driven from a fixture without a network or a JWT.
public protocol PlacesSearching: Sendable {
    func autocomplete(
        query: String,
        origin: SearchOrigin?,
        sessionToken: PlacesSessionToken?
    ) async throws -> PlacesAutocompleteResponse

    func nearby(origin: SearchOrigin, radiusMeters: Double?) async throws -> PlacesNearbyResponse

    func details(
        googlePlaceID: String,
        sessionToken: PlacesSessionToken?
    ) async throws -> PlacesDetailsResponse
}

/// The real implementation.
///
/// Every op is `POST places-search?op=…` and **requires a verified end-user JWT** (TIDY-BE-2: the
/// bare anon key resolves to no user → 401). We check the session first and throw
/// ``AteAPIError/notAuthenticated`` rather than letting a 401 surface as "couldn't search" — a
/// signed-out user needs to be told to sign in, not offered a retry button.
public struct PlacesSearchClient: PlacesSearching {
    private let api: AteAPIClient
    private let functionName = "places-search"

    public init(api: AteAPIClient) {
        self.api = api
    }

    public func autocomplete(
        query: String,
        origin: SearchOrigin?,
        sessionToken: PlacesSessionToken?
    ) async throws -> PlacesAutocompleteResponse {
        try await invoke(
            op: "autocomplete",
            body: AutocompleteBody(
                input: query,
                lat: origin?.latitude,
                lng: origin?.longitude,
                sessionToken: sessionToken?.value
            )
        )
    }

    public func nearby(origin: SearchOrigin, radiusMeters: Double?) async throws -> PlacesNearbyResponse {
        try await invoke(
            op: "nearby",
            body: NearbyBody(lat: origin.latitude, lng: origin.longitude, radius: radiusMeters)
        )
    }

    public func details(
        googlePlaceID: String,
        sessionToken: PlacesSessionToken?
    ) async throws -> PlacesDetailsResponse {
        try await invoke(
            op: "details",
            body: DetailsBody(googlePlaceID: googlePlaceID, sessionToken: sessionToken?.value)
        )
    }

    private func invoke<Body: Encodable & Sendable, Response: Decodable & Sendable>(
        op: String,
        body: Body
    ) async throws -> Response {
        try await api.requireCurrentUserID()
        return try await api.supabase.functions.invoke(
            functionName,
            options: FunctionInvokeOptions(
                method: .post,
                query: [URLQueryItem(name: "op", value: op)],
                body: body
            )
        )
    }

    private struct AutocompleteBody: Encodable, Sendable {
        let input: String
        let lat: Double?
        let lng: Double?
        let sessionToken: String?

        enum CodingKeys: String, CodingKey {
            case input, lat, lng
            case sessionToken = "session_token"
        }
    }

    private struct NearbyBody: Encodable, Sendable {
        let lat: Double
        let lng: Double
        let radius: Double?
    }

    private struct DetailsBody: Encodable, Sendable {
        let googlePlaceID: String
        let sessionToken: String?

        enum CodingKeys: String, CodingKey {
            case googlePlaceID = "google_place_id"
            case sessionToken = "session_token"
        }
    }
}
