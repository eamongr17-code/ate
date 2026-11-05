import AteKit
import SwiftUI

/// **What the tutorial shows** (`mockups/onboarding-calmer.html`, Eamon 4 Nov): the composer, at one
/// fixed size, writing one entry a step at a time, then that entry as the Feed shows it.
///
/// - **Write** — "The margherita pizza", a word at a time, then the Score key lights and ★ 4.5 lands.
/// - **Thought** — "was truly the best pizza I've had in Melbourne."
/// - **Next dish** — "The tiramisu", the Diet key lights and V lands, the Score key lights and ★ 2.5
///   lands, then "was underwhelming."
/// - **Details** — the People pill becomes "with @jess", then the library key lights and the pizza
///   and tiramisu photos land above the keys.
/// - **Share** — the composer gives way to the finished entry, rising in as the Feed prints it.
///
/// Only what has been written is laid out: each piece arrives at the end of the words, the way it
/// would as you type, and nothing waits unseen for its turn. The composer never grows; the words
/// grow inside it and the photos sit at its foot, as in the real one. Each step plays once and then
/// holds still. Built from the kit (``AteSheetHeader``, ``AteComposerByline``, ``InlineTokenText``,
/// ``AtePhotoCluster``, ``AteKeyCapsule``, ``AteEntrySlip``) on one canvas
/// (``OnboardingArtMetrics/canvas``), scaled down as a whole where the screen has less room. Nothing
/// here is tappable. With Reduce Motion each step is simply its finished picture.
struct OnboardingArt: View {
    let card: OnboardingCard
    let handle: String

    /// The step whose picture is up: finished, or playing. A step one past it plays; any other
    /// (back, or a jump) is drawn finished at once.
    @State private var shown: OnboardingCard?
    /// How many beats of ``OnboardingSample/script`` are written.
    @State private var written = 0
    /// When each beat landed, for its fade.
    @State private var arrivals: [Int: Date] = [:]
    /// No word is mid-fade: the clock below stops.
    @State private var isSettled = true
    @State private var lit: OnboardingKey?
    @State private var people: [AteWithPerson] = []
    @State private var photoCount = 0
    @State private var showsFeed = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

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
                .frame(width: canvas.width, height: canvas.height, alignment: .top)
                .scaleEffect(scale, anchor: .center)
                .frame(width: proxy.size.width, height: proxy.size.height)
        }
        .task(id: card) { await play(card) }
    }

    private var stage: some View {
        ZStack(alignment: .top) {
            // One label with every written word in it, redrawn on the display's clock only while a
            // word fades: words are only ever added at the end and nothing is resized under an
            // animation, so nothing already written can move (build 282 shook with layered labels).
            TimelineView(.animation(minimumInterval: OnboardingArtMetrics.fadeTick, paused: isSettled)) { context in
                let words = OnboardingSample.composition(written: written)
                OnboardingComposer(
                    words: words.composition,
                    fades: fades(words.ranges, at: context.date),
                    people: people,
                    photos: Array(OnboardingSample.photos.prefix(photoCount)),
                    lit: lit
                )
            }
            .opacity(showsFeed ? 0 : 1)
            .scaleEffect(showsFeed ? OnboardingArtMetrics.composerAway : 1)
            if showsFeed {
                AteEntrySlip(slip: OnboardingSample.feedSlip(handle: handle), surface: .feed, onSave: { _ in })
                    .ateShadow(.lift)
                    .padding(.horizontal, AteMetrics.tight)
                    // The card is shorter than the composer it replaces: it sits in the middle of the
                    // composer's room, not at its top with the gap all below (build 284).
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .transition(
                        .asymmetric(
                            insertion: .opacity.combined(with: .offset(y: OnboardingArtMetrics.rise)),
                            removal: .opacity
                        )
                    )
            }
        }
    }

    /// Every word still coming up: from clear to full over `wordFade` after it landed. A pill is drawn
    /// whole the moment its key goes down.
    private func fades(_ ranges: [NSRange], at now: Date) -> [InlineTokenFade] {
        arrivals.compactMap { beat, arrived in
            guard beat < ranges.count, case .word = OnboardingSample.script[beat] else { return nil }
            let opacity = min(1, max(0, now.timeIntervalSince(arrived) / OnboardingArtMetrics.wordFade))
            return opacity < 1 ? InlineTokenFade(range: ranges[beat], opacity: opacity) : nil
        }
    }

    // MARK: - Playing a step

    private func play(_ card: OnboardingCard) async {
        let playsOn = reduceMotion == false && (card.previous == shown)
        guard playsOn else { return settle(card) }
        if let previous = card.previous { settle(previous) }
        shown = card
        guard await beat(OnboardingArtMetrics.stepStart) else { return }
        switch card {
        case .write, .thought, .nextDish:
            await write(card)
        case .details:
            await details()
        case .share:
            withAnimation(OnboardingArtMetrics.feedRise) { showsFeed = true }
        }
    }

    /// The step's beats, in order: a word fades in at the end of the words; a pill waits a moment,
    /// lights its key, lands, and lets the key go.
    private func write(_ card: OnboardingCard) async {
        isSettled = false
        defer { isSettled = true }
        var previous: OnboardingSample.Beat?
        for beat in OnboardingSample.beats(card) {
            switch beat {
            case .word:
                if case .pill? = previous, await self.beat(OnboardingArtMetrics.afterPill) == false { return }
                land()
                guard await self.beat(OnboardingArtMetrics.wordGap) else { return }
            case .pill(_, let key):
                guard await self.beat(OnboardingArtMetrics.beforePill) else { return }
                withAnimation(OnboardingArtMetrics.press) { lit = key }
                guard await self.beat(OnboardingArtMetrics.keyLead) else { return }
                land()
                guard await self.beat(OnboardingArtMetrics.keyHold) else { return }
                withAnimation(OnboardingArtMetrics.press) { lit = nil }
            }
            previous = beat
        }
        // The last word's fade, before the clock stops.
        _ = await self.beat(.seconds(OnboardingArtMetrics.wordFade))
    }

    /// Who you were with fills the People pill; then the library key lights and the photos land, one
    /// after the other.
    private func details() async {
        withAnimation(OnboardingArtMetrics.drop) { people = [OnboardingSample.friend] }
        guard await beat(OnboardingArtMetrics.detailsBeat) else { return }
        withAnimation(OnboardingArtMetrics.press) { lit = .photos }
        guard await beat(OnboardingArtMetrics.keyLead) else { return }
        for _ in OnboardingSample.photos {
            withAnimation(OnboardingArtMetrics.drop) { photoCount += 1 }
            guard await beat(OnboardingArtMetrics.photoGap) else { return }
        }
        withAnimation(OnboardingArtMetrics.press) { lit = nil }
    }

    /// One more beat written, fading in from now.
    private func land() {
        arrivals[written] = .now
        written += 1
    }

    /// `card` finished, at once: what a step swiped back to, a jump, or Reduce Motion shows.
    private func settle(_ card: OnboardingCard) {
        var still = Transaction()
        still.disablesAnimations = true
        withTransaction(still) {
            written = OnboardingSample.written(through: card)
            arrivals = [:]
            isSettled = true
            lit = nil
            people = card >= .details ? [OnboardingSample.friend] : []
            photoCount = card >= .details ? OnboardingSample.photos.count : 0
            showsFeed = card == .share
            shown = card
        }
    }

    /// Waits `duration`; false when the step changed in the meantime.
    private func beat(_ duration: Duration) async -> Bool {
        try? await Task.sleep(for: duration)
        return Task.isCancelled == false
    }
}

