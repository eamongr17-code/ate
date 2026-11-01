import Foundation
import Supabase
import Synchronization

/// **Where photos are kept: Supabase Storage, or Cloudflare R2 once the server says so (0103).**
///
/// The server holds one switch, `photo_storage_config() → {base}`. `nil`: uploads go to Supabase
/// Storage, exactly as before. A base (`https://photos.<domain>/`): uploads go to the photos Worker
/// there, which checks the session with Supabase Auth, keeps each account inside its own folder and
/// takes only JPEG/PNG under the bucket's size limit. The app never holds an R2 credential.
///
/// Paths are the same in both places (`<bucket>/<uid>/<file>`), so a delete names the same path to
/// both: Supabase keeps a copy of everything that moved until it is cleared, and an older build may
/// still have uploaded there.
extension AteAPIClient {
    /// Uploads `data` to `bucket/path` and answers the public URL the database should store.
    /// Overwrites: every path is deterministic, so a retry is the same object.
    public func uploadPhoto(bucket: String, path: String, data: Data, contentType: String) async throws -> String {
        if let base = await photoBase() {
            return try await PhotoWorker(base: base, token: session().accessToken)
                .upload(bucket: bucket, path: path, data: data, contentType: contentType)
        }
        let storage = supabase.storage.from(bucket)
        _ = try await storage.upload(path, data: data, options: FileOptions(contentType: contentType, upsert: true))
        return try storage.getPublicURL(path: path).absoluteString
    }

    /// Removes your files at `paths` inside `bucket`, wherever they are. A path that is not there
    /// costs nothing. Throws only when neither store took the request.
    public func removePhotos(bucket: String, paths: [String]) async throws {
        guard paths.isEmpty == false else { return }
        var failure: (any Error)?
        do {
            _ = try await supabase.storage.from(bucket).remove(paths: paths)
        } catch {
            failure = error
        }
        if let base = await photoBase() {
            let worker = try await PhotoWorker(base: base, token: session().accessToken)
            // the Worker takes 100 keys a call
            for start in stride(from: 0, to: paths.count, by: 100) {
                let chunk = paths[start..<min(paths.count, start + 100)].map { "\(bucket)/\($0)" }
                try await worker.remove(keys: chunk)
            }
            return
        }
        if let failure { throw failure }
    }

    /// The server's switch, asked again at most every ten minutes. A failed ask keeps the last
    /// answer this phone heard (before any answer: Supabase).
    func photoBase() async -> URL? {
        if let fresh = PhotoHosts.freshAnswer() { return fresh.base }
        await refreshPhotoStorage()
        return PhotoHosts.lastBase
    }

    /// Asks the server where photos live now. Called at launch, and when a photo names a host the
    /// app has not met (``PhotoHosts/learn(host:)``).
    public func refreshPhotoStorage() async {
        struct Config: Decodable, Sendable { let base: String? }
        guard let config: Config = try? await rpc("photo_storage_config") else { return }
        PhotoHosts.record(base: config.base.flatMap(PhotoHosts.validBase))
    }
}

/// The photos Worker's write API (cloudflare/photos). Every call carries the session's access token.
struct PhotoWorker: Sendable {
    let base: URL
    let token: String
    var session: URLSession = .shared

    func upload(bucket: String, path: String, data: Data, contentType: String) async throws -> String {
        var request = URLRequest(url: base.appending(path: "v1/object/\(bucket)/\(path)"))
        request.httpMethod = "PUT"
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue(contentType, forHTTPHeaderField: "Content-Type")
        request.timeoutInterval = 60
        let (body, response) = try await session.upload(for: request, from: data)
        try PhotoStoreError.check(response)
        struct Answer: Decodable { let url: String }
        return try JSONDecoder().decode(Answer.self, from: body).url
    }

    func remove(keys: [String]) async throws {
        var request = URLRequest(url: base.appending(path: "v1/delete"))
        request.httpMethod = "POST"
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONEncoder().encode(["keys": keys])
        let (_, response) = try await session.data(for: request)
        try PhotoStoreError.check(response)
    }
}

