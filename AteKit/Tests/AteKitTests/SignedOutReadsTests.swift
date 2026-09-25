import Foundation
import Supabase
import Testing

@testable import AteKit

/// **The signed-out browser's reads leave the device.** `Welcome`'s "See what everyone's eating"
/// reads the feed, and the place, dish and profile pages it links to, with no session — as `anon`
/// (0034). A client-side "sign in first" guard in front of any of them is the bug this pins: the
/// request must go, carrying no user token, and a viewer-relative question nobody can ask signed
/// out is answered locally.
@Suite("Signed-out reads", .serialized)
struct SignedOutReadsTests {

    /// Answers every request with `[]` and remembers what was asked.
    final class Stub: URLProtocol, @unchecked Sendable {
        static let log = RequestLog()

        override static func canInit(with request: URLRequest) -> Bool { true }
        override static func canonicalRequest(for request: URLRequest) -> URLRequest { request }

        override func startLoading() {
            Self.log.append(request)
            let response = HTTPURLResponse(
                url: request.url!, statusCode: 200, httpVersion: "HTTP/1.1",
                headerFields: ["Content-Type": "application/json"]
            )!
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: Data("[]".utf8))
            client?.urlProtocolDidFinishLoading(self)
        }

        override func stopLoading() {}
    }

    final class RequestLog: @unchecked Sendable {
        private let lock = NSLock()
        private var requests: [URLRequest] = []
        func append(_ request: URLRequest) { lock.withLock { requests.append(request) } }
        func paths() -> [String] { lock.withLock { requests.compactMap { $0.url?.path } } }
        func bearers() -> [String?] { lock.withLock { requests.map { $0.value(forHTTPHeaderField: "Authorization") } } }
        func reset() { lock.withLock { requests.removeAll() } }
    }

    /// A client with nobody signed in, talking to the stub.
    func signedOut() -> AteAPIClient {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [Stub.self]
        let supabase = SupabaseClient(
            supabaseURL: URL(string: "https://signed-out.invalid")!,
            supabaseKey: "sb_publishable_test",
            options: SupabaseClientOptions(
                auth: SupabaseClientOptions.AuthOptions(
                    storage: StagingContract.EphemeralAuthStorage(),
                    autoRefreshToken: false
                ),
                global: SupabaseClientOptions.GlobalOptions(session: URLSession(configuration: configuration))
            )
        )
        return AteAPIClient(supabase: supabase)
    }

    @Test("the feed, a place's entries, a dish's reviews and a profile's entries all load signed out")
    func readsGoOut() async throws {
        Stub.log.reset()
        let api = signedOut()
        #expect(api.isSignedIn == false)
        let id = UUID()

        #expect(try await EntryFeedClient(api: api).feedPage(after: nil, pageSize: 20).items.isEmpty)
        #expect(try await PlacePageClient(api: api)
            .entriesAtPlace(restaurantID: id, scope: .all, after: nil, pageSize: 20).items.isEmpty)
        #expect(try await DishPageClient(api: api).dishReviews(dishID: id, after: nil, pageSize: 20).items.isEmpty)
        #expect(try await ProfileClient(api: api).entriesPage(authorID: id, after: nil, pageSize: 20).items.isEmpty)

        let paths = Stub.log.paths()
        for function in ["get_entry_feed", "get_entries_at_place", "get_dish_reviews", "get_entries_by_author"] {
            #expect(paths.contains { $0.hasSuffix("/rpc/\(function)") }, "\(function) never left the device")
        }
        // As `anon`: the publishable key, never a user's token.
        #expect(Stub.log.bearers().allSatisfy { $0 == nil || $0 == "Bearer sb_publishable_test" })
    }

    @Test("signed out there is no \"you\": a place's own-visits list is empty without asking")
    func noYouRows() async throws {
        Stub.log.reset()
        let page = try await PlacePageClient(api: signedOut())
            .entriesAtPlace(restaurantID: UUID(), scope: .mine, after: nil, pageSize: 20)
        #expect(page.items.isEmpty)
        #expect(Stub.log.paths().isEmpty)
    }

    @Test("signed out, nothing is saved — answered here, not asked of an RPC anon cannot call")
    func nothingIsSaved() async throws {
        Stub.log.reset()
        #expect(try await DishPageClient(api: signedOut()).isDishSaved(dishID: UUID()) == false)
        #expect(Stub.log.paths().contains { $0.hasSuffix("/rpc/is_dish_saved") } == false)
    }
}
