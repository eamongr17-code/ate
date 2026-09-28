import Foundation
import Testing
@testable import AteKit

@Suite("Load failure")
struct LoadFailureTests {
    @Test("No row is gone; everything else is couldn't-reach-Ate")
    func classify() {
        #expect(LoadFailure(AteAPIError.notFound(table: "entry_cards", id: UUID())) == .gone)
        #expect(LoadFailure(URLError(.notConnectedToInternet)) == .unreachable)
        #expect(LoadFailure(URLError(.timedOut)) == .unreachable)
        #expect(LoadFailure(AteAPIError.notAuthenticated) == .unreachable)
        #expect(LoadFailure(CocoaError(.fileReadCorruptFile)) == .unreachable)
    }
}
