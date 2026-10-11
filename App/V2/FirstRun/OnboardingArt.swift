import AteKit
import SwiftUI
import UIKit

/// **What each card shows** (`design/rebuild/onboarding-cards.html`, approved 11 Oct). Eamon: the
/// cards are instructions, not copies of a screen, and they fill the room above the title. Each one
/// stages the gesture it teaches with the kit's own parts and the one sample entry:
///
/// - **Write** — the entry typing itself on its paper, two older entries under it, the keyboard
///   under that.
/// - **Photos** — a camera roll with two photos picked, and the slip holding those two.
/// - **Scores** — the slip with its scores, and a finger part-way along the real star slider.
/// - **Share** — the ink share sheet's three cards fanned out, the story's grounds, and the row.
///
/// Drawn on one canvas (``OnboardingArtMetrics/canvas``) and scaled down as a whole where the card
/// has less room, so a small phone sees the same picture, smaller. Nothing here is tappable.
struct OnboardingArt: View {
    let card: OnboardingCard
    let sample: OnboardingSample
    let handle: String
    /// The card is on screen: its motion runs only then.
    let isShowing: Bool

    var body: some View {
        GeometryReader { proxy in
            let canvas = OnboardingArtMetrics.canvas
            let scale = min(
                OnboardingArtMetrics.maximumScale,
                proxy.size.width / canvas.width,
                proxy.size.height / canvas.height
            )
            stage
                .frame(width: canvas.width, height: canvas.height, alignment: .top)
                .scaleEffect(scale, anchor: .top)
                .frame(width: proxy.size.width, height: proxy.size.height, alignment: .top)
        }
    }

    @ViewBuilder
    private var stage: some View {
        switch card {
        case .write: OnboardingWriteArt(words: OnboardingSample.words(scored: false).plain, isShowing: isShowing)
        case .photos: OnboardingPhotosArt(sample: sample)
        case .scores: OnboardingScoresArt(sample: sample)
        case .share: OnboardingShareArt(sample: sample, handle: handle, isShowing: isShowing)
        }
    }
}

// MARK: - Write

/// The words typing themselves out on the composer's paper, with its Score and Place keys, over two
/// older entries and the top of the keyboard. The key under the letter just typed lifts.
private struct OnboardingWriteArt: View {
    let words: String
    let isShowing: Bool

    @State private var typed: Int
    @Environment(\.atePalette) private var palette
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    init(words: String, isShowing: Bool) {
        self.words = words
        self.isShowing = isShowing
        _typed = State(initialValue: words.count)
    }

    var body: some View {
        ZStack(alignment: .top) {
            older(OnboardingSample.olderEntries[0])
                .rotationEffect(.degrees(OnboardingArtMetrics.olderTilt.0))
                .padding(.horizontal, OnboardingArtMetrics.olderInset)
            older(OnboardingSample.olderEntries[1])
                .rotationEffect(.degrees(OnboardingArtMetrics.olderTilt.1))
                .padding(.horizontal, AteMetrics.snug)
                .padding(.top, OnboardingArtMetrics.olderStep)
            VStack(spacing: AteMetrics.loose) {
                paper
                keyboard
            }
            .padding(.top, OnboardingArtMetrics.paperTop)
        }
        .task(id: isShowing) { await type() }
    }

    private func type() async {
        guard isShowing, reduceMotion == false else {
            typed = words.count
            return
        }
        typed = 0
        try? await Task.sleep(for: OnboardingArtMetrics.typingStart)
        while typed < words.count {
            try? await Task.sleep(for: OnboardingArtMetrics.keystroke)
            if Task.isCancelled { return }
            typed += 1
        }
    }

