import Foundation
import Synchronization
import Testing
@testable import AteKit

@Suite("Places session")
struct PlacesSessionTests {

    private final class Clock: Sendable {
        let at = Mutex(Date(timeIntervalSince1970: 0))
        func advance(_ seconds: TimeInterval) { at.withLock { $0 += seconds } }
        func now() -> Date { at.withLock { $0 } }
    }

    @Test("Keystrokes in one pick share a token")
    func keystrokesShare() {
        let clock = Clock()
        let session = PlacesSession(now: { clock.now() })
        let first = session.current()
        clock.advance(20)
        #expect(session.current() == first)
    }

    @Test("A resolve retires the token, so the next pick is its own session")
    func resolveRetires() {
        let session = PlacesSession()
        let first = session.current()
        session.retire()
        #expect(session.current() != first)
    }

    @Test("A token older than Google keeps a session open is replaced")
    func staleReplaced() {
        let clock = Clock()
        let session = PlacesSession(now: { clock.now() })
        let first = session.current()
        clock.advance(PlacesSession.lifetime + 1)
        let second = session.current()
        #expect(second != first)
        clock.advance(10)
        #expect(session.current() == second)
    }
}
