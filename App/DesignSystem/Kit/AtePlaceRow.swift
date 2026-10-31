import SwiftUI

/// **A place row's measures** — shared by ``AtePersonRow`` and the Ate-with rows, which keep the
/// Search place row's 62pt height. (The place row view itself went unused and was removed.)
enum AtePlaceRowMetrics {
    /// `min-height:62px`.
    static let height: CGFloat = 62
}
