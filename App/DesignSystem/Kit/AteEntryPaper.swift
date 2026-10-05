import AteKit
import SwiftUI

/// **One entry, whole, on one sheet of paper** — the entry page. Flat white paper on the ground,
/// 24 top corners, running off the foot of the screen. On it, in the slip's own order: **the dish
/// rows**, the words with their tokens, the tilted photo cluster, and the place line (pin, place,
/// suburb, and the day at the right). There is no receipt on the page: the receipt is what Share
/// sends.
///
/// Every part is also a correction on your own entry: a long press on a dish row says which dish it
/// really was, and one on the place line changes the place. Somebody else's entry has no corrections:
/// a bookmark on every dish instead.
struct AteEntryPaper: View {
    enum Dishes: Equatable {
        case rows([AteSlip.Dish])
        /// The words are saved and the structure has not arrived: two still rows. `isFailed` adds
        /// "Print it again" under the words.
        case pending(isFailed: Bool)
    }

    let dishes: Dishes
    let words: EntryComposition
    var photos: [AtePhoto] = []
    let place: String?
    var suburb: String?
    let day: String
    /// A dish row's page (the dish), or a score in the words.
    var onDish: ((AteSlip.Dish) -> Void)?
    var onScoreDish: ((UUID) -> Void)?
    /// Your own entry: the dish's correction, one long press away.
    var onCorrectDish: ((AteSlip.Dish) -> Void)?
    /// Your own entry: put the dish on a list, in the same long press (`lists-notifications.html` D1).
    var onAddDishToList: ((AteSlip.Dish) -> Void)?
    /// Somebody else's entry: every row is a dish to save.
    var onSaveDish: ((AteSlip.Dish) -> Void)?
    var onPlace: (() -> Void)?
    /// Your own entry: change the place (a long press), or attach one when it has none (the tap).
    var onCorrectPlace: (() -> Void)?
    var onPhoto: ((Int) -> Void)?
    var onReprint: (() -> Void)?
    /// "Ate with": who it was eaten with, printed under the place line (``AteWithLine``) — nothing
    /// when nobody. A handle opens that person's page.
    var with: [AteWithPerson] = []
    var onWithPerson: ((AteWithPerson) -> Void)?
    /// `true`: the paper runs off the foot of the screen (the page continues). `false`: it ends at its
    /// content, rounded at the foot too, so what sits under it on the ground is in view.
    var fillsScreen = true

    @Environment(\.atePhotoViewer) private var showPhotos

    var body: some View {
        VStack(alignment: .leading, spacing: AteMetrics.pageBandGap) {
            dishBand
            if words.plain.isEmpty == false {
                InlineTokenText(composition: words, style: .proseLarge, onScoreDish: onScoreDish)
                    .accessibilityIdentifier("entry.words")
            }
            reprint
            if photos.isEmpty == false {
                AtePhotoCluster(
                    photos: Array(photos.prefix(AteEntryPaperMetrics.clusterMax)),
                    size: .entry,
                    surface: AteColor.slip,
                    onTap: onPhoto ?? { showPhotos(photos, at: $0) }
                )
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            VStack(alignment: .leading, spacing: AteWithKitMetrics.underPlace) {
                AteEntryPlaceLine(
                    place: place, suburb: suburb, day: day,
                    action: onPlace ?? onCorrectPlace,
                    secondary: onPlace == nil ? nil : onCorrectPlace
                )
                if with.isEmpty == false {
                    AteWithLine(people: with) { onWithPerson?($0) }
                }
            }
        }
        .padding(.top, AteMetrics.pagePaddingTop)
        .padding(.horizontal, AteMetrics.pagePaddingSide)
        .padding(.bottom, AteMetrics.section)
        .frame(maxWidth: .infinity, alignment: .leading)
        .frame(minHeight: fillsScreen ? Self.minimumHeight : nil, alignment: .top)
        .ateSlip()
        .background(AteColor.slip, in: UnevenRoundedRectangle(
            topLeadingRadius: AteMetrics.pageTop,
            bottomLeadingRadius: fillsScreen ? 0 : AteMetrics.pageTop,
            bottomTrailingRadius: fillsScreen ? 0 : AteMetrics.pageTop,
            topTrailingRadius: AteMetrics.pageTop,
            style: .continuous
        ))
    }

    @ViewBuilder
    private var dishBand: some View {
        switch dishes {
        case .rows(let rows):
            if rows.isEmpty == false {
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(Array(rows.enumerated()), id: \.element.id) { index, dish in
                        VStack(spacing: 0) {
                            if index > 0 { AteHairline() }
                            row(dish)
                        }
                    }
                }
                .accessibilityElement(children: .contain)
                .accessibilityIdentifier("entry.dishes")
            }
        case .pending:
            VStack(alignment: .leading, spacing: 0) { AteEntryPendingRows() }
                .accessibilityElement(children: .contain)
                .accessibilityIdentifier("entry.pending")
        }
    }

