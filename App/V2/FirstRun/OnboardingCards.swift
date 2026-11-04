import AteKit
import SwiftUI

/// **The tutorial** (`mockups/onboarding-calmer.html`, Eamon 4 Nov): one entry, written in the
/// composer the way people really write one, one piece per Next. The dish and its score; what you
/// thought; the next dish with its diet code and score; who you were with and the photos; then the
/// entry as the Feed shows it. Each step adds its piece at the end of the words and then holds still:
/// nothing is laid out ahead of it, and the composer never changes size (``OnboardingArt``).
///
/// One stage, not pages: the composer stays put and only the title changes. Next or a swipe left goes
/// on; a swipe right goes back to where the previous step finished. Skip goes to the start screen,
/// never past it. Nothing in the picture is tappable.
struct OnboardingCards: View {
    /// Left the steps: the furthest one seen (1–5), and whether Skip did it.
    let onDone: (_ reached: Int, _ skipped: Bool) -> Void
    /// The handle on the Feed card.
    let handle: String

    @State private var page: OnboardingCard
    @State private var furthest: OnboardingCard
    @Environment(\.atePalette) private var palette
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    /// `first` is where it opens: always the Write step, except a snapshot test's picture of a later one.
    init(
        onDone: @escaping (_ reached: Int, _ skipped: Bool) -> Void,
        handle: String,
        first: OnboardingCard = .write
    ) {
        self.onDone = onDone
        self.handle = handle
        _page = State(initialValue: first)
        _furthest = State(initialValue: first)
    }

    var body: some View {
        VStack(spacing: 0) {
            OnboardingArt(card: page, handle: handle)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
                .padding(.top, OnboardingMetrics.artTop)
                .padding(.bottom, AteMetrics.section)
                .allowsHitTesting(false)
                .accessibilityHidden(true)
            title
                .padding(.horizontal, OnboardingMetrics.titleInset)
                .padding(.top, AteMetrics.loose)
                .padding(.bottom, AteMetrics.section)
            dots
                .padding(.bottom, OnboardingMetrics.dotsToPill)
            AteInkPill(title: OnboardingCopy.next, identifier: "onboarding.cards.next", action: next)
                .padding(.horizontal, AteMetrics.gutter)
                .ateContentBottom(AteWelcomeCardMetrics.doorsBottom)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .contentShape(.rect)
        .gesture(swipe)
        .onChange(of: page) { _, page in furthest = max(furthest, page) }
        .accessibilityIdentifier("v2.onboarding.cards")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .confirmationAction) {
                AteWelcomeLink(title: OnboardingCopy.skip, colour: palette.fg, identifier: "onboarding.cards.skip") {
                    onDone(furthest.number, true)
                }
            }
            .sharedBackgroundVisibility(.hidden)
        }
    }

    private func next() {
        AteHaptics.key()
        guard let following = page.following else { return onDone(OnboardingCard.allCases.count, false) }
        page = following
    }

    /// Left goes on, right goes back; a mostly vertical drag is left alone.
    private var swipe: some Gesture {
        DragGesture(minimumDistance: OnboardingMetrics.swipe)
            .onEnded { drag in
                let across = drag.translation.width
                guard abs(across) > abs(drag.translation.height) else { return }
                if across < 0, let following = page.following {
                    AteHaptics.key()
                    page = following
                } else if across > 0, let previous = page.previous {
                    page = previous
                }
            }
    }

    // MARK: - The words under the picture

    /// Every step's title laid out unseen behind this one, so the block is as tall as the tallest and
    /// each title starts at the same height. The title alone cross-fades; the picture is not in the
    /// transaction (a label resized under an animation shakes, build 282).
    private var title: some View {
        ZStack(alignment: .top) {
            ForEach(OnboardingCard.allCases) { card in
                words(card).hidden().accessibilityHidden(true)
            }
            words(page)
                .id(page)
                .transition(.opacity)
        }
        .animation(reduceMotion ? nil : OnboardingArtMetrics.titleFade, value: page)
    }

    private func words(_ card: OnboardingCard) -> some View {
        AteTitle(
            text: card.title,
            style: card == .write ? .onboardingWriteTitle : .handleTitle,
            endsWithWordmark: card == .write
        )
    }

    private var dots: some View {
        HStack(spacing: AteMetrics.snug) {
            ForEach(OnboardingCard.allCases) { card in
                Circle()
                    .fill(card == page ? palette.fg : palette.hairline)
                    .frame(width: OnboardingMetrics.dot, height: OnboardingMetrics.dot)
            }
        }
        .animation(reduceMotion ? nil : OnboardingArtMetrics.titleFade, value: page)
        .accessibilityElement()
        .accessibilityLabel("Step \(page.number) of \(OnboardingCard.allCases.count)")
    }
}

/// The steps, in order: each writes the next piece of the one entry.
enum OnboardingCard: Int, CaseIterable, Identifiable, Comparable {
    case write, thought, nextDish, details, share

    var id: Int { rawValue }
    /// 1–5, as the analytics count them.
    var number: Int { rawValue + 1 }
    var following: OnboardingCard? { OnboardingCard(rawValue: rawValue + 1) }
    var previous: OnboardingCard? { OnboardingCard(rawValue: rawValue - 1) }

