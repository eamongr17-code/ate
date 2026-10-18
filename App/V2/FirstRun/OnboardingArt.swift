import AteKit
import SwiftUI

/// **What each card shows** (`design/rebuild/onboarding-calm.html`, approved 17 Oct). One real entry
/// made the way people actually make one, with no photos anywhere (Eamon: no AI photography, less
/// frantic). Each card shows one thing happening to it, then holds still:
///
/// - **Write** — the composer's paper: the place in its pill, the review typing itself out, and a
///   score dropping in after each dish while the Score key lights.
/// - **Details** — the same paper. Who you ate with drops into the top line, then the Diet key
///   lights and a V lands on the margherita.
/// - **Share** — the entry as the Feed shows it, rising into place; then someone saves the
///   margherita.
///
/// Built from the kit (``AteComposerByline``, ``InlineTokenText``, ``ComposerKey``,
/// ``AteEntrySlip``), drawn on one canvas (``OnboardingArtMetrics/canvas``) and scaled down as a
/// whole where the card has less room, never past its size in the mockup. Nothing here is
/// tappable. With Reduce Motion each card is simply its finished picture.
struct OnboardingArt: View {
    let card: OnboardingCard
    let handle: String
    /// The card is on screen: its motion runs only then.
    let isShowing: Bool

    var body: some View {
        GeometryReader { proxy in
            let canvas = OnboardingArtMetrics.canvas
            let width = proxy.size.width - OnboardingArtMetrics.inset * 2
            let scale = min(
                OnboardingArtMetrics.maximumScale,
                width / canvas.width,
                proxy.size.height / canvas.height
            )
            stage
                .frame(width: canvas.width, height: canvas.height)
                .scaleEffect(scale, anchor: .center)
                .frame(width: proxy.size.width, height: proxy.size.height)
        }
    }

    @ViewBuilder
    private var stage: some View {
        switch card {
        case .write: OnboardingWriteArt(isShowing: isShowing)
        case .details: OnboardingDetailsArt(isShowing: isShowing)
        case .share: OnboardingShareArt(handle: handle, isShowing: isShowing)
        }
    }
}

// MARK: - The composer's paper

/// The composer as the cards draw it: the byline, the words, and the keys, on the entry's paper.
/// The words' room is held at the finished entry's height, so the paper never grows as they type.
private struct OnboardingPaper: View {
    let words: EntryComposition
    let finished: EntryComposition
    var people: [AteWithPerson] = []
    var isScoring = false
    var isTagging = false

    @Environment(\.atePalette) private var palette

    var body: some View {
        VStack(alignment: .leading, spacing: AteMetrics.loose) {
            AteComposerByline(place: OnboardingSample.place, people: people, onPlace: {}, onPeople: {})
            ZStack(alignment: .topLeading) {
                InlineTokenText(composition: finished, style: .onboardingWords).hidden()
                InlineTokenText(composition: words, style: .onboardingWords)
            }
            .padding(.horizontal, AteMetrics.gutter)
            keys
                .padding(.horizontal, AteMetrics.slipPadding)
        }
        .padding(.top, AteMetrics.slipPadding)
        .padding(.bottom, AteMetrics.slipPadding + AteMetrics.tornEdgeHeight)
        .frame(maxWidth: .infinity, alignment: .leading)
        .ateTornPaper(.slip)
        .ateShadow(.lift)
    }

    /// The composer's own keys: the photos, Score, and Diet, each lighting as the card uses it.
    private var keys: some View {
        HStack(spacing: AteMetrics.snug) {
            AteIcon.library.view(size: OnboardingArtMetrics.photosIcon)
                .foregroundStyle(palette.fg)
            Spacer(minLength: 0)
            ComposerKey(
                title: "Score", icon: .starFilled, background: AteColor.scoreFill, foreground: AteColor.scoreInk,
                isActive: isScoring, activeForeground: AteColor.butter
            ) {}
            ComposerKey(
                title: "Diet", icon: .diet, iconSize: 16, background: ComposerKeyColor.place,
                foreground: ComposerKeyColor.placeInk, isActive: isTagging, iconOnly: true
            ) {}
        }
    }
}

// MARK: - Write

/// The review typing itself out, a score pill dropping in after each dish as the Score key lights.
private struct OnboardingWriteArt: View {
    let isShowing: Bool