// MARK: - The composer

/// The composer as the tutorial draws it, at one size: close and the tick, where and who, the words,
/// the photos at the foot, the keys' glass capsule, and the top of the keyboard. The real composer's
/// parts, on its own surface; the tick lights once there are words, as it does with a place held.
private struct OnboardingComposer: View {
    let words: EntryComposition
    let fades: [InlineTokenFade]
    let people: [AteWithPerson]
    let photos: [AtePhoto]
    let lit: OnboardingKey?

    var body: some View {
        VStack(spacing: 0) {
            AteSheetHeader(
                title: nil,
                primary: AteSheetPrimary(icon: .check, label: "Post", isEnabled: words.isEmpty == false) {}
            ) {}
            .animation(OnboardingArtMetrics.press, value: words.isEmpty)
            AteComposerByline(place: OnboardingSample.place, people: people, onPlace: {}, onPeople: {})
                .padding(.top, AteMetrics.regular)
            InlineTokenText(composition: words, style: .onboardingWords, fades: fades)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, AteMetrics.gutter)
                .padding(.top, AteMetrics.snug)
            Spacer(minLength: AteMetrics.snug)
            if photos.isEmpty == false {
                AtePhotoCluster(photos: photos, size: .composer, surface: AtePalette.surface.ground, onTap: { _ in })
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, AteMetrics.gutter)
                    .padding(.bottom, AteMetrics.snug)
                    .transition(.scale(scale: OnboardingArtMetrics.photoArrival, anchor: .bottomLeading)
                        .combined(with: .opacity))
            }
            AteKeyCapsule(
                isScoring: lit == .score,
                isChoosingDiet: .constant(false),
                onCamera: {},
                onScore: {},
                onDiet: {},
                onCode: { _ in },
                isDietLit: lit == .diet,
                library: { OnboardingLibraryKey(isLit: lit == .photos) }
            )
            OnboardingKeyboard()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .environment(\.atePalette, .surface)
        .foregroundStyle(AtePalette.surface.fg)
        .background(AtePalette.surface.ground)
        .clipShape(.rect(cornerRadius: OnboardingArtMetrics.windowRadius))
        .ateShadow(.lift)
    }
}