    private func older(_ line: String) -> some View {
        Text(line)
            .ateText(.slipProse)
            .foregroundStyle(palette.muted)
            .lineLimit(1)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, AteMetrics.slipPadding)
            .padding(.top, AteMetrics.regular)
            .padding(.bottom, OnboardingArtMetrics.olderHeight)
            .ateTornPaper(.slip)
    }

    private var paper: some View {
        VStack(alignment: .leading, spacing: AteMetrics.regular) {
            HStack(spacing: AteMetrics.tight) {
                AteIcon.place.view(size: OnboardingArtMetrics.placeIcon)
                Text(OnboardingSample.placeLine)
                    .ateText(.controlSmall)
            }
            .foregroundStyle(palette.muted)
            Text(words)
                .ateText(.onboardingWords)
                .hidden()
                .overlay(alignment: .topLeading) { typing }
            HStack(spacing: AteMetrics.snug) {
                ComposerKey(
                    title: "Score", icon: .starFilled, background: AteColor.scoreFill, foreground: AteColor.scoreInk
                ) {}
                ComposerKey(
                    title: "Place", icon: .place, iconSize: 16, background: ComposerKeyColor.place,
                    foreground: ComposerKeyColor.placeInk, value: OnboardingSample.place
                ) {}
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(AteMetrics.slipPadding)
        .padding(.bottom, AteMetrics.tornEdgeHeight)
        .ateTornPaper(.slip)
        .ateShadow(.cover)
    }

    /// The words so far and the caret after them, blinking.
    private var typing: some View {
        TimelineView(.periodic(from: .now, by: OnboardingArtMetrics.caretBlink)) { context in
            let isLit = reduceMotion || Int(context.date.timeIntervalSinceReferenceDate / OnboardingArtMetrics.caretBlink) % 2 == 0
            let sofar = Text(String(words.prefix(typed))).foregroundStyle(palette.fg)
            let caret = Text(OnboardingArtMetrics.caret).foregroundStyle(isLit ? AteColor.coral : .clear)
            Text("\(sofar)\(caret)")
                .ateText(.onboardingWords)
        }
    }

    /// The top three rows of the keyboard, fading out under the paper.
    private var keyboard: some View {
        let lit = typed > 0 ? String(words[words.index(words.startIndex, offsetBy: typed - 1)]).lowercased() : ""
        return VStack(spacing: OnboardingArtMetrics.keyGap + 3) {
            ForEach(OnboardingArtMetrics.keyRows, id: \.self) { row in
                HStack(spacing: OnboardingArtMetrics.keyGap) {
                    ForEach(row.map { String($0) }, id: \.self) { letter in
                        key(letter, isLit: letter == lit)
                    }
                }
            }
        }
        .mask {
            LinearGradient(colors: [palette.fg, palette.fg, .clear], startPoint: .top, endPoint: .bottom)
        }
    }

    private func key(_ letter: String, isLit: Bool) -> some View {
        Text(letter)
            .ateText(.onboardingKey)
            .foregroundStyle(palette.fg)
            .frame(width: OnboardingArtMetrics.key.width, height: OnboardingArtMetrics.key.height)
            .background(
                isLit ? palette.muted : palette.field,
                in: RoundedRectangle(cornerRadius: OnboardingArtMetrics.keyRadius, style: .continuous)
            )
            .scaleEffect(isLit ? OnboardingArtMetrics.litKeyScale : 1)
            .offset(y: isLit ? -AteMetrics.tight : 0)
    }
}

// MARK: - Photos

/// The camera roll, the margherita and the tiramisu picked (1, 2), and the slip with those two in its
/// cluster laid over the roll's last row.
private struct OnboardingPhotosArt: View {
    let sample: OnboardingSample

    @Environment(\.atePalette) private var palette

    var body: some View {
        VStack(spacing: -OnboardingArtMetrics.slipOverRoll) {
            roll
            AteEntrySlip(slip: sample.slip(photos: true, scores: false), surface: .journal)
                .ateShadow(.cover)
                .padding(.horizontal, AteMetrics.loose)
        }
    }

    private var roll: some View {
        let side = (OnboardingArtMetrics.canvas.width - OnboardingArtMetrics.rollGap * 2) / 3
        let columns = Array(repeating: GridItem(.fixed(side), spacing: OnboardingArtMetrics.rollGap), count: 3)
        return LazyVGrid(columns: columns, spacing: OnboardingArtMetrics.rollGap) {
            ForEach(Array(OnboardingSample.roll.enumerated()), id: \.offset) { index, name in
                tile(name, pick: OnboardingSample.picks[index], side: side)
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: OnboardingArtMetrics.rollRadius, style: .continuous))
    }

    private func tile(_ name: String, pick: Int?, side: CGFloat) -> some View {
        Image("Photos/\(name)")
            .resizable()
            .scaledToFill()
            .frame(width: side, height: side)
            .clipped()
            .overlay {
                if pick == nil {
                    palette.ground.opacity(OnboardingArtMetrics.unpickedDim)
                } else {
                    Rectangle().strokeBorder(AteColor.coral, lineWidth: AteMetrics.photoRing)
                }
            }
            .overlay(alignment: .topTrailing) {
                if let pick {
                    Text("\(pick)")
                        .ateText(.controlSmall)
                        .monospacedDigit()
                        .foregroundStyle(AteColor.ink)
                        .frame(width: OnboardingArtMetrics.pickBadge, height: OnboardingArtMetrics.pickBadge)
                        .background(AteColor.coral, in: .circle)
                        .overlay { Circle().strokeBorder(AteColor.overPhoto, lineWidth: 2) }
                        .padding(AteMetrics.snug)
                }
            }
    }
}

// MARK: - Scores

/// The slip with its dish rows and score tokens, and the slider under it with a finger at 4.5.
private struct OnboardingScoresArt: View {
    let sample: OnboardingSample

    @Environment(\.atePalette) private var palette

    var body: some View {
        VStack(spacing: AteMetrics.section) {
            AteEntrySlip(slip: sample.slip(photos: false, scores: true), surface: .journal)
                .ateShadow(.cover)
            StarSlider(dishName: OnboardingSample.firstDish, rating: .constant(Optional(OnboardingSample.first)))
                .overlay { finger }
        }
        .padding(.horizontal, AteMetrics.tight)
    }

    /// A fingertip on the fifth star's left half — 4.5 — with the slide it came along behind it.
    private var finger: some View {
        GeometryReader { proxy in
            let inset = OnboardingArtMetrics.sliderInset
            let track = proxy.size.width - inset * 2
            let across = inset + track * OnboardingArtMetrics.fingerAt
            let down = proxy.size.height - AteMetrics.loose - AteMetrics.starTrack / 2
            let trail = track * OnboardingArtMetrics.trailLength
            Capsule()
                .fill(LinearGradient(
                    colors: [.clear, palette.fg.opacity(OnboardingArtMetrics.trailOpacity)],
                    startPoint: .leading, endPoint: .trailing
                ))
                .frame(width: trail, height: OnboardingArtMetrics.fingertip)
                .position(x: across - trail / 2, y: down)
            Circle()
                .fill(palette.fg.opacity(OnboardingArtMetrics.fingerFill))
                .overlay { Circle().strokeBorder(palette.fg.opacity(OnboardingArtMetrics.fingerRing), lineWidth: 1.5) }
                .frame(width: OnboardingArtMetrics.fingertip, height: OnboardingArtMetrics.fingertip)
                .position(x: across, y: down)
        }
    }
}

// MARK: - Share

/// The ink share sheet as it opens on the sample: the sticker (on butter paper), the story and the
/// post fanned out, the story's grounds under them, then the row of apps with Stories pulsing.
private struct OnboardingShareArt: View {
    let sample: OnboardingSample
    let handle: String
    let isShowing: Bool

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.atePalette) private var palette

    var body: some View {
        let receipt = sample.receipt(handle: handle)
        VStack(spacing: AteMetrics.loose) {
            ZStack {
                AteShareCardPreview(
                    card: AteShareCard(format: .sticker, receipt: receipt, look: AteShareLook(paper: .butter)),
                    width: OnboardingArtMetrics.stickerWidth
                )
                .rotationEffect(.degrees(-OnboardingArtMetrics.fanTilt))
                .offset(x: -OnboardingArtMetrics.fanSpread)
                AteShareCardPreview(
                    card: AteShareCard(format: .post, receipt: receipt, photo: sample.sharePhoto),
                    width: OnboardingArtMetrics.postWidth
                )
                .rotationEffect(.degrees(OnboardingArtMetrics.fanTilt))
                .offset(x: OnboardingArtMetrics.fanSpread)
                AteShareCardPreview(
                    card: AteShareCard(format: .story, receipt: receipt, photo: sample.sharePhoto),
                    width: OnboardingArtMetrics.storyWidth
                )
            }
            .frame(height: OnboardingArtMetrics.storyWidth * 16 / 9)
            HStack(spacing: V2ShareSheetMetrics.swatchGap) {
                ForEach(AteShareGround.allCases, id: \.self) { ground in
                    AteShareSwatch(
                        fill: AnyShapeStyle(ground.colour), photo: ground == .photo ? sample.sharePhoto : nil,
                        label: ground.rawValue, isSelected: ground == .photo
                    ) {}
                }
                AteShareSwatch(icon: .crop, label: "Adjust photo") {}
            }
            AteShareRow(actions: OnboardingSample.shareActions)
                .overlay(alignment: .topLeading) { pulse }
        }
    }

    /// A ring going out from Stories, the first way out. Still, with Reduce Motion.
    @ViewBuilder
    private var pulse: some View {
        Group {
            if isShowing, reduceMotion == false {
                ring.phaseAnimator([false, true]) { content, isOut in
                    content
                        .scaleEffect(isOut ? OnboardingArtMetrics.pulseScale : 1)
                        .opacity(isOut ? 0 : 1)
                } animation: { isOut in
                    isOut ? .easeOut(duration: OnboardingArtMetrics.pulseDuration) : nil
                }
            } else {
                ring
            }
        }
        .padding(.leading, AteShareRowMetrics.scrollInset
            + (AteShareRowMetrics.scrollItem - AteShareRowMetrics.scrollDisc) / 2)
    }

    private var ring: some View {
        Circle()
            .strokeBorder(palette.fg, lineWidth: 2)
            .frame(width: AteShareRowMetrics.scrollDisc, height: AteShareRowMetrics.scrollDisc)
    }
}

