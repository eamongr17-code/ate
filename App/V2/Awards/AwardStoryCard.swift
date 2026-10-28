import AteKit
import SwiftUI

/// **An award's story card** — 9:16, the plate on the takeover's lit ink, its name, the dish under
/// it and the day, the wordmark at the foot. Made at the moment of sharing.
struct AwardStoryCard: View {
    let award: EarnedAward
    let plate: UIImage?
    let daysAfterFirstDish: Int?

    /// The card's own pixels: a story is 1080 × 1920.
    static let size = CGSize(width: 1080, height: 1920)
    static let plateSide = 960

    var body: some View {
        VStack(spacing: 0) {
            Group {
                if let plate {
                    Image(uiImage: plate).resizable().scaledToFit()
                } else {
                    AtePlateStill(award: award.award)
                }
            }
            .frame(width: AwardStoryMetrics.plate, height: AwardStoryMetrics.plate)
            .padding(.top, AwardStoryMetrics.plateTop)
            Text(award.award.name)
                .ateText(.awardStoryTitle)
                .foregroundStyle(AteAwardColor.takeoverInk)
                .multilineTextAlignment(.center)
            if let line {
                Text(line)
                    .ateText(.awardStoryLine)
                    .foregroundStyle(AteAwardColor.takeoverInk)
                    .multilineTextAlignment(.center)
                    .lineLimit(3)
                    .padding(.top, AwardStoryMetrics.titleToLine)
            }
            Text(AtePlateSpec.backstampDate(award.earnedAt))
                .ateText(.awardStoryDate)
                .foregroundStyle(AteAwardColor.takeoverMuted)
                .padding(.top, AwardStoryMetrics.lineToDate)
            Spacer(minLength: 0)
            AteWordmark(height: AwardStoryMetrics.wordmark, colour: AteAwardColor.takeoverInk)
                .padding(.bottom, AwardStoryMetrics.wordmarkBottom)
        }
        .padding(.horizontal, AwardStoryMetrics.inset)
        .frame(width: Self.size.width, height: Self.size.height)
        .background {
            RadialGradient(
                colors: [AteAwardColor.takeoverGlow, AteAwardColor.takeoverGround],
                center: AteAwardColor.takeoverGlowCentre,
                startRadius: 0,
                endRadius: Self.size.height * AteAwardColor.takeoverGlowStop
            )
        }
        .environment(\.dynamicTypeSize, .large)
    }

    private var line: String? {
        if let daysAfterFirstDish { return AwardCopy.daysAfterFirstDish(daysAfterFirstDish) }
        return award.dishLine
    }

    @MainActor
    static func render(award: EarnedAward, plate: UIImage?, daysAfterFirstDish: Int?) -> UIImage? {
        let renderer = ImageRenderer(content: AwardStoryCard(
            award: award, plate: plate, daysAfterFirstDish: daysAfterFirstDish
        ))
        renderer.scale = 1
        renderer.proposedSize = ProposedViewSize(size)
        return renderer.uiImage
    }
}

enum AwardStoryMetrics {
    static let plate: CGFloat = 960
    static let plateTop: CGFloat = 200
    static let inset: CGFloat = 80
    static let titleToLine: CGFloat = 28
    static let lineToDate: CGFloat = 16
    static let wordmark: CGFloat = 72
    static let wordmarkBottom: CGFloat = 140
}
