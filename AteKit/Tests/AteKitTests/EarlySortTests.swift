import Foundation
import Testing
@testable import AteKit

/// What the scheduler sent, and what got cancelled on the way — safe from any isolation.
private final class Sent: @unchecked Sendable {
    private let lock = NSLock()
    private var inputs: [EarlySortInput] = []
    private var cancelled: [EarlySortInput] = []
    private var concurrent = 0
    private(set) var maximumConcurrent = 0

    func begin(_ input: EarlySortInput) {
        lock.withLock {
            inputs.append(input)
            concurrent += 1
            maximumConcurrent = max(maximumConcurrent, concurrent)
        }
    }
    func end(cancelled wasCancelled: Bool, _ input: EarlySortInput) {
        lock.withLock {
            concurrent -= 1
            if wasCancelled { cancelled.append(input) }
        }
    }
    var all: [EarlySortInput] { lock.withLock { inputs } }
    var allCancelled: [EarlySortInput] { lock.withLock { cancelled } }
}

private let place = UUID()

private func input(_ body: String) -> EarlySortInput {
    EarlySortInput(body: body, tagTokens: [], restaurantID: place)
}

/// A sleep that is a real, cancellable suspension but does not take real time.
private let instantSleep: EarlySortScheduler.Sleep = { _ in
    await Task.yield()
    try Task.checkCancellation()
}

@Suite("Early sort — when a preview is worth asking for")
struct EarlySortEligibilityTests {
    @Test("no place, no preview — nothing prints without one")
    func needsPlace() {
        let words = EntryComposition(plain: "The tagliatelle al ragù was unreal", spans: [])
        #expect(EarlySortInput(composition: words, restaurantID: nil) == nil)
        #expect(EarlySortInput(composition: words, restaurantID: place) != nil)
    }

    @Test("under twelve characters, only a dish-like token makes it worth asking")
    func shortWordsNeedAToken() {
        let short = EntryComposition(plain: "ragù great", spans: [])
        #expect(EarlySortInput(composition: short, restaurantID: place) == nil)

        let scored = EntryComposition(plain: "ragù 4.5", spans: [
            EntryTokenSpan(
                token: EntryToken(kind: .score(Rating(exactly: 4.5)!)), span: TextSpan(location: 5, length: 3)
            )
        ])
        #expect(EarlySortInput(composition: scored, restaurantID: place)?.body == "ragù 4.5")

        let tagged = EntryComposition(plain: "cake GF", spans: [
            EntryTokenSpan(
                token: EntryToken(kind: .tag(DietTagMark(tag: .gf, text: "GF"))), span: TextSpan(location: 5, length: 2)
            )
        ])
        let preview = EarlySortInput(composition: tagged, restaurantID: place)
        #expect(preview?.tagTokens == [TagToken(offset: 5, length: 2)])
    }

    @Test("twelve characters is enough on its own; whitespace does not count")
    func twelveCharacters() {
        let twelve = EntryComposition(plain: "123456789012", spans: [])
        let padded = EntryComposition(plain: "  12345678901  ", spans: [])
        #expect(EarlySortInput(composition: twelve, restaurantID: place) != nil)
        #expect(EarlySortInput(composition: padded, restaurantID: place) == nil)
    }
}

@Suite("Early sort — debounce, cancellation and the ration")
@MainActor
struct EarlySortSchedulerTests {
    private func scheduler(_ sent: Sent, limit: Int = 12, work: Duration = .zero) -> EarlySortScheduler {
        EarlySortScheduler(limit: limit, sleep: instantSleep) { input in
            sent.begin(input)
            do {
                if work > .zero { try await Task.sleep(for: work) }
                try Task.checkCancellation()
                sent.end(cancelled: false, input)
            } catch {
                sent.end(cancelled: true, input)
                throw error
            }
        }
    }

    @Test("a burst of typing sends one preview, for the words as they ended")
    func debounces() async {
        let sent = Sent()
        let early = scheduler(sent)
        early.edited(input("the ragù"))
        early.edited(input("the ragù 4"))
        early.edited(input("the ragù 4.5 was unreal"))
        await early.settle()
        #expect(sent.all == [input("the ragù 4.5 was unreal")])
        #expect(early.sentCount == 1)
    }