    @State private var typed = OnboardingSample.steps(tagged: false)
    @State private var isScoring = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        OnboardingPaper(
            words: OnboardingSample.words(tagged: false, typed: typed),
            finished: OnboardingSample.words(tagged: false),
            isScoring: isScoring
        )
        .animation(reduceMotion ? nil : OnboardingArtMetrics.press, value: isScoring)
        .task(id: isShowing) { await type() }
    }

    private func type() async {
        let steps = OnboardingSample.steps(tagged: false)
        isScoring = false
        guard isShowing, reduceMotion == false else {
            typed = steps
            return
        }
        typed = 0
        try? await Task.sleep(for: OnboardingArtMetrics.typingStart)
        while typed < steps {
            if Task.isCancelled { return }
            if OnboardingSample.isToken(step: typed, tagged: false) {
                // The pill, as the composer makes one: the Score key goes down, the score drops in.
                isScoring = true
                try? await Task.sleep(for: OnboardingArtMetrics.scoreHold)
                typed += 1
                try? await Task.sleep(for: OnboardingArtMetrics.scoreHold)
                isScoring = false
            } else {
                try? await Task.sleep(for: OnboardingArtMetrics.keystroke)
                typed += 1
            }
        }
    }
}

// MARK: - Details

/// The same paper: who you ate with drops into the byline, then a V lands on the margherita.
private struct OnboardingDetailsArt: View {
    let isShowing: Bool

    @State private var hasPeople = true
    @State private var isTagging = false
    @State private var isTagged = true
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        OnboardingPaper(
            words: OnboardingSample.words(tagged: isTagged),
            finished: OnboardingSample.words(tagged: true),
            people: hasPeople ? [OnboardingSample.friend] : [],
            isTagging: isTagging
        )
        .task(id: isShowing) { await play() }
    }

    private func play() async {
        isTagging = false
        guard isShowing, reduceMotion == false else {
            hasPeople = true
            isTagged = true
            return
        }
        hasPeople = false
        isTagged = false
        try? await Task.sleep(for: OnboardingArtMetrics.detailsStart)
        guard Task.isCancelled == false else { return }
        withAnimation(OnboardingArtMetrics.drop) { hasPeople = true }
        try? await Task.sleep(for: OnboardingArtMetrics.detailsBeat)
        guard Task.isCancelled == false else { return }
        withAnimation(OnboardingArtMetrics.press) { isTagging = true }
        try? await Task.sleep(for: OnboardingArtMetrics.scoreHold)
        guard Task.isCancelled == false else { return }
        withAnimation(OnboardingArtMetrics.drop) { isTagged = true }
        try? await Task.sleep(for: OnboardingArtMetrics.scoreHold)
        withAnimation(OnboardingArtMetrics.press) { isTagging = false }
    }
}

// MARK: - Share

/// The entry as everyone sees it in the Feed: it rises into place, then the margherita is saved.
private struct OnboardingShareArt: View {
    let handle: String
    let isShowing: Bool

    @State private var isRisen = true
    @State private var isSaved = true
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        AteEntrySlip(
            slip: OnboardingSample.feedSlip(handle: handle, isSaved: isSaved),
            surface: .feed,
            onSave: { _ in }
        )
        .ateShadow(.lift)
        .padding(.horizontal, AteMetrics.tight)
        .opacity(isRisen ? 1 : 0)
        .offset(y: isRisen ? 0 : OnboardingArtMetrics.rise)
        .task(id: isShowing) { await play() }
    }

    private func play() async {
        guard isShowing, reduceMotion == false else {
            isRisen = true
            isSaved = true
            return
        }
        isRisen = false
        isSaved = false
        try? await Task.sleep(for: OnboardingArtMetrics.riseStart)
        guard Task.isCancelled == false else { return }
        withAnimation(OnboardingArtMetrics.risen) { isRisen = true }
        try? await Task.sleep(for: OnboardingArtMetrics.saveAfter)
        guard Task.isCancelled == false else { return }
        withAnimation(OnboardingArtMetrics.drop) { isSaved = true }
    }
}

// MARK: - Metrics

/// `onboarding-calm.html`, in points and seconds.
enum OnboardingArtMetrics {
    /// Every card's picture is drawn on this (`.art`: 24 in from each side of a 402 phone), then
    /// scaled down where the card has less room. Never up.
    static let canvas = CGSize(width: 354, height: 400)
    static let inset: CGFloat = 24
    static let maximumScale: CGFloat = 1
    static let photosIcon: CGFloat = 22

    // Write
    static let typingStart: Duration = .milliseconds(450)
    static let keystroke: Duration = .milliseconds(38)
    static let scoreHold: Duration = .milliseconds(350)

    // Details
    static let detailsStart: Duration = .milliseconds(900)
    static let detailsBeat: Duration = .milliseconds(1000)

    // Share
    static let rise: CGFloat = 24
    static let riseStart: Duration = .milliseconds(150)
    static let saveAfter: Duration = .milliseconds(1800)

    static let press = Animation.easeOut(duration: 0.15)
    static let drop = Animation.spring(response: 0.4, dampingFraction: 0.6)
    static let risen = Animation.spring(response: 0.7, dampingFraction: 0.85)
}
