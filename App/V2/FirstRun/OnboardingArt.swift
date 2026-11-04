import AteKit
import SwiftUI

/// **What each card shows** (`design/rebuild/onboarding-calm.html`, approved 17 Oct). One real entry
/// made the way people actually make one (Eamon: no AI photography, less frantic). The only photos
/// are the details card's two real ones. Each card shows one thing happening to it, then holds still:
///
/// - **Write** — the composer's paper: the place in its pill, the review appearing word by word,
///   and a score dropping in after each dish while the Score key lights.
/// - **Details** — the same paper. Who you ate with drops into the top line, the photos key lights
///   and the pizza and tiramisu land, then the Diet key opens into every code, V lights and lands on
///   the margherita. It holds with the codes open, so the card shows what the key holds
///   (`design/rebuild/onboarding-diet-details.html`, Eamon 25 Oct: show the options, add photos).
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
    /// The details card: its photos so far, the photos key lit as they land, and the Diet key's codes
    /// open with the one it picks on. Their room is held whenever `holdsPhotos`, so nothing jumps.
    var holdsPhotos = false
    var photos: [AtePhoto] = []
    var isAddingPhotos = false
    var isChoosingDiet = false
    var picked: DietTag?
    /// Where the touch dot is (``AteTouchDot``): on the key the card is about to press.
    var touch = AteTouch()
    /// The Write card's words still fading in (Eamon, 4 Nov: fade in word by word rather than
    /// type). Every word is laid out from the start and only its colour comes up, in one label.
    var fades: [InlineTokenFade] = []

    @Environment(\.atePalette) private var palette

    var body: some View {
        VStack(alignment: .leading, spacing: AteMetrics.loose) {
            AteComposerByline(place: OnboardingSample.place, people: people, onPlace: {}, onPeople: {})
            ZStack(alignment: .topLeading) {
                InlineTokenText(composition: finished, style: .onboardingWords).hidden()
                InlineTokenText(composition: words, style: .onboardingWords, fades: fades)
            }
            .padding(.horizontal, AteMetrics.gutter)
            if holdsPhotos {
                ZStack(alignment: .topLeading) {
                    cluster(OnboardingSample.photos).hidden()
                    cluster(photos)
                }
                .padding(.horizontal, AteMetrics.gutter)
            }
            ComposerDietUnfold(isChoosingDiet: isChoosingDiet, keys: keys, back: back) { tag in
                AteKey(kind: .code(tag), isActive: tag == picked) {}
                    .ateTouchTarget(tag == .v ? .code : nil)
            }
            .padding(.horizontal, AteMetrics.slipPadding)
        }
        .padding(.top, AteMetrics.slipPadding)
        .padding(.bottom, AteMetrics.slipPadding + AteMetrics.tornEdgeHeight)
        .frame(maxWidth: .infinity, alignment: .leading)
        .ateTornPaper(.slip)
        .ateShadow(.lift)
        .ateTouchDot(touch)
    }

    private func cluster(_ photos: [AtePhoto]) -> some View {
        AtePhotoCluster(photos: photos, surface: AtePaperTone.slip.fill, onTap: { _ in })
    }

    private var back: some View {
        AteIcon.back.view(size: OnboardingArtMetrics.photosIcon)
            .foregroundStyle(palette.fg)
            .frame(width: AteMetrics.hit, height: AteMetrics.hit)
    }

    /// The composer's own keys: the photos, Score, and Diet, each lighting as the card uses it.
    private var keys: some View {
        HStack(spacing: AteMetrics.snug) {
            AteIcon.library.view(size: OnboardingArtMetrics.photosIcon)
                .foregroundStyle(isAddingPhotos ? palette.inverted : palette.fg)
                .frame(width: OnboardingArtMetrics.photosKey, height: OnboardingArtMetrics.photosKey)
                .background(isAddingPhotos ? palette.solid : .clear, in: .circle)
                .ateTouchTarget(.photos)
                .padding(.leading, -OnboardingArtMetrics.photosKeyOutset)
            Spacer(minLength: 0)
            ComposerKey(
                title: "Score", icon: .starFilled, background: AteColor.scoreFill, foreground: AteColor.scoreInk,
                isActive: isScoring, activeForeground: AteColor.butter
            ) {}
            .ateTouchTarget(.score)
            ComposerKey(
                title: "Diet", icon: .diet, iconSize: 16, background: ComposerKeyColor.place,
                foreground: ComposerKeyColor.placeInk, isActive: isTagging, iconOnly: true
            ) {}
            .ateTouchTarget(.diet)
        }
    }
}

