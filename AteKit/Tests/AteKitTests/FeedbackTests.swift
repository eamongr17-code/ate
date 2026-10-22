import Foundation
import PostgREST
import Testing

@testable import AteKit

/// The bug button's report (0082): what it sends, what the server refuses, and the outbox that
/// keeps a report through a dropped connection.
@Suite("Feedback — the tester's report")
struct FeedbackTests {

    @Test("words are trimmed; empty or past 4000 never wakes the arrow")
    func bodyRules() {
        #expect(FeedbackReport(body: "  froze \n").body == "froze")
        #expect(FeedbackReport(body: "froze").canSend)
        #expect(FeedbackReport(body: " \n ").canSend == false)
        #expect(FeedbackReport(body: String(repeating: "x", count: 4000)).canSend)
        #expect(FeedbackReport(body: String(repeating: "x", count: 4001)).canSend == false)
    }

    @Test("three screenshots at most, each under the sender's folder for this report")
    func screenshotPaths() {
        let owner = UUID(uuidString: "00000000-0000-4000-8000-00000000000A")!
        let id = UUID(uuidString: "00000000-0000-4000-8000-000000008201")!
        let report = FeedbackReport(id: id, body: "x", screenshots: [Data([1]), Data([2]), Data([3]), Data([4])])
        #expect(report.screenshots.count == 3)
        #expect(report.screenshotPaths(owner: owner) == [
            "00000000-0000-4000-8000-00000000000a/00000000-0000-4000-8000-000000008201/1.jpg",
            "00000000-0000-4000-8000-00000000000a/00000000-0000-4000-8000-000000008201/2.jpg",
            "00000000-0000-4000-8000-00000000000a/00000000-0000-4000-8000-000000008201/3.jpg"
        ])
    }

    @Test("the trail keeps the last 20 screens and skips a repeat")
    func trail() {
        let trail = ScreenTrail()
        trail.visit("journal")
        trail.visit("journal")
        trail.visit("entry")
        #expect(trail.screens == ["journal", "entry"])
        for n in 0..<30 { trail.visit("s\(n)") }
        #expect(trail.screens.count == 20)
        #expect(trail.screens.first == "s10")
        #expect(trail.screens.last == "s29")
    }

    @Test("the server's refusals, read")
    func errors() {
        func of(_ code: String) -> FeedbackError {
            FeedbackError.of(PostgrestError(code: code, message: "x"))
        }
        #expect(of("54000") == .rateLimited)
        #expect(of("22023") == .badInput)
        #expect(of("42501") == .signedOut)
        #expect(of("08006") == .unreachable)
        #expect(FeedbackError.of(URLError(.notConnectedToInternet)) == .unreachable)
        #expect(FeedbackError.unreachable.isRetryable)
        #expect(FeedbackError.rateLimited.isRetryable == false)
    }

    @Test("events carry what triage and the funnel need, nothing a tester wrote")
    func events() {
        #expect(FeedbackEvents.opened().name == "feedback_opened")
        #expect(FeedbackEvents.sent(screenshots: 2, queued: true).parameters == ["screenshots": "2", "queued": "true"])
        #expect(FeedbackEvents.refused(.rateLimited).parameters == ["reason": "rate"])
    }

    @Test("offline: the report waits on disk, then goes on the next flush, once")
    func outbox() async throws {
        let service = FlakyFeedback()
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("outbox-\(UUID())")
        defer { try? FileManager.default.removeItem(at: directory) }
        let outbox = FeedbackOutbox(service: service, directory: directory)

        await service.setOnline(false)
        let report = FeedbackReport(body: "froze")
        #expect(try await outbox.send(report) == true, "queued")
        #expect(await outbox.pending == 1)

        await outbox.flush()
        #expect(await outbox.pending == 1, "still offline: still kept")

        await service.setOnline(true)
        await outbox.flush()
        #expect(await outbox.pending == 0)
        #expect(await service.sent == [report.id])
    }

    @Test("a refusal is thrown, never kept")
    func refusalIsNotKept() async throws {
        let service = FlakyFeedback()
        await service.refuse(.rateLimited)
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("outbox-\(UUID())")
        defer { try? FileManager.default.removeItem(at: directory) }
        let outbox = FeedbackOutbox(service: service, directory: directory)
        await #expect(throws: FeedbackError.rateLimited) { try await outbox.send(FeedbackReport(body: "x")) }
        #expect(await outbox.pending == 0)
    }
}

private actor FlakyFeedback: FeedbackServing {
    private(set) var sent: [UUID] = []
    private var online = true
    private var refusal: FeedbackError?

    func setOnline(_ value: Bool) { online = value }
    func refuse(_ error: FeedbackError) { refusal = error }

    func send(_ report: FeedbackReport) async throws {
        if let refusal { throw refusal }
        guard online else { throw FeedbackError.unreachable }
        sent.append(report.id)
    }
}
