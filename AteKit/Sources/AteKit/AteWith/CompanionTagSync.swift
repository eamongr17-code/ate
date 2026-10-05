import Foundation

/// **Tags, sent behind the entry and never in front of it.** The composer hands over who was added
/// and who was taken off; this sends them, and keeps anything that could not go — offline, or an
/// entry still in the outbox — on disk until it can. A refusal that cannot change (the cap, a
/// block) is dropped: a tag never blocks a post and never nags.
///
/// One operation per (entry, person): a later add or remove replaces an earlier one still waiting,
/// so a person ticked, unticked and ticked again offline is one tag, not three calls.
public actor CompanionTagSync {
    public struct Operation: Sendable, Hashable, Codable {
        public enum Kind: String, Sendable, Codable {
            case tag
            case untag
        }

        public let entryID: UUID
        public let userID: UUID
        public let kind: Kind
        /// Whose entry: only ever sent as its own author.
        public let owner: UUID?
        public var attempts: Int

        public init(entryID: UUID, userID: UUID, kind: Kind, owner: UUID?, attempts: Int = 0) {
            self.entryID = entryID
            self.userID = userID
            self.kind = kind
            self.owner = owner
            self.attempts = attempts
        }
    }

    /// After this many tries an operation is let go — an entry that never lands takes its tags with it.
    public static let maximumAttempts = 8

    private let service: any CompanionTagging
    private let storeURL: URL?
    private let owner: (@Sendable () -> UUID?)?
    private var queue: [Operation]
    private var isRunning = false

    /// - Parameter storeURL: where the queue survives a relaunch; `nil` keeps it in memory (tests).
    public init(service: any CompanionTagging, storeURL: URL? = nil, owner: (@Sendable () -> UUID?)? = nil) {
        self.service = service
        self.storeURL = storeURL
        self.owner = owner
        self.queue = storeURL
            .flatMap { try? Data(contentsOf: $0) }
            .flatMap { try? JSONDecoder().decode([Operation].self, from: $0) } ?? []
    }

    /// The app's queue file, under Application Support.
    public static var defaultStoreURL: URL {
        let support = (try? FileManager.default.url(
            for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true
        )) ?? URL.temporaryDirectory
        let root = support.appending(path: "AteWith", directoryHint: .isDirectory)
        try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root.appending(path: "tags.json", directoryHint: .notDirectory)
    }

    public var pending: [Operation] { queue }

    /// **The difference between who an entry had and who it has now**, queued and sent. Returns how
    /// many people were added — what `ate_with_tagged` counts.
    @discardableResult
    public func apply(entryID: UUID, from original: [UUID], to current: [UUID]) async -> Int {
        let before = Set(original)
        let after = Set(current)
        let added = current.filter { before.contains($0) == false }
        let removed = original.filter { after.contains($0) == false }
        guard added.isEmpty == false || removed.isEmpty == false else { return 0 }
        let who = owner?()
        for userID in removed { enqueue(Operation(entryID: entryID, userID: userID, kind: .untag, owner: who)) }
        for userID in added { enqueue(Operation(entryID: entryID, userID: userID, kind: .tag, owner: who)) }
        persist()
        await run()
        return added.count
    }

    /// Works the queue: on a post, and on every return to the app (after the entry outbox, so an
    /// entry that just landed takes its tags with it).
    public func run() async {
        guard isRunning == false, queue.isEmpty == false else { return }
        isRunning = true
        defer { isRunning = false }
        let current = owner?()
        for operation in queue {
            // Somebody else's tags wait for them.
            if let current, let mine = operation.owner, mine != current { continue }
            do {
                switch operation.kind {
                case .tag: _ = try await service.tag(entryID: operation.entryID, userID: operation.userID)
                case .untag: try await service.untag(entryID: operation.entryID, userID: operation.userID)
                }
                finish(operation)
            } catch {
                switch CompanionTagFailure.of(error) {
                case .drop: finish(operation)
                case .retry: retried(operation)
                }
            }
        }
        persist()
    }

    private func enqueue(_ operation: Operation) {
        queue.removeAll { $0.entryID == operation.entryID && $0.userID == operation.userID }
        queue.append(operation)
    }

    /// Done with — unless a newer operation for the pair replaced it while this one was in flight.
    private func finish(_ operation: Operation) {
        queue.removeAll { $0 == operation }
    }

    private func retried(_ operation: Operation) {
        guard let index = queue.firstIndex(of: operation) else { return }
        queue[index].attempts += 1
        if queue[index].attempts >= Self.maximumAttempts { queue.remove(at: index) }
    }

    private func persist() {
        guard let storeURL else { return }
        if queue.isEmpty {
            try? FileManager.default.removeItem(at: storeURL)
        } else if let data = try? JSONEncoder().encode(queue) {
            try? data.write(to: storeURL, options: .atomic)
        }
    }
}
