import AteKit
import SwiftUI

/// **One award, opened** (`plate-awards-screens.html`): the live plate — drag to spin, turn it over
/// for its back — its name and day, then what earned it, by type:
/// - a dish count: "Your first N dishes", oldest first, the Nth ringed; the next award's distance;
/// - a few dishes (one entry's five, one place's five, the 10 saves', the same dish's three, the
///   saved dish): their rows;
/// - everything else: the entries behind it, as their slips.
/// Somebody else's opens read-only, the same way.
struct V2AwardPage: View {
    let route: AwardRoute
    let context: V2PageContext

    @State private var store: AwardsStore
    @State private var lines: AwardLinesStore
    @State private var stage = AtePlateStage()
    @State private var entries: [EntryCard] = []
    @State private var dishesLogged: Int?
    @State private var sharing: AwardShareImage?
    @Environment(\.colorScheme) private var colorScheme

    init(route: AwardRoute, context: V2PageContext) {
        self.route = route
        self.context = context
        let awards = context.services.awards
        _store = State(initialValue: AwardsStore(userID: route.userID, awards: awards))
        _lines = State(initialValue: AwardLinesStore(userID: route.userID, award: route.award, awards: awards))
    }

    private var isMine: Bool { route.userID == nil }
    private var award: EarnedAward? { store.award(route.award) }

