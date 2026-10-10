import AteKit
import SwiftUI

/// What a receipt says. Data only — no formatting decisions, no view types — so the same value can be
/// built from a live entry, from a preview fixture, or from a share export.
struct AteReceipt: Equatable, Identifiable {
    struct Item: Equatable, Identifiable {
        let id: UUID
        var name: String
        /// `nil` is a dish that was named but not scored. Design rule 7: its score column is empty —
        /// no star, no zero.
        ///
        /// There is deliberately no note here. **A receipt prints dish rows and scores only — never a
        /// per-dish quote under a line** (Eamon, 2026-09-26: Share, Summary, statement, anywhere), so
        /// the model cannot carry one for a view to print.
        var score: Rating?
        /// The dish itself — what a save saves, and where a line links to. Absent on a fixture that
        /// has no dish behind it.
        var dishID: UUID?
        /// The viewer's own bookmark. Only ever drawn on somebody else's entry: your own dishes are
        /// written, not saved.
        var isSaved: Bool

        init(
            id: UUID = UUID(),
            name: String,
            score: Rating? = nil,
            dishID: UUID? = nil,
            isSaved: Bool = false
        ) {
            self.id = id
            self.name = name
            self.score = score
            self.dishID = dishID
            self.isSaved = isSaved
        }
    }

    let id: UUID
    var place: String
    var placeID: UUID?
    var address: String?
    /// The suburb — the one safe short label for a place. The share sticker prints it beside the
    /// name where the receipt prints the street.
    var locality: String?
    var items: [Item]
    /// The entry's number in the person's own sequence — `#0142`. Printed, not computed here.
    var orderNumber: Int
    var date: Date
    var handle: String
    /// "Ate with": the handles the signature line adds — "@eamon with @jess", "with @jess +1"
    /// (`ate-with.html` 1e). Empty prints the signature alone.
    var companions: [String] = []

    init(
        id: UUID = UUID(),
        place: String,
        placeID: UUID? = nil,
        address: String? = nil,
        locality: String? = nil,
        items: [Item],
        orderNumber: Int,
        date: Date,
        handle: String,
        companions: [String] = []
    ) {
        self.id = id
        self.place = place
        self.placeID = placeID
        self.address = address
        self.locality = locality
        self.items = items
        self.orderNumber = orderNumber
        self.date = date
        self.handle = handle
        self.companions = companions
    }

    /// How a receipt writes its date: "Sat 19 Sep 2026". The ORDER is the design's and is fixed; the
    /// weekday and month NAMES still come from the reader's locale.
    static let dateFormat = Date.VerbatimFormatStyle(
        format: """
\(weekday: .abbreviated) \(day: .defaultDigits) \(month: .abbreviated) \(year: .defaultDigits)
""",
        locale: .autoupdatingCurrent,
        timeZone: .autoupdatingCurrent,
        calendar: .autoupdatingCurrent
    )

    /// The mean of the dishes that were actually scored. Unscored dishes are not zeros and are not
    /// counted.
    var average: Double? {
        let scores = items.compactMap(\.score?.value)
        guard scores.isEmpty == false else { return nil }
        return scores.reduce(0, +) / Double(scores.count)
    }
}

// Fixtures are `DEBUG || BETA`, not `DEBUG`: the debug gallery ships to TestFlight, and a component
// that can't be shown there is a component nobody can judge. Previews stay `DEBUG`.
#if DEBUG || BETA
extension AteReceipt {
    /// The prototype's own receipt, so a preview and the design can be held side by side.
    static let preview = AteReceipt(
        place: "Tipo 00",
        address: "361 Little Bourke St",
        locality: "Melbourne",
        items: [
            Item(name: "Tagliatelle al ragù", score: Rating(rounding: 4.5)),
            Item(name: "Tiramisu", score: Rating(rounding: 3)),
            Item(name: "Prawn spaghetti")
        ],
        orderNumber: 142,
        date: Date(timeIntervalSince1970: 1_789_000_000),
        handle: "eamon"
    )

    /// A receipt that cannot print until a place is picked.
    static let previewPlaceless = AteReceipt(
        place: "",
        items: [],
        orderNumber: 144,
        date: Date(timeIntervalSince1970: 1_789_300_000),
        handle: "eamon"
    )

    static let previewSingle = AteReceipt(
        place: "Butchers Diner",
        address: "224 Little Bourke St",
        items: [Item(name: "Cheeseburger", score: Rating(rounding: 4.5))],
        orderNumber: 143,
        date: Date(timeIntervalSince1970: 1_789_200_000),
        handle: "eamon"
    )
}
#endif
