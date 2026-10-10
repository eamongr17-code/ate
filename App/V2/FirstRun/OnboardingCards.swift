import AteKit
import SwiftUI

/// **The four cards** (`design/rebuild/onboarding-v2.html`, steps 3–6): one sample entry built up a
/// step at a time — the words, then its photos, then its scores, then the receipt it shares as — so
/// each card adds one thing to the last. Swipe or Next; Skip goes to the start screen, never past it.
///
/// Every picture is the app's own component fed ``OnboardingSample``: ``AteEntrySlip``, its photo
/// cluster and inline score tokens, ``AteShareStory`` (``AteShareSlip`` on the photo) and
/// ``AteShareRow``. Change the kit and the cards change with it. Nothing on a card is tappable.
struct OnboardingCards: View {
    /// Left the cards: the furthest one seen (1–4), and whether Skip did it.
    let onDone: (_ reached: Int, _ skipped: Bool) -> Void
    /// The receipt's signature.
    let handle: String

    @State private var page = 0
    @State private var furthest = 0
    @State private var sample = OnboardingSample()
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
            art(card)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
                .padding(.top, OnboardingMetrics.artTop)
                .allowsHitTesting(false)
                .accessibilityHidden(true)
            AteTitle(text: card.title, style: .handleTitle)
                .padding(.horizontal, OnboardingMetrics.titleInset)
                .padding(.vertical, AteMetrics.section)
        }
    }

    @ViewBuilder
    private func art(_ card: OnboardingCard) -> some View {
        switch card {
        case .write:
            AteEntrySlip(slip: sample.slip(photos: false, scores: false), surface: .journal)
                .ateCardWidth()
        case .photos:
            AteEntrySlip(slip: sample.slip(photos: true, scores: false), surface: .journal)
                .ateCardWidth()
        case .scores:
            AteEntrySlip(slip: sample.slip(photos: true, scores: true), surface: .journal)
                .ateCardWidth()
        case .share:
            share
        }
    }

    /// What leaves the app — the receipt on the entry's first photo — at whatever size the card has
    /// room for, with the share screen's row of ways out under it.
    private var share: some View {
        GeometryReader { proxy in
            let room = proxy.size.height - OnboardingMetrics.shareRowHeight - AteMetrics.loose
            let scale = max(0.3, min(OnboardingMetrics.storyScale, room / AteShareStoryMetrics.height))
            VStack(spacing: AteMetrics.loose) {
                AteShareStory(receipt: sample.receipt(handle: handle), photo: sample.photos.first)
                    .scaleEffect(scale, anchor: .topLeading)
                    .frame(
                        width: AteShareStoryMetrics.width * scale,
                        height: AteShareStoryMetrics.height * scale,
                        alignment: .topLeading
                    )
                    .clipShape(.rect(cornerRadius: AteShareStoryMetrics.radius * scale, style: .continuous))
                AteShareRow(actions: OnboardingSample.shareActions)
                    .padding(.horizontal, AteMetrics.regular)
            }
            .frame(maxWidth: .infinity)
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
    case write, photos, scores, share

    var id: Int { rawValue }

    var title: String {
        switch self {
        case .write: "Write about what you ate."
        case .photos: "Add your photos."
        case .scores: "Score dishes as you go."
        case .share: "Share it with friends."
        }
    }
}

/// **The one sample entry** the cards build: a margherita and a tiramisu, the bundled photos of
/// both, scores of 4.5 and 3.5. Made once per first run, so its photos keep their identity as the
/// pages move.
struct OnboardingSample {
    let photos = [AtePhoto(image: Image("Photos/pizza")), AtePhoto(image: Image("Photos/tiramisu"))]
    private let dishIDs = [UUID(), UUID()]

    private static let first = Rating(rounding: 4.5)
    private static let second = Rating(rounding: 3.5)

    /// The words, with or without their score tokens. Each token's span is found in the text rather
    /// than counted by hand: a span that misses its words is dropped by the model.
    static func words(scored: Bool) -> EntryComposition {
        guard scored else {
            return EntryComposition(
                plain: "The margherita was the best I've had outside Naples. The tiramisu was fine.", spans: []
            )
        }
        let text = "The margherita 4.5 was the best I've had outside Naples. The tiramisu 3.5 was fine."
        var spans: [EntryTokenSpan] = []
        var from = text.startIndex
        for rating in [first, second] {
            let kind = EntryTokenKind.score(rating)
            guard let range = text.range(of: kind.plainText, range: from..<text.endIndex),
                  let lower = range.lowerBound.samePosition(in: text.utf16) else { continue }
            spans.append(EntryTokenSpan(
                token: EntryToken(kind: kind),
                span: TextSpan(
                    location: text.utf16.distance(from: text.utf16.startIndex, to: lower),
                    length: kind.plainText.utf16.count
                )
            ))
            from = range.upperBound
        }
        return EntryComposition(plain: text, spans: spans)
    }

    func slip(photos withPhotos: Bool, scores: Bool) -> AteSlip {
        AteSlip(
            dishes: scores ? [
                AteSlip.Dish(id: dishIDs[0], dishID: dishIDs[0], name: "Margherita", score: Self.first),
                AteSlip.Dish(id: dishIDs[1], dishID: dishIDs[1], name: "Tiramisu", score: Self.second)
            ] : [],
            words: Self.words(scored: scores),
            photos: withPhotos ? photos : []
        )
    }

    func receipt(handle: String) -> AteReceipt {
        AteReceipt(
            place: "400 Gradi",
            locality: "Brunswick East",
            items: [
                AteReceipt.Item(name: "Margherita", score: Self.first),
                AteReceipt.Item(name: "Tiramisu", score: Self.second)
            ],
            orderNumber: 1,
            date: .now,
            handle: handle
        )
    }

    /// The share screen's row as it reads after a review, drawn but not wired: the card shows the
    /// ways out, it does not share anything.
    static var shareActions: [AteShareRow.Action] {
        [
            .init(id: "stories", icon: .camera, title: "Instagram Stories", isPrimary: true) {},
            .init(id: "link", icon: .link, title: "Copy link") {},
            .init(id: "messages", icon: .messageCircle, title: "Messages") {},
            .init(id: "save", icon: .download, title: "Save image") {},
            .init(id: "more", icon: .more, title: "More") {}
        ]
    }
}
