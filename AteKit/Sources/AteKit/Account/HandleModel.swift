import Foundation

/// **`Handle`** — what the field knows, and when it goes and asks.
///
/// Two behaviours, both of which the screen is unusable without:
///
/// 1. **The field can only hold a legal handle.** Every keystroke is sanitised (``HandleName``), so
///    the artboard's single green check really is the only state the screen needs: there is no
///    error copy to write, and design rule 1 forbids one anyway.
/// 2. **One check per pause, never one per keystroke.** `handle_available` is a round trip; typing
///    "eamon" would fire five, and the answers can land out of order — which is how a field ends up
///    green on a taken handle. So a burst is debounced to its last value, the previous check is
///    cancelled, and a reply is ignored unless it is still about what is in the field.
///
/// Editing from Settings is the same screen: ``current`` is your own handle, and typing it back
/// unchanged is `available`, because it is yours and no round trip can say otherwise.
@MainActor
@Observable
public final class HandleModel {
    /// What is in the field, always sanitised. Setting it starts the clock.
    public var typed: String = "" {
        didSet {
            guard typed != oldValue else { return }
            scheduleCheck()
        }
    }

    public private(set) var status: HandleStatus = .empty
    /// True while Continue is writing.
    public private(set) var isSaving = false
    /// Set when the write itself was refused — the one failure the person has to be told about,
    /// because their tap did nothing.
    public private(set) var didFailToSave = false

    /// The handle already on the profile, when this screen is an edit rather than a first run.
    public let current: String?
    /// First run has no way back and a Continue that leaves the screen for good; an edit returns.
    public let isFirstRun: Bool

    @ObservationIgnored private let account: any AccountServing
    @ObservationIgnored private let analytics: AnalyticsRecorder
    @ObservationIgnored private let debounce: Duration
    @ObservationIgnored private var check: Task<Void, Never>?

    /// 350ms: long enough that a word typed at speed is one round trip, short enough that the check
    /// has landed before a thumb reaches Continue.
    public static let defaultDebounce = Duration.milliseconds(350)

    public init(
        account: any AccountServing,
        analytics: @escaping AnalyticsRecorder = { _ in },
        current: String? = nil,
        isFirstRun: Bool,
        debounce: Duration = HandleModel.defaultDebounce
    ) {
        self.account = account
        self.analytics = analytics
        self.current = current.map(HandleName.sanitise)
        self.isFirstRun = isFirstRun
        self.debounce = debounce
        if let current = self.current, current.isEmpty == false {
            self.typed = current
            self.status = .available
        }
    }

    /// The whole field, `@` and all — the `@` is the app's, never the column's.
    public var display: String { HandleName.display(typed) }

    /// Continue.
    public var canContinue: Bool { status.allowsContinue && isSaving == false }

    /// What the field should hold after a keystroke. The view hands over whatever the text field
    /// produced, including the `@` it draws, and gets back what is legal.
    public func type(_ text: String) {
        typed = HandleName.sanitise(text)
    }

    /// Continue: writes `profiles.username`. Returns the handle that was written, or nil if the
    /// server refused — the screen stays put on a refusal rather than pretending.
    @discardableResult
    public func save() async -> String? {
        guard canContinue, HandleName.isWellFormed(typed) else { return nil }
        // Unchanged is already done. An UPDATE to the same value would succeed, but it would also
        // mean the edit screen could not be left without a round trip.
        if let current, current == typed {
            // …but on first run, keeping the handle the account was made with IS picking it, and
            // the funnel step has to count it or everyone who liked their suggestion reads as lost.
            if isFirstRun { analytics(AccountEvents.handleSet(isFirstRun: true)) }
            return typed
        }
        isSaving = true
        didFailToSave = false
        defer { isSaving = false }
        do {
            try await account.setHandle(typed)
            analytics(AccountEvents.handleSet(isFirstRun: isFirstRun))
            return typed
        } catch {
            didFailToSave = true
            // The one case worth re-reading: the unique index refused because somebody took it
            // between the check and the write.
            status = .taken
            return nil
        }
    }

    // MARK: - The check

    private func scheduleCheck() {
        check?.cancel()
        didFailToSave = false
        let handle = typed
        guard handle.isEmpty == false else {
            status = .empty
            return
        }
        guard HandleName.isWellFormed(handle) else {
            status = .malformed
            return
        }
        // Your own handle is yours. No round trip can improve on that answer, and asking would get
        // `false` back — `handle_available` sees the row you already own.
        if let current, current == handle {
            status = .available
            return
        }
        status = .checking
        check = Task { [weak self, debounce] in
            try? await Task.sleep(for: debounce)
            guard Task.isCancelled == false, let self else { return }
            await self.ask(handle)
        }
    }

    private func ask(_ handle: String) async {
        let isFree: Bool
        do {
            isFree = try await account.isHandleAvailable(handle)
        } catch {
            guard typed == handle else { return }
            status = .unknown
            return
        }
        // The field moved on while the answer was in the air. A late reply about a handle nobody is
        // looking at any more must not repaint the check.
        guard typed == handle else { return }
        status = isFree ? .available : .taken
    }
}
