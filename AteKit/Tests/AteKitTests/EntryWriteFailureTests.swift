import Foundation
import Supabase
import Testing
@testable import AteKit

@Suite("EntryWriteFailure — retry later, or refused")
struct EntryWriteFailureTests {
    private static func response(_ status: Int) -> HTTPURLResponse {
        HTTPURLResponse(url: URL(string: "https://x.supabase.co")!, statusCode: status, httpVersion: nil, headerFields: nil)!
    }

    @Test("a cold-starting function, a gateway hiccup or a rate limit is retried, not a save failure")
    func transientAnswersRetry() {
        for status in [500, 502, 503, 504, 408, 425, 429] {
            #expect(EntryWriteFailure.of(FunctionsError.httpError(code: status, data: Data())) == .offline, "\(status)")
            #expect(EntryWriteFailure.of(HTTPError(data: Data(), response: Self.response(status))) == .offline, "\(status)")
        }
        #expect(EntryWriteFailure.of(FunctionsError.relayError) == .offline)
        let expired = PostgrestError(code: "PGRST301", message: "JWT expired")
        #expect(EntryWriteFailure.of(expired) == .offline, "an expired session refreshes and retries")
    }

    @Test("a refusal of the data itself is still a refusal")
    func refusalsReject() {
        for status in [400, 401, 403, 404, 409, 422] {
            #expect(EntryWriteFailure.of(FunctionsError.httpError(code: status, data: Data())).isRetryable == false, "\(status)")
        }
        #expect(EntryWriteFailure.of(PostgrestError(code: "42501", message: "permission denied")).isRetryable == false)
        #expect(EntryWriteFailure.of(URLError(.notConnectedToInternet)) == .offline)
    }
}