    static func < (lhs: Self, rhs: Self) -> Bool { lhs.rawValue < rhs.rawValue }

    /// The Write step's title ends on the logo, not the word: "Write about what you [ate.]".
    var title: String {
        switch self {
        case .write: "Write about what you"
        case .thought: "Say what you thought."
        case .nextDish: "Add the next dish."
        case .details: "Add the details."
        case .share: "Share your favourite dishes with the world."
        }
    }
}

/// **The one sample entry** the steps write, word for word: the margherita pizza at 4.5, the
/// tiramisu (vegetarian) at 2.5, at 400 Gradi, with @jess.
enum OnboardingSample {
    static let first = Rating(rounding: 4.5)
    static let second = Rating(rounding: 2.5)
    static let place = "400 Gradi"
    static let suburb = "Brunswick East"
    /// Fixed ids throughout: an avatar's colour comes from its id's bytes, so the picture is the same
    /// every time it plays (and in its snapshot).
    static let friend = AteWithPerson(id: fixed(0x02), handle: "jess")
    /// The details step's photos: the app's own pizza and tiramisu, the two dishes in the words.
    static let photos = [("pizza", 0x03), ("tiramisu", 0x04)].map { name, id in
        AtePhoto(id: fixed(UInt8(id)), image: Image("Photos/\(name)"))
    }

    private static let firstScore = EntryToken(kind: .score(first))
    private static let secondScore = EntryToken(kind: .score(second))
    /// The composer's Diet key puts the chip between the dish and its score.
    private static let vegetarian = EntryToken(kind: .tag(DietTagMark(tag: .v, text: DietTag.v.label)))
    private static let dishIDs = [fixed(0x05), fixed(0x06)]
    /// The person's own tile on the Feed card.
    private static let bylineID = fixed(0x01)
    /// The Feed card's own id: the photos' tilt is seeded from it.
    private static let slipID = fixed(0x07)

    private static func fixed(_ last: UInt8) -> UUID {
        UUID(uuid: (0xA7, 0xE0, 0x0B, 0x0A, 0x2D, 0x1E, 0x4C, 0x11, 0x8A, 0x7E, 0x0B, 0x0A, 0x2D, 0x1E, 0x00, last))
    }

    /// One step of the writing: a word, or a pill put in by the key that makes it.
    enum Beat: Equatable {
        case word(String)
        case pill(EntryToken, key: OnboardingKey)
    }

    /// What each step writes, in the order it is written. The details and share steps write no words.
    static func beats(_ card: OnboardingCard) -> [Beat] {
        switch card {
        case .write:
            let pills: [Beat] = [.pill(firstScore, key: .score)]
            return words("The margherita pizza") + pills
        case .thought:
            return words("was truly the best pizza I've had in Melbourne.")
        case .nextDish:
            let pills: [Beat] = [.pill(vegetarian, key: .diet), .pill(secondScore, key: .score)]
            return words("The tiramisu") + pills + words("was underwhelming.")
        case .details, .share:
            return []
        }
    }

    private static func words(_ text: String) -> [Beat] {
        text.split(separator: " ").map { .word(String($0)) }
    }

    /// Every beat, in order.
    static let script: [Beat] = OnboardingCard.allCases.flatMap { beats($0) }

    /// How many beats are written once `card` has finished.
    static func written(through card: OnboardingCard) -> Int {
        OnboardingCard.allCases.filter { $0 <= card }.reduce(0) { $0 + beats($1).count }
    }

    /// The words as far as `written` beats have got, one space between beats, and where each beat
    /// landed in the text (a word's range carries its leading space). Only what is written is laid
    /// out: nothing waits unseen for its turn.
    static func composition(written: Int) -> (composition: EntryComposition, ranges: [NSRange]) {
        var plain = ""
        var spans: [EntryTokenSpan] = []
        var ranges: [NSRange] = []
        for beat in script.prefix(written) {
            let start = plain.utf16.count
            if plain.isEmpty == false { plain += " " }
            switch beat {
            case .word(let word):
                plain += word
            case .pill(let token, _):
                spans.append(EntryTokenSpan(
                    token: token,
                    span: TextSpan(location: plain.utf16.count, length: token.kind.plainText.utf16.count)
                ))
                plain += token.kind.plainText
            }
            ranges.append(NSRange(location: start, length: plain.utf16.count - start))
        }
        return (EntryComposition(plain: plain, spans: spans), ranges)
    }

    /// The finished words.
    static var finished: EntryComposition { composition(written: script.count).composition }

    /// The entry as the Feed prints it, with the person's own handle on it.
    static func feedSlip(handle: String) -> AteSlip {
        AteSlip(
            id: slipID,
            dishes: [
                AteSlip.Dish(id: dishIDs[0], dishID: dishIDs[0], name: "Margherita Pizza", score: first),
                AteSlip.Dish(id: dishIDs[1], dishID: dishIDs[1], name: "Tiramisu", score: second, tags: [.v])
            ],
            place: place,
            suburb: suburb,
            words: finished,
            photos: photos,
            byline: AteByline(userID: bylineID, handle: handle, age: "now", with: "@\(friend.handle)")
        )
    }
}

/// The composer key a step lights as it uses it.
enum OnboardingKey: Equatable {
    case score, diet, photos
}
