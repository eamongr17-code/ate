import Foundation
import PostgREST
import Supabase

/// **Tester feedback** (`design/rebuild/feedback.html`): what the bug button's sheet sends.
///
/// One report: the words, up to three screenshots (JPEG), and what the server can't know: the build,
/// the device and the last screens visited. The id is made here, so a retry is the same report
/// (`send_feedback` is idempotent on it, 0082).
public struct FeedbackReport: Sendable, Equatable, Codable, Identifiable {
    public let id: UUID
    public let body: String
    public let screenshots: [Data]
    public let build: String?
    public let device: String?
    public let osVersion: String?
    public let screens: [String]
    public let createdAt: Date

    public init(
        id: UUID = UUID(), body: String, screenshots: [Data] = [], build: String? = nil,
        device: String? = nil, osVersion: String? = nil, screens: [String] = [], createdAt: Date = Date()
    ) {
        self.id = id
        self.body = body.trimmingCharacters(in: .whitespacesAndNewlines)
        self.screenshots = Array(screenshots.prefix(FeedbackRules.screenshotCap))
        self.build = build
        self.device = device
        self.osVersion = osVersion
        self.screens = Array(screens.suffix(FeedbackRules.screenTrailCap))
        self.createdAt = createdAt
    }

    /// The send arrow wakes on the first letter and sleeps past the cap.
    public var canSend: Bool { FeedbackRules.canSend(body) }

    /// `<you>/<report>/<n>.jpg` — the only paths 0082's policy and `send_feedback` accept.
    public func screenshotPaths(owner: UUID) -> [String] {
        screenshots.indices.map { "\(owner.uuidString.lowercased())/\(id.uuidString.lowercased())/\($0 + 1).jpg" }
    }
}

/// The server's rules, said once on the client (0082).
public enum FeedbackRules {
    public static let bodyCap = 4000
    public static let screenshotCap = 3
    public static let screenTrailCap = 20

    public static func canSend(_ body: String) -> Bool {
        let trimmed = body.trimmingCharacters(in: .whitespacesAndNewlines)
        return !trimmed.isEmpty && trimmed.count <= bodyCap
    }
}

public enum FeedbackError: Error, Equatable, Sendable {
    case signedOut
    /// 10 an hour or 30 a day: the one refusal the sheet explains.
    case rateLimited
    case badInput
    /// Offline or the server failed: the report waits in the outbox.
    case unreachable

    public static func of(_ error: any Error) -> FeedbackError {
        if let error = error as? FeedbackError { return error }
        if let postgrest = error as? PostgrestError {
            switch postgrest.code {
            case "42501": return .signedOut
            case "54000": return .rateLimited
            case "22023", "23505": return .badInput
            default: return .unreachable
            }
        }
        if (error as? AteAPIError) == .notAuthenticated { return .signedOut }
        return .unreachable
    }

    /// Worth keeping for a later try: nothing about the report itself was refused.
    public var isRetryable: Bool { self == .unreachable }
}

public protocol FeedbackServing: Sendable {
    func send(_ report: FeedbackReport) async throws
}

/// The last screens visited, oldest first — what triage reads to know where a bug happened.
/// Names are route names, never content (no dish names, no handles).
public final class ScreenTrail: @unchecked Sendable {
    private let lock = NSLock()
    private var names: [String] = []

    public init() {}

    public func visit(_ name: String) {
        lock.lock()
        defer { lock.unlock() }
        guard names.last != name else { return }
        names.append(name)
        let cap = FeedbackRules.screenTrailCap
        if names.count > cap { names.removeFirst(names.count - cap) }
    }

    public var screens: [String] {
        lock.lock()
        defer { lock.unlock() }
        return names
    }
}

public enum FeedbackEvents {
    /// The bug button was tapped and the sheet rose.
    public static func opened() -> AnalyticsEvent {
        AnalyticsEvent(name: "feedback_opened")
    }

