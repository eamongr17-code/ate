import SwiftUI

/// One answer in the city picker: a city, Everywhere, or the Feed's Near me.
struct AteCityOption: Identifiable, Hashable {
    /// The slug, or a reserved word (`@everywhere`, `@near-me`) — whatever the caller keys on.
    let id: String
    let title: String
    /// Radio rows only: Near me's resolved city, a city's region.
    var subtitle: String?
    /// Pills only: Near me's mark.
    var icon: AteIcon?

    static let everywhereID = "@everywhere"
    static let everywhere = AteCityOption(id: everywhereID, title: "Everywhere")
}

/// **The one city picker** (round 5) — the filter sheet's City section and the Feed's location
/// sheet are the same control, so a city is picked the same way everywhere (AGENTS.md rule 2).
///
/// Two drawings are on the table: **rows** (the sheets' radio rows, with a subtitle) and **pills**
/// (a wrap of pills, the chosen one ink). Picking never closes anything by itself — the caller
/// decides (the filter sheet waits for Done; the Feed's sheet closes on the pick).
struct AteCityPicker: View {
    enum Style {
        case rows, pills
    }

    let options: [AteCityOption]
    let selection: String
    var style: Style = .rows
    var title: String? = "City"
    let onPick: (AteCityOption) -> Void

    var body: some View {
        if let title {
            AteFilterSection(title: title, scrolls: false) { choices }
        } else {
            choices
        }
    }

    @ViewBuilder
    private var choices: some View {
        switch style {
        case .rows:
            VStack(spacing: 0) {
                ForEach(options) { option in
                    AteRadioRow(title: option.title, subtitle: option.subtitle, isSelected: option.id == selection) {
                        onPick(option)
                    }
                }
            }
        case .pills:
            AteFlow(spacing: AteMetrics.snug) {
                ForEach(options) { option in
                    AteFilterChoice(title: option.title, isOn: option.id == selection, icon: option.icon) {
                        onPick(option)
                    }
                    .accessibilityIdentifier("row.\(option.title)")
                }
            }
        }
    }
}