    @Test("the pause is 1.5 seconds, and it is what the scheduler sleeps for")
    func pauseLength() async {
        let slept = Mutex<[Duration]>([])
        let early = EarlySortScheduler(
            sleep: { duration in slept.withLock { $0.append(duration) } },
            send: { _ in }
        )
        early.edited(input("the ragù 4.5 was unreal"))
        await early.settle()
        #expect(slept.withLock { $0 } == [.milliseconds(1500)])
    }

    @Test("an edit cancels the preview in flight, and the next never overlaps it")
    func cancelsInFlight() async {
        let sent = Sent()
        let early = scheduler(sent, work: .seconds(30))
        early.edited(input("the ragù 4.5"))
        // Let the first one get onto the wire.
        while sent.all.isEmpty { await Task.yield() }
        early.edited(input("the ragù 4.5 was unreal"))
        // The second is slow too; cancel it by stopping, so the test does not wait 30s.
        while sent.all.count < 2 { await Task.yield() }
        early.stop(cancellingInFlight: true)
        await early.settle()
        #expect(sent.allCancelled.first == input("the ragù 4.5"))
        #expect(sent.maximumConcurrent == 1)
    }

    @Test("nothing is sent for words that are not worth a preview")
    func ineligible() async {
        let sent = Sent()
        let early = scheduler(sent)
        early.edited(input("the ragù 4.5 was unreal"))
        early.edited(nil) // the place was cleared, or the words fell below the bar
        await early.settle()
        #expect(sent.all.isEmpty)
    }

    @Test("the same words are not asked about twice")
    func noRepeat() async {
        let sent = Sent()
        let early = scheduler(sent)
        early.edited(input("the ragù 4.5 was unreal"))
        await early.settle()
        early.edited(input("the ragù 4.5 was unreal"))
        await early.settle()
        #expect(sent.all.count == 1)
    }

    @Test("it stops after twelve in a session")
    func ration() async {
        let sent = Sent()
        var counted: [Int] = []
        let early = EarlySortScheduler(
            sleep: instantSleep,
            onSent: { counted.append($0) },
            send: { sent.begin($0); sent.end(cancelled: false, $0) }
        )
        for index in 0..<20 {
            early.edited(input("the ragù was unreal, take \(index)"))
            await early.settle()
        }
        #expect(sent.all.count == 12)
        #expect(early.sentCount == 12)
        #expect(counted == Array(1...12))
    }

    @Test("Done stops anything still waiting for the pause")
    func stopCancelsPending() async {
        let sent = Sent()
        let early = EarlySortScheduler(
            sleep: { _ in try await Task.sleep(for: .seconds(30)) },
            send: { sent.begin($0) }
        )
        early.edited(input("the ragù 4.5 was unreal"))
        early.stop()
        await early.settle()
        early.edited(input("the ragù 4.5 was unreal, again"))
        await early.settle()
        #expect(sent.all.isEmpty)
    }
}

/// A tiny lock-wrapped box.
private final class Mutex<Value>: @unchecked Sendable {
    private var value: Value
    private let lock = NSLock()
    init(_ value: Value) { self.value = value }
    func withLock<Result>(_ body: (inout Value) -> Result) -> Result {
        lock.lock()
        defer { lock.unlock() }
        return body(&value)
    }
}

@Suite("The preview sort's wire")
struct PreviewSortWireTests {
    @Test("preview: true, the words, the chips and the place — no entry id")
    func body() throws {
        let place = UUID()
        let request = SupabaseEntryService.PreviewSortRequest(
            EarlySortInput(body: "cake GF 4.0", tagTokens: [TagToken(offset: 5, length: 2)], restaurantID: place)
        )
        let json = try #require(try JSONSerialization.jsonObject(with: JSONEncoder().encode(request)) as? [String: Any])
        #expect(json["preview"] as? Bool == true)
        #expect(json["body"] as? String == "cake GF 4.0")
        #expect(json["restaurant_id"] as? String == place.uuidString.lowercased())
        #expect((json["tag_tokens"] as? [[String: Int]]) == [["offset": 5, "length": 2]])
        #expect(json["entry_id"] == nil)
    }
}

/// QA round 3, note (a): the early sort is stopped only by Done or close — a full-screen cover
/// (the camera) over the composer is a pause in typing, not the end of the session.
@Suite("The early sort survives a cover")
@MainActor
struct EarlySortCoverTests {
    private let place = UUID()