// MARK: - Write


/// The review appearing word by word, a score pill dropping in after each dish as the Score key lights.
private struct OnboardingWriteArt: View {
    let isShowing: Bool

    // Each card waits at its first frame until it is the page on screen, so a card swiped in is
    // the empty paper that then fills, never the finished one that empties and refills (Eamon,
    // 4 Nov: the second and third cards glitched when swiped to).
    @State private var typed = 0
    /// When each step arrived, for its fade.
    @State private var arrivals: [Int: Date] = [:]
    /// No word is mid-fade: the clock below stops.
    @State private var isSettled = true
    @State private var isScoring = false
    @State private var touch = AteTouch()
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        // One label with every word in it, redrawn on the display's clock only while a word fades:
        // nothing is added, removed or resized as the words come up, so nothing can jump (build
        // 282's layered labels each resized under the fade's animation and shook).
        TimelineView(.animation(minimumInterval: OnboardingArtMetrics.fadeTick, paused: isSettled)) { context in
            let arrival = OnboardingSample.arriving(typed: typed)
            OnboardingPaper(
                words: arrival.composition,
                finished: OnboardingSample.words(tagged: false),
                isScoring: isScoring,
                touch: touch,
                fades: fades(arrival, at: context.date)
            )
        }
        .animation(reduceMotion ? nil : OnboardingArtMetrics.press, value: isScoring)
        .task(id: isShowing) { await type() }
    }

    /// Every word not fully in yet: unseen before its step, then up over `wordFade`.
    private func fades(_ arrival: OnboardingArrival, at now: Date) -> [InlineTokenFade] {
        arrival.words.compactMap { word in
            let opacity: Double
            if word.step >= typed {
                opacity = 0
            } else if let arrived = arrivals[word.step] {
                opacity = min(1, now.timeIntervalSince(arrived) / OnboardingArtMetrics.wordFade)
            } else {
                opacity = 1
            }
            return opacity < 1 ? InlineTokenFade(range: word.range, opacity: opacity) : nil
        }
    }

    /// One more word (or pill), fading in.
    private func step() {
        arrivals[typed] = .now
        typed += 1
    }

    private func type() async {
        let steps = OnboardingSample.steps(tagged: false)
        isScoring = false
        touch = AteTouch()
        arrivals = [:]
        isSettled = true
        guard reduceMotion == false else {
            typed = steps
            return
        }
        typed = 0
        guard isShowing else { return }
        isSettled = false
        defer { isSettled = true }
        try? await Task.sleep(for: OnboardingArtMetrics.typingStart)
        while typed < steps {
            if Task.isCancelled { return }
            if OnboardingSample.isToken(step: typed, tagged: false) {
                // The pill, as the composer makes one: the dot lands on the Score key, the key goes
                // down, the score drops in, and the dot lifts off.
                touch.target = .score
                try? await Task.sleep(for: OnboardingArtMetrics.touchLead)
                isScoring = true
                touch.isDown = true
                try? await Task.sleep(for: OnboardingArtMetrics.scoreHold)
                step()
                touch.isDown = false
                try? await Task.sleep(for: OnboardingArtMetrics.scoreHold)
                isScoring = false
                touch.target = nil
            } else {
                try? await Task.sleep(for: OnboardingArtMetrics.keystroke)
                step()
            }
        }
        // The last word's fade, before the clock stops.
        try? await Task.sleep(for: .seconds(OnboardingArtMetrics.wordFade))
    }
}