    var body: some View {
        ScrollView {
            VStack(spacing: 0) {
                AtePlateView(stage: stage)
                    .frame(width: AteAwardsMetrics.detailPlate, height: AteAwardsMetrics.detailPlate)
                    .padding(.top, AteMetrics.loose)
                Text(route.award.name)
                    .ateTextExactLifted(.awardTitle)
                    .foregroundStyle(AtePalette.automatic.fg)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, AteMetrics.gutter)
                    .padding(.top, AteMetrics.tight)
                if let award {
                    Text(AtePlateSpec.backstampDate(award.earnedAt))
                        .ateText(.awardDate)
                        .foregroundStyle(AtePalette.automatic.muted)
                        .padding(.top, AteMetrics.tight)
                    behind(award)
                        .transition(.opacity)
                }
            }
            // Full width at every phase: before its rows land the page is only as wide as its
            // title, and the screen's own white showed at both sides (Eamon, build 269).
            .frame(maxWidth: .infinity)
            .ateAnimation(AteMotion.fillIn, value: award == nil)
            .padding(.bottom, AteMetrics.section)
        }
        .ateRefreshable { await store.refresh() }
        .accessibilityIdentifier("v2.award")
        .ateGround()
        .atePushedBar()
        .toolbar {
            if award != nil {
                ToolbarItem(placement: .topBarTrailing) {
                    Button(action: share) {
                        AteIcon.share.view(size: AteGlassDiscMetrics.glyph)
                    }
                    .accessibilityLabel("Share")
                    .accessibilityIdentifier("award.page.share")
                }
            }
        }
        .sheet(item: $sharing) { image in
            ShareSheet(image: image.image)
                .presentationDetents([.medium, .large])
        }
        .task { await load() }
        .onChange(of: colorScheme) { _, _ in showPlate(intro: false) }
    }

    // MARK: - What earned it

    @ViewBuilder
    private func behind(_ award: EarnedAward) -> some View {
        switch route.award.opening {
        case .mosaic(let count):
            mosaic(award, count: count)
                .padding(.horizontal, AteMetrics.gutter)
        case .dishes:
            dishRows
                .padding(.horizontal, AteMetrics.gutter)
                .padding(.top, AteMetrics.section)
        case .entries:
            slips
                .padding(.top, AwardPageMetrics.slipsTop)
        }
    }

    private func mosaic(_ award: EarnedAward, count: Int) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            if let days = store.daysAfterFirstDish(award) {
                Text(AwardCopy.daysAfterFirstDish(days))
                    .ateText(.awardStat)
                    .foregroundStyle(AtePalette.automatic.fg)
                    .frame(maxWidth: .infinity)
                    .padding(.top, AteMetrics.snug)
            }
            Text(isMine ? AwardCopy.yourFirst(count) : AwardCopy.firstDishes(count))
                .ateText(.awardSection)
                .foregroundStyle(AtePalette.automatic.fg)
                .accessibilityAddTraits(.isHeader)
                .padding(.top, AteMetrics.section)
                .padding(.bottom, AteMetrics.regular)
            LazyVGrid(columns: AwardPageMetrics.mosaicColumns, spacing: AteMetrics.snug) {
                ForEach(Array(lines.lines.enumerated()), id: \.element.id) { index, line in
                    tile(line, isEarning: index == count - 1)
                        .task { await lines.loadMore(after: line) }
                }
            }
            if lines.phase == .loading { AteAwardsGridSkeleton().padding(.top, AteMetrics.regular) }
            if isMine, let logged = dishesLogged, let toGo = PlateAward.dishesToNext(after: logged) {
                Text(AwardCopy.nextAward(in: toGo))
                    .ateText(.awardDate)
                    .foregroundStyle(AtePalette.automatic.muted)
                    .frame(maxWidth: .infinity)
                    .padding(.top, AwardPageMetrics.nextTop)
            }
        }
    }

    private func tile(_ line: AwardLine, isEarning: Bool) -> some View {
        Button { open(line) } label: {
            AteThumb(photo: .dish(line.dishID, name: line.dishName, cover: line.photoURL), size: .row)
                .padding(AwardPageMetrics.ringGap)
                .overlay {
                    if isEarning {
                        RoundedRectangle(cornerRadius: AwardPageMetrics.ringRadius, style: .continuous)
                            .strokeBorder(AtePalette.automatic.fg, lineWidth: AwardPageMetrics.ring)
                    }
                }
        }
        .buttonStyle(.plain)
        .accessibilityLabel(line.dishName)
    }

    private var dishRows: some View {
        VStack(spacing: 0) {
            ForEach(lines.lines) { line in
                Button { open(line) } label: {
                    HStack(spacing: AteMetrics.regular) {
                        AteThumb(photo: .dish(line.dishID, name: line.dishName, cover: line.photoURL), size: .menu)
                        VStack(alignment: .leading, spacing: AteMetrics.hairspace) {
                            Text(line.dishName)
                                .ateText(.rowTitle)
                                .foregroundStyle(AtePalette.automatic.fg)
                            if let place = line.restaurantName {
                                Text(place)
                                    .ateText(.meta)
                                    .foregroundStyle(AtePalette.automatic.muted)
                            }
                        }
                        Spacer(minLength: AteMetrics.snug)
                        if let score = line.score.flatMap(Rating.init(exactly:)) {
                            AteScoreToken(rating: score, size: .row)
                        }
                    }
                    .padding(.vertical, AteMetrics.snug)
                    .contentShape(.rect)
                }
                .buttonStyle(.plain)
                .task { await lines.loadMore(after: line) }
            }
        }
    }

    private var slips: some View {
        VStack(spacing: AteMetrics.slipGap) {
            ForEach(entries) { entry in
                AteEntrySlip(
                    slip: isMine ? EntrySlipPresentation.journal(entry) : EntrySlipPresentation.profile(entry),
                    surface: isMine ? .journal : .profile,
                    onOpen: { context.open(.entry(entry), from: .award) },
                    onPlace: { context.open(.place($0), from: .award) },
                    onDish: { context.open(.dish($0.dishID), from: .award) },
                    identifier: "award.slip"
                )
                .ateCardWidth() // the one card width, as on the Journal and a profile
            }
        }
    }

    // MARK: - Loading

    private func load() async {
        await store.loadIfNeeded()
        showPlate(intro: true)
        guard let award else { return }
        switch route.award.opening {
        case .mosaic, .dishes:
            await lines.loadIfNeeded()
            if isMine, case .mosaic = route.award.opening, let me = try? await context.services.stats.viewerID() {
                dishesLogged = try? await context.services.stats.summary(userID: me).dishes
            }
        case .entries:
            guard entries.isEmpty else { return }
            var read: [EntryCard] = []
            for id in award.entries {
                if let card = try? await context.services.entries.entry(id: id) { read.append(card) }
            }
            entries = read
        }
    }

    private func showPlate(intro: Bool) {
        guard let award else { return }
        stage.show(AtePlateSpec(
            award: award.award, dish: award.dishLine, date: award.earnedAt,
            handle: isMine ? context.app.handle : route.handle,
            dark: colorScheme == .dark, intro: intro
        ))
    }

    private func open(_ line: AwardLine) {
        if let entryID = line.entryID {
            context.open(.entry(EntryRoute(entryID: entryID)), from: .award)
        } else {
            context.open(.dish(line.dishID), from: .award)
        }
    }

    private func share() {
        guard let award else { return }
        let days = store.daysAfterFirstDish(award)
        let stage = stage
        Task {
            let plate = await stage.still(side: AwardStoryCard.plateSide)
            guard let image = AwardStoryCard.render(award: award, plate: plate, daysAfterFirstDish: days)
            else { return }
            context.services.analytics(AwardEvents.shared(award: award.award, source: isMine ? .you : .profile))
            sharing = AwardShareImage(image: image)
        }
    }
}

enum AwardPageMetrics {
    /// "Your first N dishes": five across, 8 apart (`.mos`).
    static let mosaicColumns = Array(repeating: GridItem(.flexible(), spacing: AteMetrics.snug), count: 5)
    /// The earning dish's ring: 2 of ink, 2 off the tile.
    static let ring: CGFloat = 2
    static let ringGap: CGFloat = 3
    static let ringRadius: CGFloat = 19
    static let nextTop: CGFloat = 18
    static let slipsTop: CGFloat = 22
}
