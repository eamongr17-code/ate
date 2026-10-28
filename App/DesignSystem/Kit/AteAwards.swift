import AteKit
import SwiftUI

/// **The awards band** — on You (the third band, after Your ratings and Your top dishes) and on a
/// profile: a row of plates, newest first, running off the trailing edge. A plate opens it.
struct AteAwardsRow: View {
    let awards: [EarnedAward]
    let onOpen: (EarnedAward) -> Void

    var body: some View {
        ScrollView(.horizontal) {
            LazyHStack(spacing: AteAwardsMetrics.rowGap) {
                ForEach(awards) { award in
                    Button { onOpen(award) } label: {
                        AtePlateStill(award: award.award)
                            .frame(width: AteAwardsMetrics.rowPlate, height: AteAwardsMetrics.rowPlate)
                            .contentShape(.circle)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(award.award.name)
                    .accessibilityIdentifier("awards.row.\(award.award.rawValue)")
                }
            }
            .padding(.horizontal, AteMetrics.gutter)
        }
        .scrollIndicators(.hidden)
        // the row runs to the screen's edges, the page's gutter inside it
        .padding(.horizontal, -AteMetrics.gutter)
    }
}

/// The band before it has arrived: four discs in the plates' places.
struct AteAwardsRowSkeleton: View {
    var breathes = true

    @Environment(\.atePalette) private var palette

    var body: some View {
        HStack(spacing: AteAwardsMetrics.rowGap) {
            ForEach(0..<AteAwardsMetrics.skeletonCount, id: \.self) { _ in
                Circle()
                    .fill(palette.hairline)
                    .padding(AteAwardsMetrics.skeletonInset)
                    .frame(width: AteAwardsMetrics.rowPlate, height: AteAwardsMetrics.rowPlate)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .ateSkeletonSweep(breathes)
        .accessibilityHidden(true)
    }
}

/// **One place on the Awards page**: an earned plate with its name and day, or a silhouette with
/// neither.
struct AteAwardCell: View {
    let cell: AwardCell
    let onOpen: (EarnedAward) -> Void

    @Environment(\.atePalette) private var palette

    var body: some View {
        switch cell {
        case .earned(let award):
            Button { onOpen(award) } label: {
                VStack(spacing: AteMetrics.hairspace) {
                    AtePlateStill(award: award.award)
                        .frame(maxWidth: AteAwardsMetrics.gridPlate)
                        .padding(.bottom, AteMetrics.tight - AteMetrics.hairspace)
                    // the exact line box: two-line names sat on the face's own loose leading
                    Text(award.award.name)
                        .ateTextExactLifted(.awardCellName)
                        .foregroundStyle(palette.fg)
                        .multilineTextAlignment(.center)
                        .fixedSize(horizontal: false, vertical: true)
                    Text(AteAwardsMetrics.cellDate(award.earnedAt))
                        .ateText(.awardCellDate)
                        .foregroundStyle(palette.muted)
                        .monospacedDigit()
                }
                .frame(maxWidth: .infinity)
                .contentShape(.rect)
            }
            .buttonStyle(.plain)
            .accessibilityElement(children: .combine)
            .accessibilityIdentifier("awards.cell.\(award.award.rawValue)")
        case .hidden(let award):
            AtePlateStill(award: award, isHidden: true)
                .frame(maxWidth: AteAwardsMetrics.gridPlate)
                .frame(maxWidth: .infinity, alignment: .top)
                .accessibilityElement()
                .accessibilityLabel("Hidden award")
        }
    }
}

/// The grid before it has arrived.
struct AteAwardsGridSkeleton: View {
    @Environment(\.atePalette) private var palette

    var body: some View {
        LazyVGrid(columns: AteAwardsMetrics.columns, spacing: AteAwardsMetrics.gridRowGap) {
            ForEach(0..<AteAwardsMetrics.gridSkeletonCount, id: \.self) { _ in
                Circle()
                    .fill(palette.hairline)
                    .padding(AteAwardsMetrics.skeletonInset)
                    .aspectRatio(1, contentMode: .fit)
                    .frame(maxWidth: AteAwardsMetrics.gridPlate)
            }
        }
        .ateSkeletonSweep()
        .accessibilityHidden(true)
    }
}

enum AteAwardsMetrics {
    /// The band's plates: 92 square, 6 apart (`.arow`).
    static let rowPlate: CGFloat = 92
    static let rowGap: CGFloat = 6
    static let skeletonCount = 4
    /// A disc's inset in its plate's square — a still's plate does not fill its square.
    static let skeletonInset: CGFloat = 12
    /// The grid: three columns, plates up to 112, rows 18 apart (`.grid`).
    static let gridPlate: CGFloat = 112
    static let gridColumnGap: CGFloat = 6
    static let gridRowGap: CGFloat = 18
    static let gridSkeletonCount = 9
    static let columns = Array(
        repeating: GridItem(.flexible(), spacing: gridColumnGap, alignment: .top), count: 3
    )
    /// An opened award's plate: 330 square.
    static let detailPlate: CGFloat = 330

    /// "18 Oct" — the year only when it is not this one.
    static func cellDate(_ date: Date, now: Date = .now) -> String {
        let calendar = Calendar.current
        if calendar.component(.year, from: date) == calendar.component(.year, from: now) {
            return date.formatted(.dateTime.day().month(.abbreviated))
        }
        return date.formatted(.dateTime.day().month(.abbreviated).year())
    }
}