// MARK: - Details

/// The same paper: who you ate with drops into the byline, the two photos land, then the Diet key
/// opens into its codes, V lights, and a V lands on the margherita. It holds there, codes open.
private struct OnboardingDetailsArt: View {
    let isShowing: Bool

    @State private var hasPeople = false
    @State private var photoCount = 0
    @State private var isAddingPhotos = false
    @State private var isTagging = false
    @State private var isChoosingDiet = false
    @State private var isPicked = false
    @State private var isTagged = false
    @State private var touch = AteTouch()
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        OnboardingPaper(
            words: OnboardingSample.words(tagged: isTagged),
            finished: OnboardingSample.words(tagged: true),
            people: hasPeople ? [OnboardingSample.friend] : [],
            isTagging: isTagging,
            holdsPhotos: true,
            photos: Array(OnboardingSample.photos.prefix(photoCount)),
            isAddingPhotos: isAddingPhotos,
            isChoosingDiet: isChoosingDiet,
            picked: isPicked ? .v : nil,
            touch: touch
        )
        .task(id: isShowing) { await play() }
    }

    private func play() async {
        isTagging = false
        isAddingPhotos = false
        touch = AteTouch()
        guard reduceMotion == false else {
            hasPeople = true
            photoCount = OnboardingSample.photos.count
            isChoosingDiet = true
            isPicked = true
            isTagged = true
            return
        }
        hasPeople = false
        photoCount = 0
        isChoosingDiet = false
        isPicked = false
        isTagged = false
        guard isShowing, await beat(OnboardingArtMetrics.detailsStart) else { return }
        withAnimation(OnboardingArtMetrics.drop) { hasPeople = true }
        guard await beat(OnboardingArtMetrics.detailsBeat), await addPhotos() else { return }
        // The Diet key goes down and unfolds into every code; V lights, then lands in the words.
        guard await beat(OnboardingArtMetrics.detailsBeat) else { return }
        guard await tap(.diet, press: {
            withAnimation(OnboardingArtMetrics.press) { isTagging = true }
        }) else { return }
        touch.target = nil
        guard await beat(OnboardingArtMetrics.scoreHold) else { return }
        isTagging = false
        isChoosingDiet = true
        guard await beat(OnboardingArtMetrics.codesBeat) else { return }
        guard await tap(.code, press: {
            withAnimation(OnboardingArtMetrics.press) { isPicked = true }
        }) else { return }
        touch.target = nil
        guard await beat(OnboardingArtMetrics.scoreHold) else { return }
        withAnimation(OnboardingArtMetrics.drop) { isTagged = true }
    }

    /// The photos: the dot lands on the key, it goes down, the two land one after the other.
    private func addPhotos() async -> Bool {
        guard await tap(.photos, press: {
            withAnimation(OnboardingArtMetrics.press) { isAddingPhotos = true }
        }) else { return false }
        for _ in OnboardingSample.photos {
            guard await beat(OnboardingArtMetrics.scoreHold) else { return false }
            withAnimation(OnboardingArtMetrics.drop) { photoCount += 1 }
        }
        touch.target = nil
        guard await beat(OnboardingArtMetrics.scoreHold) else { return false }
        withAnimation(OnboardingArtMetrics.press) { isAddingPhotos = false }
        return true
    }

    /// Waits `duration`; false when the card left in the meantime.
    private func beat(_ duration: Duration) async -> Bool {
        try? await Task.sleep(for: duration)
        return Task.isCancelled == false
    }

    /// The dot lands on `target`, goes down doing `press`, and comes up, still on the key.
    private func tap(_ target: AteTouchTarget, press: () -> Void) async -> Bool {
        touch.target = target
        guard await beat(OnboardingArtMetrics.touchLead) else { return false }
        touch.isDown = true
        press()
        let stayed = await beat(OnboardingArtMetrics.tap)
        touch.isDown = false
        return stayed
    }
}

