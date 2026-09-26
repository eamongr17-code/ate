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
