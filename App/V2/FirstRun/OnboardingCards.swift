import AteKit
import SwiftUI

/// **The three cards** (`design/rebuild/onboarding-calm.html`, 17 Oct): one entry, written the way
/// people really write one — the review with a score after each dish — then its details, then how it
/// looks in the Feed (``OnboardingArt``). A centred title on each; only the first has a line under
/// it. No photos. Swipe or Next; Skip goes to the start screen, never past it.
///
/// The pictures are built from the kit fed ``OnboardingSample``, so a kit change reaches them.
/// Nothing on a card is tappable.
struct OnboardingCards: View {
    /// Left the cards: the furthest one seen (1–3), and whether Skip did it.
    let onDone: (_ reached: Int, _ skipped: Bool) -> Void
    /// The receipt's signature.
    let handle: String

    @State private var page = 0
    @State private var furthest = 0
    @Environment(\.atePalette) private var palette

    var body: some View {
        VStack(spacing: 0) {
            TabView(selection: $page) {
                ForEach(OnboardingCard.allCases) { card in
                    cardPage(card).tag(card.rawValue)
                }
            }
            .tabViewStyle(.page(indexDisplayMode: .never))
            dots
                .padding(.bottom, OnboardingMetrics.dotsToPill)
            AteInkPill(title: OnboardingCopy.next, identifier: "onboarding.cards.next", action: next)
                .padding(.horizontal, AteMetrics.gutter)
                .ateContentBottom(AteWelcomeCardMetrics.doorsBottom)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .onChange(of: page) { _, page in furthest = max(furthest, page) }
        .accessibilityIdentifier("v2.onboarding.cards")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .confirmationAction) {
                AteWelcomeLink(title: OnboardingCopy.skip, colour: palette.fg, identifier: "onboarding.cards.skip") {
                    onDone(furthest + 1, true)
                }
            }
            .sharedBackgroundVisibility(.hidden)
        }
    }

    private func next() {
        guard page < OnboardingCard.allCases.count - 1 else {
            return onDone(OnboardingCard.allCases.count, false)
        }
        AteHaptics.key()
        withAnimation(AteMotion.fillIn) { page += 1 }
    }

    // MARK: - A card

    private func cardPage(_ card: OnboardingCard) -> some View {
        VStack(spacing: 0) {
            OnboardingArt(card: card, handle: handle, isShowing: page == card.rawValue)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
                .padding(.top, OnboardingMetrics.artTop)
                .allowsHitTesting(false)
                .accessibilityHidden(true)
            // Every card's words are laid out unseen behind this card's, so the block is as tall as
            // the tallest and each title starts at the same height, whatever its line count.
            ZStack(alignment: .top) {
                ForEach(OnboardingCard.allCases) { other in
                    words(other).hidden().accessibilityHidden(true)
                }
                words(card)
            }
            .padding(.horizontal, OnboardingMetrics.titleInset)
            .padding(.top, AteMetrics.loose)
            .padding(.bottom, AteMetrics.section)
        }
    }

    private func words(_ card: OnboardingCard) -> some View {
        VStack(spacing: AteMetrics.snug) {
            AteTitle(
                text: card.title,
                style: card == .write ? .onboardingWriteTitle : .handleTitle,
                endsWithWordmark: card == .write
            )
            if let line = card.line {
                Text(line)
                    .ateText(.onboardingLine)
                    .foregroundStyle(palette.muted)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private var dots: some View {
        HStack(spacing: AteMetrics.snug) {
            ForEach(OnboardingCard.allCases) { card in
                Circle()
                    .fill(card.rawValue == page ? palette.fg : palette.hairline)
                    .frame(width: OnboardingMetrics.dot, height: OnboardingMetrics.dot)
            }
        }
        .accessibilityElement()
        .accessibilityLabel("Page \(page + 1) of \(OnboardingCard.allCases.count)")
    }
}

/// The cards, in order: each adds one thing to the entry before it.
enum OnboardingCard: Int, CaseIterable, Identifiable {
    case write, details, share

    var id: Int { rawValue }

    /// The Write card's title ends on the logo, not the word: "Write about what you [ate.]".
    var title: String {
        switch self {
        case .write: "Write about what you"
        case .details: "Add the details."
        case .share: "Share your favourite dishes with the world."
        }
    }

    /// The one line under the title, on the first card only.
    var line: String? {
        switch self {
        case .write: "Score as you go."
        case .details, .share: nil
        }
    }
}

/// **The one sample entry** the cards build, word for word as Eamon wrote it: the margherita pizza at
/// 4.5 and the tiramisu at 2.5, each score straight after its dish, at 400 Gradi, with @jess.
enum OnboardingSample {
    static let first = Rating(rounding: 4.5)
    static let second = Rating(rounding: 2.5)
    static let place = "400 Gradi"
    static let suburb = "Brunswick East"
    static let friend = AteWithPerson(id: UUID(), handle: "jess")
    /// The details card's photos: the app's own pizza and tiramisu, the two dishes in the words.
    static let photos = ["pizza", "tiramisu"].map { AtePhoto(id: UUID(), image: Image("Photos/\($0)")) }

    private static let firstScore = EntryToken(kind: .score(first))
    private static let secondScore = EntryToken(kind: .score(second))
    /// The composer's Diet key puts the chip between the dish and its score.
    private static let vegetarian = EntryToken(kind: .tag(DietTagMark(tag: .v, text: DietTag.v.label)))
    private static let dishIDs = [UUID(), UUID()]

    private enum Piece {
        case words(String)
        case token(EntryToken)

        /// A token is one step of the typing, however many characters it prints.
        var steps: Int {
            switch self {
            case .words(let text): text.count
            case .token: 1
            }
        }
    }

    private static func pieces(tagged: Bool) -> [Piece] {
        var pieces: [Piece] = [.words("The margherita pizza ")]
        if tagged { pieces += [.token(vegetarian), .words(" ")] }
        pieces += [
            .token(firstScore),
            .words(" was truly the best pizza I've had in Melbourne. The tiramisu for dessert was underwhelming "),
            .token(secondScore)
        ]
        return pieces
    }

    /// How many steps typing the words takes: a step per character, and one per pill.
    static func steps(tagged: Bool) -> Int {
        pieces(tagged: tagged).reduce(0) { $0 + $1.steps }
    }

    /// Whether the step after `step` is a pill rather than a character.
    static func isToken(step: Int, tagged: Bool) -> Bool {
        var reached = 0
        for piece in pieces(tagged: tagged) {
            if step < reached + piece.steps {
                if case .token = piece { return true }
                return false
            }
            reached += piece.steps
        }
        return false
    }

    /// The words, as far as `typed` steps have got (all of them when `nil`), each pill's span found
    /// by building the text rather than counted by hand.
    static func words(tagged: Bool, typed: Int? = nil) -> EntryComposition {
        var remaining = typed ?? .max
        var plain = ""
        var spans: [EntryTokenSpan] = []
        for piece in pieces(tagged: tagged) where remaining > 0 {
            switch piece {
            case .words(let text):
                plain += String(text.prefix(remaining))
            case .token(let token):
                spans.append(EntryTokenSpan(
                    token: token,
                    span: TextSpan(location: plain.utf16.count, length: token.kind.plainText.utf16.count)
                ))
                plain += token.kind.plainText
            }
            remaining -= piece.steps
        }
        return EntryComposition(plain: plain, spans: spans)
    }

    /// The entry as the Feed prints it, with the person's own handle on it.
    static func feedSlip(handle: String, isSaved: Bool) -> AteSlip {
        AteSlip(
            dishes: [
                AteSlip.Dish(
                    id: dishIDs[0], dishID: dishIDs[0], name: "Margherita Pizza", score: first,
                    isSaved: isSaved, tags: [.v]
                ),
                AteSlip.Dish(id: dishIDs[1], dishID: dishIDs[1], name: "Tiramisu", score: second)
            ],
            place: place,
            suburb: suburb,
            words: words(tagged: true),
            byline: AteByline(userID: UUID(), handle: handle, age: "now", with: "@\(friend.handle)")
        )
    }
}
