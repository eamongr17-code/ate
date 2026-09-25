import Foundation
import Testing

@testable import AteKit

/// **Signed out, but looking** — reading is free, and the first write asks.
@Suite("Session gate — the signed-out feed")
@MainActor
struct SessionGateTests {

    @Test("a signed-in person is never asked")
    func signedInWritesFreely() {
        let events = EventLog()
        let gate = SessionGate(analytics: events.recorder)
        #expect(gate.permitsWrite(.save))
        #expect(gate.permitsWrite(.compose))
        #expect(gate.isAsking == false)
        #expect(events.names.isEmpty)
    }

    @Test("a browser's first write is refused and asks, once, naming the write")
    func browserIsAsked() {
        let events = EventLog()
        let gate = SessionGate(analytics: events.recorder)
        gate.browse()
        #expect(gate.isBrowsing)
        #expect(gate.permitsWrite(.save) == false)
        #expect(gate.isAsking)
        // A second tap while Welcome is already up is still refused, and is not a second prompt.
        #expect(gate.permitsWrite(.compose) == false)
        #expect(events.names == ["browse_started", "sign_in_prompted"])
        #expect(events.first(named: "sign_in_prompted")?.parameters["trigger"] == "save")
    }

    @Test("Not now puts the browser back, and the next write asks again")
    func dismissedPromptAsksAgain() {
        let events = EventLog()
        let gate = SessionGate(analytics: events.recorder)
        gate.browse()
        _ = gate.permitsWrite(.journal)
        gate.isAsking = false
        #expect(gate.permitsWrite(.report) == false)
        #expect(events.events(named: "sign_in_prompted").map { $0.parameters["trigger"] } == ["journal", "report"])
    }

    @Test("signing in ends browsing and closes the prompt")
    func signingInOpensTheDoor() {
        let gate = SessionGate()
        gate.browse()
        _ = gate.permitsWrite(.you)
        gate.signedIn()
        #expect(gate.isBrowsing == false)
        #expect(gate.isAsking == false)
        #expect(gate.permitsWrite(.save))
    }

    @Test("browse_started is once, however many times the door is used")
    func browseIsReportedOnce() {
        let events = EventLog()
        let gate = SessionGate(analytics: events.recorder)
        gate.browse()
        gate.browse()
        #expect(events.names == ["browse_started"])
    }
}