    /// A sort that failed: "Print it again" at its own width, under the words.
    @ViewBuilder
    private var reprint: some View {
        if dishes == .pending(isFailed: true), let onReprint {
            AteInkPill(title: "Print it again", size: .empty, identifier: "entry.reprint", action: onReprint)
                .environment(\.atePalette, .automatic)
        }
    }

    private func row(_ dish: AteSlip.Dish) -> some View {
        let open = onDish.map { open in { open(dish) } }
        let correct = onCorrectDish.map { correct in { correct(dish) } }
        let primary = open ?? correct
        return SlipDishRow(
            dish: dish,
            action: primary,
            secondary: primary == nil ? nil : correct.map { (title: "Change the dish", action: $0) },
            addToList: primary == nil ? nil : onAddDishToList.map { add in
                (title: "Add to a list", action: { add(dish) })
            },
            onSave: onSaveDish.map { save in { save(dish) } },
            identifier: "entry"
        )
    }

    /// Everything left of the screen under the bar, and a little past the fold: the page continues.
    private static var minimumHeight: CGFloat {
        max(0, AteScreen.height - AteMetrics.contentTop - AteMetrics.hit + AteMetrics.pageOvershoot)
    }
}

/// **The place line** at the foot of the entry: muted pin, the place, its suburb, and the day at the
/// right, ruled above. The place truncates first; the suburb and the day never wrap. A place never
/// attached is not guessed at: the line carries only the day.
struct AteEntryPlaceLine: View {
    let place: String?
    var suburb: String?
    let day: String
    var action: (() -> Void)?
    /// "Change the place", one long press away.
    var secondary: (() -> Void)?

    @Environment(\.atePalette) private var palette

    var body: some View {
        VStack(spacing: 0) {
            AteHairline()
            if let action {
                Button(action: action) { line.contentShape(.rect) }
                    .buttonStyle(.plain)
                    .contextMenu {
                        if let secondary { Button("Change the place", action: secondary) }
                    }
                    .accessibilityIdentifier("entry.place")
            } else {
                line
            }
        }
    }

    private var line: some View {
        HStack(spacing: AteEntryPaperMetrics.lineGap) {
            if let place {
                AteIcon.place.view(size: AteEntryPaperMetrics.pin)
                    .foregroundStyle(palette.muted)
                Text(place)
                    .ateText(.control)
                    .foregroundStyle(palette.fg)
                    .lineLimit(1)
                    .truncationMode(.tail)
                if let suburb {
                    Text(suburb)
                        .ateText(.meta)
                        .foregroundStyle(palette.muted)
                        .lineLimit(1)
                        .fixedSize()
                        .padding(.leading, AteMetrics.hairspace)
                        .layoutPriority(1)
                }
            }
            Spacer(minLength: AteMetrics.snug)
            Text(day)
                .ateText(.meta)
                .foregroundStyle(palette.muted)
                .lineLimit(1)
                .fixedSize()
                .layoutPriority(1)
        }
        .frame(minHeight: AteMetrics.hit)
        .accessibilityElement(children: .combine)
    }
}

/// **The dish rows before they have arrived**: the shape of two rows parted by a hairline, still —
/// no label, no spinner.
struct AteEntryPendingRows: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(0..<2, id: \.self) { row in
                VStack(spacing: 0) {
                    if row > 0 { AteHairline() }
                    HStack {
                        AteSkeletonBar(
                            width: row == 0 ? AteEntryPaperMetrics.firstBar : AteEntryPaperMetrics.secondBar,
                            height: AteEntryPaperMetrics.nameBar
                        )
                        Spacer(minLength: 0)
                        AteSkeletonBar(
                            width: AteEntryPaperMetrics.scoreBarWidth,
                            height: AteEntryPaperMetrics.scoreBar
                        )
                    }
                    .frame(minHeight: AteMetrics.hit)
                }
            }
        }
        .accessibilityHidden(true)
    }
}

enum AteEntryPaperMetrics {
    /// The place line: `gap:6px`, its pin 16.
    static let lineGap: CGFloat = 6
    static let pin: CGFloat = 16
    /// The still rows: a 168 and a 120 name over an 18 bar, a 56 × 20 score.
    static let firstBar: CGFloat = 168
    static let secondBar: CGFloat = 120
    static let nameBar: CGFloat = 18
    static let scoreBarWidth: CGFloat = 56
    static let scoreBar: CGFloat = 20
    /// The cluster shows three; the viewer has every photo.
    static let clusterMax = 3
}