    @Test("edits before and after a pause both preview; only stop() ends the session")
    func survivesPause() async {
        let sent = SentBox()
        let early = EarlySortScheduler(
            sleep: { _ in await Task.yield(); try Task.checkCancellation() },
            send: { sent.add($0.body) }
        )
        early.edited(EarlySortInput(body: "the ragù 4.5 was unreal", tagTokens: [], restaurantID: place))
        await early.settle()
        // The camera cover comes and goes; the person keeps writing.
        early.edited(EarlySortInput(body: "the ragù 4.5 was unreal, tiramisu", tagTokens: [], restaurantID: place))
        await early.settle()
        #expect(sent.all.count == 2)

        early.stop()
        early.edited(EarlySortInput(body: "after close", tagTokens: [], restaurantID: place))
        await early.settle()
        #expect(sent.all.count == 2, "closed: nothing further goes")
    }
}

private final class SentBox: @unchecked Sendable {
    private let lock = NSLock()
    private var bodies: [String] = []
    func add(_ body: String) { lock.withLock { bodies.append(body) } }
    var all: [String] { lock.withLock { bodies } }
}

/// Build 87, note 11: a settled moment previews at once, and Done's last word.
@Suite("Early sort — settled moments go at once")
@MainActor
struct EarlySortNowTests {
    private let place = UUID()

    private func input(_ body: String, place: UUID? = nil) -> EarlySortInput {
        EarlySortInput(body: body, tagTokens: [], restaurantID: place ?? self.place)
    }

    @Test("now() sends without the pause")
    func sendsAtOnce() async {
        let slept = Mutex<Int>(0)
        let sent = SentBox()
        let early = EarlySortScheduler(
            sleep: { _ in slept.withLock { $0 += 1 }; try await Task.sleep(for: .seconds(30)) },
            send: { sent.add($0.body) }
        )
        early.edited(input("the ragù 4.5"))
        early.now(input("the ragù 4.5"))
        await early.settle()
        #expect(sent.all == ["the ragù 4.5"])
        #expect(early.lastCompleted == input("the ragù 4.5"))
    }

    @Test("a preview out for the same words is left to land, and not sent twice")
    func keepsMatchingFlight() async {
        let sent = Sent()
        let gate = Mutex<Bool>(false)
        let early = EarlySortScheduler(sleep: instantSleep) { input in
            sent.begin(input)
            while gate.withLock({ $0 }) == false { try await Task.sleep(for: .milliseconds(1)) }
            sent.end(cancelled: false, input)
        }
        early.now(input("the ragù 4.5"))
        while sent.all.isEmpty { await Task.yield() }
        #expect(early.covers(input("the ragù 4.5")))
        early.edited(input("the ragù 4.5"))
        early.now(input("the ragù 4.5"))
        gate.withLock { $0 = true }
        await early.settle()
        #expect(sent.all.count == 1)
        #expect(sent.allCancelled.isEmpty)
    }

    @Test("Done's last word goes after stop() only when the key is stale")
    func doneFlushesStaleKey() async {
        let sent = SentBox()
        let early = EarlySortScheduler(sleep: instantSleep, send: { sent.add($0.body) })
        early.now(input("the ragù 4.5"))
        await early.settle()
        // Done with the same words: the server already has the plan.
        early.now(input("the ragù 4.5"))
        early.stop()
        await early.settle()
        #expect(sent.all == ["the ragù 4.5"])
        // Done with a changed place: one last preview, even though typing has stopped.
        let other = UUID()
        early.now(input("the ragù 4.5", place: other))
        await early.settle()
        #expect(sent.all.count == 2)
        #expect(early.covers(input("the ragù 4.5", place: other)))
        early.edited(input("after Done"))
        await early.settle()
        #expect(sent.all.count == 2, "stopped: typing previews no more")
    }

    @Test("words that come back after a cancelled preview are asked about again")
    func cancelledIsNotCovered() async {
        let sent = Sent()
        let early = EarlySortScheduler(sleep: instantSleep) { input in
            sent.begin(input)
            do {
                try await Task.sleep(for: .milliseconds(input.body == "a long one" ? 30_000 : 0))
                sent.end(cancelled: false, input)
            } catch {
                sent.end(cancelled: true, input)
                throw error
            }
        }
        early.now(input("a long one"))
        while sent.all.isEmpty { await Task.yield() }
        early.edited(input("short"))
        #expect(early.covers(input("a long one")) == false)
        early.now(input("short"))
        await early.settle()
        #expect(sent.all.map(\.body) == ["a long one", "short"])
        #expect(sent.maximumConcurrent == 1)
    }
}
