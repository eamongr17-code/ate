import Foundation

/// **What the receipt's wait says when it is not short** (receipt fallback, 18 Oct, approved). The
/// entry is already saved by the time any of these shows, so every line tells the person they can
/// close it: the receipt finishes in the background (the outbox, ``EntryOutbox``). Never "print" —
/// Eamon: people would think it means paper.
public enum ReceiptFallback: String, Sendable, Equatable, CaseIterable {
    /// Still sorting past ``slowAfter``.
    case slow
    /// The sort failed, or the watch gave up: "Try again" is offered beside it.
    case unfinished
    /// The words never reached the server (offline, or the insert ran past its patience).
    case offline

    /// How long the receipt's wait runs before it says it is taking longer than usual.
    public static let slowAfter: Duration = .seconds(8)

    /// The line under the receipt on the composer's sheet.
    public var message: String {
        switch self {
        case .slow:
            "Taking longer than usual. Your entry is saved, so you can close this. "
                + "Its receipt will finish in the background."
        case .unfinished:
            "Your entry is saved, so you can close this. Ate will finish its receipt in the background."
        case .offline:
            "No connection. Your entry is saved on this phone, so you can close this. "
                + "Its receipt will finish once you're back online."
        }
    }

    /// Whether "Try again" stands under the line. Offline it could not work, so it is not offered.
    public var offersRetry: Bool { self == .unfinished }

    /// The line on the entry page, under the rows still waiting for their dishes.
    public static let entryPageMessage =
        "Your entry is saved. Its receipt will finish in the background, so there's nothing to wait for."

    /// The retry's title, wherever a receipt did not finish.
    public static let retryTitle = "Try again"

    /// Which line the composer's sheet shows, if any. A receipt that has printed (or waits on its
    /// place) has nothing to explain.
    public static func on(_ phase: EntrySummaryStore.Phase, isQueued: Bool, isSlow: Bool) -> ReceiptFallback? {
        switch phase {
        case .printed, .needsPlace, .unscored:
            nil
        case .sorting:
            isQueued ? .offline : (isSlow ? .slow : nil)
        case .stalled:
            isQueued ? .offline : .unfinished
        }
    }
}
