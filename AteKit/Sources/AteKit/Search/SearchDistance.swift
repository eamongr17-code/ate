import Foundation

/// Renders `distance_meters` for a picker row.
///
/// The rule from §11.1 is small but load-bearing: *"render nothing when absent, never `0 km`"*.
/// A naive `(m / 1000).formatted(.number.precision(.fractionLength(1))) + " km"` — which is what the
/// legacy `formatDistanceKm` did — prints `"0.0 km"` for anything under 50 m, and every restaurant
/// you are actually standing in is under 50 m. So sub-kilometre distances render in metres.
public enum SearchDistance {
    /// Below this, render metres; at or above, render kilometres to 1dp. 995 rather than 1000 so the
    /// two branches stay monotonic: at 950 the km branch would print "0.9 km" (1dp, round-half-even
    /// on a binary 0.95) *below* the metre branch's "950 m".
    static let metresCeiling: Double = 995
    /// Metres are rounded to this step — GPS is not accurate to the metre and a jittering row is noise.
    static let metresStep: Double = 10

    /// `nil` when there is nothing honest to show (absent, negative, or non-finite).
    public static func string(meters: Double?, locale: Locale = .autoupdatingCurrent) -> String? {
        guard let meters, meters.isFinite, meters >= 0 else { return nil }

        if meters < metresCeiling {
            let rounded = max(metresStep, (meters / metresStep).rounded() * metresStep)
            return "\(Int(rounded).formatted(.number.locale(locale))) m"
        }

        let kilometres = meters / 1000
        return "\(kilometres.formatted(.number.precision(.fractionLength(1)).locale(locale))) km"
    }
}