// MARK: - Metrics

/// `onboarding-cards.html`, in points.
enum OnboardingArtMetrics {
    /// Every card's picture is drawn on this, then scaled to the room the card has.
    static let canvas = CGSize(width: 362, height: 460)
    /// A taller phone shows it a little bigger, never more than this.
    static let maximumScale: CGFloat = 1.1

    // Write
    static let olderTilt: (Double, Double) = (-3.5, 2.5)
    static let olderInset: CGFloat = 22
    static let olderStep: CGFloat = 26
    static let olderHeight: CGFloat = 60
    static let paperTop: CGFloat = 62
    static let placeIcon: CGFloat = 14
    static let caret = "|"
    static let caretBlink: TimeInterval = 0.5
    static let typingStart: Duration = .milliseconds(450)
    static let keystroke: Duration = .milliseconds(45)
    static let keyRows = ["qwertyuiop", "asdfghjkl", "zxcvbnm"]
    static let key = CGSize(width: 31, height: 42)
    static let keyGap: CGFloat = 5
    static let keyRadius: CGFloat = 8
    static let litKeyScale: CGFloat = 1.12

    // Photos
    static let rollGap: CGFloat = 3
    static let rollRadius: CGFloat = 24
    static let slipOverRoll: CGFloat = 110
    static let unpickedDim: Double = 0.45
    static let pickBadge: CGFloat = 28

    // Scores
    /// `StarSlider`'s own side padding: the track runs inside it.
    static let sliderInset: CGFloat = 18
    /// 4.5 is the fifth star's left half: 0.8–0.9 of the track.
    static let fingerAt: CGFloat = 0.85
    static let trailLength: CGFloat = 0.4
    static let trailOpacity: Double = 0.14
    static let fingertip: CGFloat = 44
    static let fingerFill: Double = 0.2
    static let fingerRing: Double = 0.5

    // Share
    static let storyWidth: CGFloat = 160
    static let postWidth: CGFloat = 150
    static let stickerWidth: CGFloat = 132
    static let fanTilt: Double = 6
    static let fanSpread: CGFloat = 112
    static let pulseScale: CGFloat = 1.35
    static let pulseDuration: Double = 1.6
}
