import Foundation

/// **The one actions sheet's rows** (pattern contract §8: "Save, Share, Report and Block live in one
/// actions sheet, the same everywhere"). The order and the asks are decided here, once, so an entry's
/// sheet and a profile's cannot drift into different answers to the same question.
public enum ActionsSheetRow: String, CaseIterable, Sendable, Identifiable {
    case save, share, report, block

    public var id: String { rawValue }

    /// The rows a sheet shows. Save is present only where there is something to save — a visit's
    /// dishes; a profile has no visit, so its sheet simply has no Save row (never a disabled one).
    public static func rows(canSave: Bool) -> [ActionsSheetRow] {
        canSave ? allCases : allCases.filter { $0 != .save }
    }

    /// Report and Block ask once, in a native confirmation dialog, before anything happens.
    public var confirms: Bool {
        switch self {
        case .report, .block: true
        case .save, .share: false
        }
    }

    /// Block carries the system's destructive role (contract §5).
    public var isDestructive: Bool { self == .block }

    /// Save, Report and Block write. Somebody browsing signed out is asked to sign in instead.
    public var isWrite: Bool { self != .share }
}
