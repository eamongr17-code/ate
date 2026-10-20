import Foundation
import Observation

/// **The signed-in person's diet** — one of it for the whole app, so the composer's lit codes, the
/// place page's chips and the Settings row all read the same thing, and a change in Settings is
/// current everywhere in the same turn.
@MainActor
@Observable
public final class DietStore {
    /// `nil` until the profile has answered — nothing is lit and no chip is drawn on a guess.
    public private(set) var choice: DietChoice?

    @ObservationIgnored private let account: any AccountServing
    @ObservationIgnored private let analytics: AnalyticsRecorder
    @ObservationIgnored private var hasLoaded = false
    /// Bumped by every write, so a slow failure never puts back a choice a later tap replaced.
    @ObservationIgnored private var writes = 0

    public init(account: any AccountServing, analytics: @escaping AnalyticsRecorder = { _ in }) {
        self.account = account
        self.analytics = analytics
    }

    /// The stored codes, `[]` until known.
    public var codes: [DietTag] { choice?.codes ?? [] }

    /// Read once per session; a read that fails is tried again next time.
    public func loadIfNeeded() async {
        guard hasLoaded == false else { return }
        hasLoaded = true
        await reload()
    }

    public func reload() async {
        do {
            choice = DietChoice(try await account.diet())
        } catch {
            hasLoaded = false
        }
    }

    /// **Settings → Diet: one tap, saved at once.** The row changes under the finger; a write the
    /// server refused puts it back and returns `false` so the page can say so. A code another pick
    /// covers does nothing.
    @discardableResult
    public func toggle(_ tag: DietTag) async -> Bool {
        let current = choice ?? DietChoice()
        guard let next = current.toggling(tag) else { return true }
        return await write(next, replacing: current, source: .settings)
    }

    /// **The first-run step**: Next writes the picks. Returns `false` when it could not.
    @discardableResult
    public func save(_ next: DietChoice, source: DietEvents.Source) async -> Bool {
        await write(next, replacing: choice, source: source)
    }

    /// "None of these": nothing is written, only counted.
    public func declined() {
        analytics(DietEvents.set(source: .onboarding, codes: []))
    }

    /// Writes go one after another, each the whole set: two quick taps can never land out of order
    /// and leave the server holding the first.
    private func write(_ next: DietChoice, replacing previous: DietChoice?, source: DietEvents.Source) async -> Bool {
        writes += 1
        let ticket = writes
        choice = next
        let before = lastWrite
        let account = self.account
        let codes = next.codes
        let write = Task<Bool, Never> {
            _ = await before?.value
            do {
                try await account.setDiet(codes)
                return true
            } catch {
                return false
            }
        }
        lastWrite = write
        let landed = await write.value
        if landed {
            analytics(DietEvents.set(source: source, codes: codes))
        } else if ticket == writes {
            choice = previous
        }
        return landed
    }

    @ObservationIgnored private var lastWrite: Task<Bool, Never>?
}