/// The library key's face, lit in ink while the photos are being added.
private struct OnboardingLibraryKey: View {
    let isLit: Bool

    @Environment(\.atePalette) private var palette

    var body: some View {
        AteIcon.library.view(size: AteGlassDiscMetrics.glyph)
            .foregroundStyle(isLit ? palette.inverted : palette.fg)
            .frame(width: OnboardingArtMetrics.libraryLit, height: OnboardingArtMetrics.libraryLit)
            .background(isLit ? palette.solid : .clear, in: .circle)
            .frame(width: AteMetrics.hit, height: AteMetrics.hit)
    }
}

/// The top of the keyboard under the keys: two rows of letters, cut off by the composer's edge, so
/// the picture reads as writing.
private struct OnboardingKeyboard: View {
    private static let rows = ["qwertyuiop", "asdfghjkl"]

    var body: some View {
        VStack(spacing: OnboardingArtMetrics.keyRowGap) {
            ForEach(Self.rows, id: \.self) { row in
                HStack(spacing: OnboardingArtMetrics.keyGap) {
                    ForEach(row.map(String.init), id: \.self) { letter in
                        key(letter)
                    }
                }
            }
        }
        .padding(.top, OnboardingArtMetrics.keyboardTop)
        .frame(maxWidth: .infinity, alignment: .top)
        .frame(height: OnboardingArtMetrics.keyboardHeight, alignment: .top)
        .clipped()
        .background(AteKitColor.keyboard)
    }

    private func key(_ letter: String) -> some View {
        Text(letter)
            .ateText(.onboardingKeyLetter)
            .foregroundStyle(AteKitColor.keyboardLetter)
            .frame(width: OnboardingArtMetrics.keyWidth, height: OnboardingArtMetrics.keyHeight)
            .background {
                // The key's lower edge: the keyboard's own one-point shade under each key.
                RoundedRectangle(cornerRadius: OnboardingArtMetrics.keyRadius)
                    .fill(AteKitColor.keyboardKeyEdge)
                    .offset(y: 1)
                RoundedRectangle(cornerRadius: OnboardingArtMetrics.keyRadius)
                    .fill(AteKitColor.keyboardKey)
            }
    }
}

// MARK: - Metrics

/// The tutorial's picture: its canvas and its timing.
enum OnboardingArtMetrics {
    /// The canvas the picture is drawn on (`onboarding-calmer.html`: the composer 354 by 500), scaled
    /// down as a whole where the screen has less room, never up.
    static let canvas = CGSize(width: 354, height: 500)
    static let inset: CGFloat = 18
    static let maximumScale: CGFloat = 1
    static let windowRadius: CGFloat = 32

    /// The keyboard's top: two rows of 42pt keys, cut at 64.
    static let keyboardHeight: CGFloat = 64
    static let keyboardTop: CGFloat = 8
    static let keyWidth: CGFloat = 29
    static let keyHeight: CGFloat = 42
    static let keyGap: CGFloat = 5
    static let keyRowGap: CGFloat = 11
    static let keyRadius: CGFloat = 6
    /// The library key's ink disc while lit: the capsule's keys are 40.
    static let libraryLit: CGFloat = 40

    // The timing. One piece at a time, unhurried: a word every 0.13s, fading up over 0.28s; a pill
    // waits, lights its key, lands, and holds the key a moment.
    /// Before the step's first piece, while its title comes up.
    static let stepStart: Duration = .milliseconds(450)
    static let wordGap: Duration = .milliseconds(130)
    static let wordFade: TimeInterval = 0.28
    /// The fade's clock: 30 a second is smooth for an opacity and half the work of 60.
    static let fadeTick: TimeInterval = 1.0 / 30
    static let beforePill: Duration = .milliseconds(250)
    static let keyLead: Duration = .milliseconds(200)
    static let keyHold: Duration = .milliseconds(280)
    static let afterPill: Duration = .milliseconds(250)
    /// From the People pill filling to the library key lighting.
    static let detailsBeat: Duration = .milliseconds(650)
    static let photoGap: Duration = .milliseconds(320)
    /// A photo grows in from 80% at the cluster's corner.
    static let photoArrival: CGFloat = 0.8
    /// The Feed slip rises 24 into place as the composer recedes to 96%.
    static let rise: CGFloat = 24
    static let composerAway: CGFloat = 0.96

    static let press = Animation.easeOut(duration: 0.15)
    static let drop = Animation.spring(response: 0.4, dampingFraction: 0.72)
    static let feedRise = Animation.spring(response: 0.6, dampingFraction: 0.88)
    static let titleFade = Animation.easeInOut(duration: 0.25)
}