// MARK: - Share

/// The entry as everyone sees it in the Feed: it rises into place, then the margherita is saved.
private struct OnboardingShareArt: View {
    let handle: String
    let isShowing: Bool

    @State private var isRisen = false
    @State private var isSaved = false
    @State private var touch = AteTouch()
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        AteEntrySlip(
            slip: OnboardingSample.feedSlip(handle: handle, isSaved: isSaved),
            surface: .feed,
            onSave: { _ in }
        )
        .ateShadow(.lift)
        .environment(\.ateMarksSaveTarget, true)
        .ateTouchDot(touch)
        .padding(.horizontal, AteMetrics.tight)
        .opacity(isRisen ? 1 : 0)
        .offset(y: isRisen ? 0 : OnboardingArtMetrics.rise)
        .task(id: isShowing) { await play() }
    }

    private func play() async {
        touch = AteTouch()
        guard reduceMotion == false else {
            isRisen = true
            isSaved = true
            return
        }
        isRisen = false
        isSaved = false
        guard isShowing else { return }
        try? await Task.sleep(for: OnboardingArtMetrics.riseStart)
        guard Task.isCancelled == false else { return }
        withAnimation(OnboardingArtMetrics.risen) { isRisen = true }
        try? await Task.sleep(for: OnboardingArtMetrics.saveAfter)
        guard Task.isCancelled == false else { return }
        touch.target = .save
        try? await Task.sleep(for: OnboardingArtMetrics.touchLead)
        guard Task.isCancelled == false else { return }
        touch.isDown = true
        withAnimation(OnboardingArtMetrics.drop) { isSaved = true }
        try? await Task.sleep(for: OnboardingArtMetrics.tap)
        touch.isDown = false
        touch.target = nil
    }
}

// MARK: - Metrics

/// `onboarding-calm.html`, in points and seconds.
enum OnboardingArtMetrics {
    /// Every card's picture is drawn on this (`.art`: 24 in from each side of a 402 phone), then
    /// scaled down where the card has less room. Never up.
    static let canvas = CGSize(width: 354, height: 440)
    static let inset: CGFloat = 24
    static let maximumScale: CGFloat = 1
    static let photosIcon: CGFloat = 22
    /// The photos key's lit disc: a composer key's 40, its glyph where the bare icon sat.
    static let photosKey: CGFloat = AteMetrics.keyHeight
    static let photosKeyOutset: CGFloat = (AteMetrics.keyHeight - 22) / 2

    // Write
    // Quick on purpose (Eamon, 3 Nov: the typing was too slow): a word per step, the whole card
    // done in about two seconds rather than seven.
    static let typingStart: Duration = .milliseconds(250)
    /// One word, with its space: a new one every 80ms, each fading in over 0.24s, so about three
    /// are arriving at once and none snaps in.
    static let keystroke: Duration = .milliseconds(80)
    static let wordFade: TimeInterval = 0.24
    /// How often a fading word is redrawn.
    static let fadeTick: TimeInterval = 1.0 / 30
    static let scoreHold: Duration = .milliseconds(250)
    /// The touch dot settling on a key before it presses, and how long a tap holds it down.
    static let touchLead: Duration = .milliseconds(220)
    static let tap: Duration = .milliseconds(180)

    // Details
    static let detailsStart: Duration = .milliseconds(350)
    static let detailsBeat: Duration = .milliseconds(550)
    /// The codes unfold before V lights.
    static let codesBeat: Duration = .milliseconds(500)

    // Share
    static let rise: CGFloat = 24
    static let riseStart: Duration = .milliseconds(100)
    static let saveAfter: Duration = .milliseconds(700)

    static let press = Animation.easeOut(duration: 0.15)
    static let drop = Animation.spring(response: 0.4, dampingFraction: 0.6)
    static let risen = Animation.spring(response: 0.7, dampingFraction: 0.85)
}
