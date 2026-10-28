import AteKit
import SwiftUI

/// **The award takeover** (`plate-awards-screens.html`, approved 28 Oct) — full screen over
/// everything, on ink in both modes: the live plate rises in with the approved turn, then its name,
/// what earned it and the day fade up under it, with one soft haptic. Several awards are pages of
/// this one takeover — swipe or Next, Done on the last — never separate pop-ups.
struct AwardTakeoverScreen: View {
    let app: AppModel
    let onDone: () -> Void

    @State private var stage = AtePlateStage()
    @State private var page = 0
    /// Bumped per page so the words play their entrance again.
    @State private var arrival = 0
    @State private var isWordsUp = false
    @State private var sharing: AwardShareImage?
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var awards: [EarnedAward] { app.awardTakeover.showing }
    private var current: EarnedAward? { awards.indices.contains(page) ? awards[page] : awards.first }
    private var isLast: Bool { page >= awards.count - 1 }

    var body: some View {
        GeometryReader { geometry in
            VStack(spacing: 0) {
                AtePlateView(stage: stage)
                    .frame(width: geometry.size.width, height: geometry.size.width)
                    .padding(.top, AwardTakeoverMetrics.plateTop)
                if let current {
                    words(current)
                        .padding(.horizontal, AwardTakeoverMetrics.wordsInset)
                        .padding(.top, AwardTakeoverMetrics.plateToWords)
                }
                Spacer(minLength: AteMetrics.section)
                if awards.count > 1 { dots }
                buttons
                    .padding(.horizontal, AteMetrics.gutter)
                    .ateContentBottom(AwardTakeoverMetrics.buttonsBottom)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        }
        .background { ground }
        .environment(\.atePalette, .ink)
        .preferredColorScheme(.dark)
        .contentShape(.rect)
        .gesture(swipe)
        .accessibilityIdentifier("v2.award.takeover")
        .sheet(item: $sharing) { image in
            ShareSheet(image: image.image)
                .presentationDetents([.medium, .large])
        }
        .onAppear {
            if let first = awards.first {
                app.services.analytics(AwardEvents.takeoverShown(award: first.award, count: awards.count))
            }
            arrive()
        }
    }

    // MARK: - Parts

    private var ground: some View {
        RadialGradient(
            colors: [AteAwardColor.takeoverGlow, AteAwardColor.takeoverGround],
            center: AteAwardColor.takeoverGlowCentre,
            startRadius: 0,
            endRadius: AteScreen.size.height * AteAwardColor.takeoverGlowStop * AwardTakeoverMetrics.glowReach
        )
        .background(AteAwardColor.takeoverGround)
        .ignoresSafeArea()
    }

    private func words(_ award: EarnedAward) -> some View {
        VStack(spacing: 0) {
            Text(award.award.name)
                .ateText(.awardTakeoverTitle)
                .foregroundStyle(AteAwardColor.takeoverInk)
                .multilineTextAlignment(.center)
                .rise(isWordsUp, delay: AwardTakeoverMetrics.titleDelay, reduceMotion: reduceMotion)
            line(award)
                .padding(.top, AteMetrics.regular)
                .rise(isWordsUp, delay: AwardTakeoverMetrics.lineDelay, reduceMotion: reduceMotion)
            Text(AtePlateSpec.backstampDate(award.earnedAt))
                .ateText(.awardDate)
                .foregroundStyle(AteAwardColor.takeoverMuted)
                .padding(.top, AwardTakeoverMetrics.lineToDate)
                .rise(isWordsUp, delay: AwardTakeoverMetrics.dateDelay, reduceMotion: reduceMotion)
        }
        .frame(maxWidth: .infinity)
        .accessibilityElement(children: .combine)
        .id(arrival)
    }

    /// A dish count says how long it took; everything else says the dish, and the score it got.
    @ViewBuilder
    private func line(_ award: EarnedAward) -> some View {
        if let days = app.awardTakeover.daysAfterFirstDish(award) {
            Text(AwardCopy.daysAfterFirstDish(days))
                .ateText(.awardLine)
                .foregroundStyle(AteAwardColor.takeoverInk)
        } else if let dish = award.dishLine {
            AteFlow(spacing: AteMetrics.snug, lineSpacing: AteMetrics.tight, centresLines: true) {
                Text(dish)
                    .ateText(.awardLine)
                    .foregroundStyle(AteAwardColor.takeoverInk)
                    .multilineTextAlignment(.center)
                if let score = award.score.flatMap(Rating.init(exactly:)) {
                    AteScoreToken(rating: score, size: .row)
                }
            }
        }
    }

    private var dots: some View {
        HStack(spacing: AwardTakeoverMetrics.dotGap) {
            ForEach(awards.indices, id: \.self) { index in
                Circle()
                    .fill(index == page ? AteAwardColor.takeoverInk : AteAwardColor.takeoverDot)
                    .frame(width: AwardTakeoverMetrics.dot, height: AwardTakeoverMetrics.dot)
            }
        }
        .padding(.bottom, AwardTakeoverMetrics.dotsToButtons)
        .accessibilityHidden(true)
    }

    private var buttons: some View {
        HStack(spacing: AwardTakeoverMetrics.buttonGap) {
            AteInkPill(title: AwardCopy.share, identifier: "award.share") { share() }
            Button(action: next) {
                Text(isLast ? AwardCopy.done : AwardCopy.next)
                    .ateText(.button)
                    .foregroundStyle(AteAwardColor.takeoverInk)
                    .frame(maxWidth: .infinity)
                    .frame(height: AteInkPillMetrics.sheetHeight)
                    .background(AteAwardColor.takeoverQuietPill, in: .capsule)
                    .overlay {
                        Capsule().strokeBorder(AteAwardColor.takeoverQuietEdge, lineWidth: AwardTakeoverMetrics.edge)
                    }
                    .contentShape(.capsule)
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier(isLast ? "award.done" : "award.next")
        }
    }

    private var swipe: some Gesture {
        DragGesture(minimumDistance: AwardTakeoverMetrics.swipeStart)
            .onEnded { drag in
                guard abs(drag.translation.width) > abs(drag.translation.height),
                      abs(drag.translation.width) > AwardTakeoverMetrics.swipeDistance else { return }
                if drag.translation.width < 0 {
                    if isLast == false { go(to: page + 1) }
                } else if page > 0 {
                    go(to: page - 1)
                }
            }
    }

    // MARK: - Moves

    private func next() {
        if isLast {
            onDone()
        } else {
            go(to: page + 1)
        }
    }

    private func go(to index: Int) {
        page = index
        arrive()
    }

    private func arrive() {
        guard let current else { return }
        stage.show(AtePlateSpec(
            award: current.award, dish: current.dishLine, date: current.earnedAt, handle: app.handle
        ))
        app.services.analytics(AwardEvents.earned(award: current.award))
        isWordsUp = false
        arrival += 1
        Task {
            // the words come up as the plate settles
            try? await Task.sleep(for: .milliseconds(AwardTakeoverMetrics.hapticDelay))
            AteHaptics.award()
        }
        Task { isWordsUp = true }
    }

    private func share() {
        guard let current else { return }
        let days = app.awardTakeover.daysAfterFirstDish(current)
        let stage = stage
        Task {
            let plate = await stage.still(side: AwardStoryCard.plateSide)
            guard let image = AwardStoryCard.render(award: current, plate: plate, daysAfterFirstDish: days)
            else { return }
            app.services.analytics(AwardEvents.shared(award: current.award, source: .takeover))
            sharing = AwardShareImage(image: image)
        }
    }
}

/// A rendered story card, ready for the share sheet.
struct AwardShareImage: Identifiable {
    let id = UUID()
    let image: UIImage
}

/// The awards' few words. Never about printing or receipts.
enum AwardCopy {
    static let share = "Share"
    static let next = "Next"
    static let done = "Done"

    static func daysAfterFirstDish(_ days: Int) -> String {
        days == 1 ? "1 day after your first dish" : "\(days) days after your first dish"
    }

    static func yourFirst(_ count: Int) -> String { "Your first \(count) dishes" }
    static func firstDishes(_ count: Int) -> String { "First \(count) dishes" }

    static func nextAward(in dishes: Int) -> String {
        dishes == 1 ? "Next award in 1 dish" : "Next award in \(dishes) dishes"
    }
}

enum AwardTakeoverMetrics {
    /// The plate's square starts under the status bar (`#stage{top:96px}`, less the bar).
    static let plateTop: CGFloat = 42
    static let plateToWords: CGFloat = 0
    static let wordsInset: CGFloat = 28
    static let lineToDate: CGFloat = 6
    static let titleDelay: Double = 0.7
    static let lineDelay: Double = 0.85
    static let dateDelay: Double = 1.0
    static let rise: CGFloat = 10
    static let riseDuration: Double = 0.8
    static let hapticDelay = 1600
    static let dot: CGFloat = 7
    static let dotGap: CGFloat = 7
    static let dotsToButtons: CGFloat = 22
    static let buttonGap: CGFloat = 10
    static let buttonsBottom: CGFloat = 44
    static let edge: CGFloat = 0.5
    static let glowReach: CGFloat = 0.9
    static let swipeStart: CGFloat = 24
    static let swipeDistance: CGFloat = 60
}

private extension View {
    /// `@keyframes up`: up 10 and in, over 0.8s, after `delay`.
    func rise(_ isUp: Bool, delay: Double, reduceMotion: Bool) -> some View {
        opacity(isUp || reduceMotion ? 1 : 0)
            .offset(y: isUp || reduceMotion ? 0 : AwardTakeoverMetrics.rise)
            .animation(
                reduceMotion ? nil
                    : .timingCurve(0.2, 0.7, 0.2, 1, duration: AwardTakeoverMetrics.riseDuration).delay(delay),
                value: isUp
            )
    }
}
