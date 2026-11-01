import Foundation
import Synchronization
import Testing
@testable import AteKit

@Suite("ErrorReporting — handled faults reach Sentry, the network and the person don't", .serialized)
struct ErrorReportingTests {
    private struct ServerFault: Error {}
    private struct OtherFault: Error {}

    /// Records only this suite's places: other suites' stores report through the same global sink.
    private final class Recorder: Sendable {
        private let places = Mutex<[String]>([])
        var sent: [String] { places.withLock { $0 } }
        func install() {
            ErrorReporting.install { [self] _, place in
                guard place.hasPrefix("test.") else { return }
                places.withLock { $0.append(place) }
            }
        }
    }

    @Test("connection, cancel, signed-out and gone are never sent")
    func skipsNonFaults() {
        let quiet: [any Error] = [
            URLError(.notConnectedToInternet), URLError(.timedOut), URLError(.networkConnectionLost),
            URLError(.cannotFindHost), URLError(.cancelled), CancellationError(),
            AteAPIError.notAuthenticated, AteAPIError.notFound(table: "entries", id: UUID()),
        ]
        for error in quiet { #expect(ErrorReporting.isWorthReporting(error) == false, "\(error)") }
        #expect(ErrorReporting.isWorthReporting(ServerFault()))
        #expect(ErrorReporting.isWorthReporting(URLError(.badServerResponse)))
        #expect(ErrorReporting.isWorthReporting(DecodingError.dataCorrupted(.init(codingPath: [], debugDescription: "x"))))
    }

    @Test("one report per place and error type per quiet period")
    func throttles() {
        let recorder = Recorder()
        recorder.install()
        defer { ErrorReporting.install(nil) }
        let t0 = Date(timeIntervalSince1970: 1_000_000)

        ErrorReporting.report(ServerFault(), where: "test.a", now: t0)
        ErrorReporting.report(ServerFault(), where: "test.a", now: t0.addingTimeInterval(60))
        ErrorReporting.report(OtherFault(), where: "test.a", now: t0.addingTimeInterval(60))
        ErrorReporting.report(ServerFault(), where: "test.b", now: t0.addingTimeInterval(60))
        ErrorReporting.report(URLError(.notConnectedToInternet), where: "test.c", now: t0)
        ErrorReporting.report(ServerFault(), where: "test.a", now: t0.addingTimeInterval(ErrorReporting.quietPeriod + 1))

        #expect(recorder.sent == ["test.a", "test.a", "test.b", "test.a"])
    }

    @Test("no sink installed: reporting is a no-op")
    func noSink() {
        ErrorReporting.install(nil)
        ErrorReporting.report(ServerFault(), where: "test.none")
    }
}