    /// The arrow was tapped. `queued` when it is waiting in the outbox for a connection.
    public static func sent(screenshots: Int, queued: Bool) -> AnalyticsEvent {
        AnalyticsEvent(name: "feedback_sent", parameters: [
            "screenshots": String(screenshots), "queued": String(queued)
        ])
    }

    /// The server refused it: `reason` is `rate` or `input`.
    public static func refused(_ error: FeedbackError) -> AnalyticsEvent {
        AnalyticsEvent(name: "feedback_refused", parameters: ["reason": error == .rateLimited ? "rate" : "input"])
    }
}

/// **The live client**: screenshots into the private bucket, then `send_feedback`.
public struct FeedbackClient: FeedbackServing {
    private let api: AteAPIClient

    public init(api: AteAPIClient) {
        self.api = api
    }

    public func send(_ report: FeedbackReport) async throws {
        guard report.canSend else { throw FeedbackError.badInput }
        do {
            let owner = try await api.requireCurrentUserID()
            let paths = report.screenshotPaths(owner: owner)
            let storage = api.supabase.storage.from("feedback-screenshots")
            for (path, data) in zip(paths, report.screenshots) {
                do {
                    let options = FileOptions(contentType: "image/jpeg", upsert: false)
                    _ = try await storage.upload(path, data: data, options: options)
                } catch let error as StorageError where error.statusCode == "409" || error.message.contains("exists") {
                    // already uploaded by an earlier try of this same report
                }
            }
            _ = try await api.supabase.rpc("send_feedback", params: [
                "p_id": AnyJSON.string(report.id.uuidString.lowercased()),
                "p_body": .string(report.body),
                "p_screenshots": .array(paths.map { .string($0) }),
                "p_build": report.build.map { .string($0) } ?? .null,
                "p_device": report.device.map { .string($0) } ?? .null,
                "p_os_version": report.osVersion.map { .string($0) } ?? .null,
                "p_screens": .array(report.screens.map { .string($0) })
            ]).execute()
        } catch {
            throw FeedbackError.of(error)
        }
    }
}

/// **The outbox**: a report that could not go now is kept on disk and sent on the next flush (the
/// next send, or the app coming back to the foreground). One JSON file per report.
public actor FeedbackOutbox {
    private let service: any FeedbackServing
    private let directory: URL

    public init(service: any FeedbackServing, directory: URL) {
        self.service = service
        self.directory = directory
    }

    /// `Application Support/feedback-outbox`.
    public static func defaultDirectory() -> URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return base.appendingPathComponent("feedback-outbox", isDirectory: true)
    }

    /// Send now; on a dropped connection keep it and answer `true` (queued). A refusal is thrown.
    @discardableResult
    public func send(_ report: FeedbackReport) async throws -> Bool {
        do {
            try await service.send(report)
            await flush()
            return false
        } catch let error as FeedbackError where error.isRetryable {
            try keep(report)
            return true
        }
    }

    /// Try every kept report once, oldest first. Sent or refused, it leaves the outbox; unreachable stays.
    public func flush() async {
        for (url, report) in kept() {
            do {
                try await service.send(report)
                try? FileManager.default.removeItem(at: url)
            } catch let error as FeedbackError where error.isRetryable {
                return
            } catch {
                try? FileManager.default.removeItem(at: url)
            }
        }
    }

    public var pending: Int { kept().count }

    private func keep(_ report: FeedbackReport) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let data = try JSONEncoder().encode(report)
        try data.write(to: directory.appendingPathComponent("\(report.id.uuidString).json"), options: .atomic)
    }

    private func kept() -> [(URL, FeedbackReport)] {
        let urls = (try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)) ?? []
        return urls.filter { $0.pathExtension == "json" }
            .compactMap { url in
                guard let data = try? Data(contentsOf: url),
                      let report = try? JSONDecoder().decode(FeedbackReport.self, from: data) else { return nil }
                return (url, report)
            }
            .sorted { $0.1.createdAt < $1.1.createdAt }
    }
}
