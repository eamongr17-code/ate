import AteKit
import SwiftUI

/// **The entry page's dish rows** — what `EntryHier.dc.html` leads the page with, built from the
/// card's own row (``SlipDishRow``) so a dish reads the same on the page as it did in the list that
/// opened it. There is no bill here any more: the dishes are the page's first band, the words and
/// photos follow, and the place is a pin line at the foot.
///
/// **A row does two things and the open question is which one owns the tap.** The dish has a page,
/// and it also has ``DishSheet`` (`entry_corrected`, `part=dish`) — the structure is Ate's guess and
/// the person has the last word on it. `tapOpensDetail` decides: on, a tap opens the page and a long
/// press corrects; off, the other way round. Somebody else's entry has no correction, so its rows
/// always open the dish and carry a bookmark each.
struct EntryDishRows: View {
    let dishes: [AteSlip.Dish]
    /// The dish's page — the same page the feed's slips and the place's menu open.
    var onOpen: ((AteSlip.Dish) -> Void)?
    /// The correction — `DishSheet`, on your own entry only.
    var onCorrect: ((AteSlip.Dish) -> Void)?
    /// Present on somebody else's entry: every row is a dish you can put on your own shelf.
    var onSave: ((AteSlip.Dish) -> Void)?
    var tapOpensDetail = true

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(Array(dishes.enumerated()), id: \.element.id) { index, dish in
                VStack(spacing: 0) {
                    // `.dish+.dish{border-top:1px solid var(--hair)}`.
                    if index > 0 { AteHairline() }
                    row(dish)
                }
            }
        }
        // `.contain` so the rows are one queryable element for a drive.
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("entry.dishes")
    }

    private func row(_ dish: AteSlip.Dish) -> some View {
        let open = onOpen.map { open in { open(dish) } }
        let correct = onCorrect.map { correct in { correct(dish) } }
        // With no correction to offer (somebody else's entry) the page always owns the tap.
        let primary = tapOpensDetail ? (open ?? correct) : (correct ?? open)
        let secondary: (title: String, action: () -> Void)? = if tapOpensDetail {
            correct.map { (title: "Change the dish", action: $0) }
        } else {
            open.map { (title: "Open the dish", action: $0) }
        }
        return SlipDishRow(
            dish: dish,
            action: primary,
            secondary: primary == nil ? nil : secondary,
            onSave: onSave.map { save in { save(dish) } },
            identifier: "entry"
        )
    }
}

/// **The dish rows before they have arrived**, and when they could not.
///
/// `docs/DESIGN.md` builds these from the existing vocabulary ("not-yet-sorted entry: words show,
/// the bill absent"): the shape of two dish rows parted by a hairline, the way a slip's skeleton
/// draws them — no label, no spinner, no apology. When the sort failed, one ink pill underneath.
struct EntryPendingDishes: View {
    let isFailed: Bool
    let onRetry: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: AteMetrics.regular) {
            VStack(alignment: .leading, spacing: 0) {
                ForEach(0..<2, id: \.self) { row in
                    VStack(spacing: 0) {
                        if row > 0 { AteHairline() }
                        HStack {
                            bar(width: row == 0 ? 168 : 120, height: 18)
                            Spacer(minLength: 0)
                            bar(width: 56, height: 20)
                        }
                        .frame(minHeight: AteMetrics.hit)
                    }
                }
            }
            .accessibilityHidden(true)
            if isFailed {
                AteButton(title: "Print it again", height: 52, action: onRetry)
                    .padding(.top, AteMetrics.tight)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("entry.pending")
    }

    private func bar(width: CGFloat, height: CGFloat) -> some View {
        RoundedRectangle(cornerRadius: height / 2, style: .continuous)
            .fill(AtePalette.slip.hairline)
            .frame(width: width, height: height)
    }
}

/// **The place line** at the foot of the page (`EntryHier`): muted pin, the place, its suburb, and the
/// day at the right — `gap:6px; min-height:44px`, ruled above. The place truncates first; the suburb
/// and the date never wrap.
struct EntryPlaceLine<Extra: View>: View {
    let place: String?
    let suburb: String?
    let day: String
    var action: (() -> Void)?
    var secondary: (title: String, action: () -> Void)?
    /// Anything else the long press offers — the Debug/Beta variant switch.
    @ViewBuilder var extra: () -> Extra

    var body: some View {
        VStack(spacing: 0) {
            AteHairline()
            if let action {
                Button(action: action) { line.contentShape(.rect) }
                    .buttonStyle(.plain)
                    .contextMenu {
                        if let secondary { Button(secondary.title, action: secondary.action) }
                        extra()
                    }
                    .accessibilityIdentifier("entry.place")
            } else {
                line
            }
        }
    }

    private var line: some View {
        HStack(spacing: Self.gap) {
            if let place {
                AteIcon.place.view(size: 16)
                    .foregroundStyle(AtePalette.slip.muted)
                Text(place)
                    .ateText(.control)
                    .foregroundStyle(AtePalette.slip.fg)
                    .lineLimit(1)
                    .truncationMode(.tail)
                if let suburb {
                    // `margin-left:2px` on top of the row's 6.
                    Text(suburb)
                        .ateText(.meta)
                        .foregroundStyle(AtePalette.slip.muted)
                        .lineLimit(1)
                        .fixedSize()
                        .padding(.leading, 2)
                        .layoutPriority(1)
                }
            }
            Spacer(minLength: 0)
            // `margin-left:auto; padding-left:8px`.
            Text(day)
                .ateText(.meta)
                .foregroundStyle(AtePalette.slip.muted)
                .lineLimit(1)
                .fixedSize()
                .padding(.leading, 8 - Self.gap)
                .layoutPriority(1)
        }
        .frame(minHeight: AteMetrics.hit)
        .accessibilityElement(children: .combine)
    }

    private static var gap: CGFloat { 6 }
}