/// The photos Worker said no. ``EntryWriteFailure`` reads ``status`` like any other HTTP answer:
/// a 5xx or 429 is retried, a refusal is not.
public struct PhotoStoreError: Error, Sendable, Equatable {
    public let status: Int

    static func check(_ response: URLResponse) throws {
        guard let http = response as? HTTPURLResponse else { throw PhotoStoreError(status: 0) }
        guard (200..<300).contains(http.statusCode) else { throw PhotoStoreError(status: http.statusCode) }
    }
}

/// **Which hosts a photo may be drawn from.** Supabase's, always (checked by the caller); the photos
/// Worker's once the server has named it. The last base is kept on the phone, so a cold start draws
/// R2 photos before the first answer comes back.
public enum PhotoHosts {
    /// The server's last answer: where photos go, and when it was heard.
    struct Answer: Sendable {
        let base: URL?
        let heard: Date
    }

    private struct State: Sendable {
        var base: URL?
        var answer: Answer?
    }

    private static let key = "ate.photos.base"
    private static let lifetime: TimeInterval = 600
    private static let state = Mutex<State>(State(
        base: UserDefaults.standard.string(forKey: key).flatMap(validBase), answer: nil
    ))
    private static let refresher = Mutex<(@Sendable () async -> Void)?>(nil)

    /// Wires the server ask in (``AteAPIClient/refreshPhotoStorage()``); the live app does at launch.
    public static func setRefresher(_ refresh: @escaping @Sendable () async -> Void) {
        refresher.withLock { $0 = refresh }
    }

    /// `https://<host>/`, https only, nothing after the slash; anything else is not a base.
    static func validBase(_ string: String) -> URL? {
        guard let url = URL(string: string), url.scheme == "https", let host = url.host(), host.contains("."),
              url.path() == "/", url.query() == nil, url.fragment() == nil else { return nil }
        return url
    }

    static func record(base: URL?, at now: Date = Date()) {
        state.withLock {
            $0.base = base
            $0.answer = Answer(base: base, heard: now)
        }
        UserDefaults.standard.set(base?.absoluteString, forKey: key)
    }

    /// The server's answer if it was heard within ``lifetime``, else nil (ask again).
    static func freshAnswer(now: Date = Date()) -> Answer? {
        state.withLock { current in
            guard let answer = current.answer, now.timeIntervalSince(answer.heard) < lifetime else { return nil }
            return answer
        }
    }

    /// The last base this phone heard, kept across launches. `nil` = Supabase.
    static var lastBase: URL? { state.withLock { $0.base } }

    /// Whether `host` is the photos Worker's.
    public static func isPhotoHost(_ host: String) -> Bool {
        guard let known = lastBase?.host()?.lowercased() else { return false }
        return known == host.lowercased()
    }

    /// Whether to fetch `url`: `known` (the caller's own host check passed), or an https photo on a
    /// host the server turns out to name once asked (the first launch after photos moved, or a new
    /// domain).
    public static func allows(_ url: URL, known: Bool) async -> Bool {
        if known { return true }
        guard url.scheme == "https", let host = url.host() else { return false }
        return await learn(host: host)
    }

    /// A photo names a host the app has not met: ask the server, then answer again. One ask at a
    /// time however many tiles wait on it, and none within 30 seconds of the last.
    public static func learn(host: String, now: Date = Date()) async -> Bool {
        if isPhotoHost(host) { return true }
        guard let refresh = refresher.withLock({ $0 }) else { return false }
        let ask = learning.withLock { current -> Task<Void, Never>? in
            if let task = current.task { return task }
            if let last = current.last, now.timeIntervalSince(last) < 30 { return nil }
            let task = Task { await refresh() }
            current = (task, now)
            return task
        }
        guard let ask else { return false }
        await ask.value
        learning.withLock { current in
            if current.task == ask { current.task = nil }
        }
        return isPhotoHost(host)
    }

    private static let learning = Mutex<(task: Task<Void, Never>?, last: Date?)>((nil, nil))
}
