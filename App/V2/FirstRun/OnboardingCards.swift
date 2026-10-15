import AteKit
import SwiftUI
import UIKit

/// **The four cards** (`design/rebuild/onboarding-v2.html`, steps 3–6; restaged as instructions in
/// `onboarding-cards.html`, 11 Oct): one sample entry built up a step at a time — the words, then its
/// photos, then its scores, then the cards it shares as — each picture staging the gesture it
/// teaches (``OnboardingArt``), with the title and one line under it saying it. Swipe or Next; Skip
/// goes to the start screen, never past it.
///
/// The pictures are built from the kit fed ``OnboardingSample`` — ``AteEntrySlip``, ``StarSlider``,
/// ``AteShareCard``, ``AteShareRow`` — so a kit change reaches them. Nothing on a card is tappable.
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
            OnboardingArt(card: card, sample: sample, handle: handle, isShowing: page == card.rawValue)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
                .padding(.top, OnboardingMetrics.artTop)
                .allowsHitTesting(false)
                .accessibilityHidden(true)
            VStack(spacing: AteMetrics.snug) {
                AteTitle(text: card.title, style: .handleTitle)
                Text(card.line)
                    .ateText(.onboardingLine)
                    .foregroundStyle(palette.muted)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(.horizontal, OnboardingMetrics.titleInset)
            .padding(.top, AteMetrics.loose)
            .padding(.bottom, AteMetrics.section)
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

    /// The one line under the title: how.
    var line: String {
        switch self {
        case .write: "Just type. Ate picks out the dishes."
        case .photos: "Pick them straight from your camera roll."
        case .scores: "Slide across the stars. Half stars count."
        case .share: "As a sticker, a story or a post."
        }
    }
}

/// **The one sample entry** the cards build: a margherita and a tiramisu, the bundled photos of
/// both, scores of 4.5 and 3.5. Made once per first run, so its photos keep their identity as the
/// pages move.
struct OnboardingSample {
    let photos = [AtePhoto(image: Image("Photos/pizza")), AtePhoto(image: Image("Photos/tiramisu"))]
    /// The first photo in hand, for the share cards.
    let sharePhoto = UIImage(named: "Photos/pizza")
    private let dishIDs = [UUID(), UUID()]

    static let first = Rating(rounding: 4.5)
    private static let second = Rating(rounding: 3.5)
    static let firstDish = "Margherita"
    static let place = "400 Gradi"
    static let placeLine = "400 Gradi · Brunswick East"

    /// The two entries the Write card's paper sits on.
    static let olderEntries = [
        "Salmon nigiri melted. Get the tuna too.",
        "Smash burger at Royal Stacks, extra pickles."
    ]
    /// The Photos card's camera roll, and which of it is picked (in order).
    static let roll = ["sushi", "pizza", "burger", "ragu", "prawn", "tiramisu", "penne", "cake", "sushi"]
    static let picks: [Int?] = [nil, 1, nil, nil, nil, 2, nil, nil, nil]

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
                AteSlip.Dish(id: dishIDs[0], dishID: dishIDs[0], name: Self.firstDish, score: Self.first),
                AteSlip.Dish(id: dishIDs[1], dishID: dishIDs[1], name: "Tiramisu", score: Self.second)
            ] : [],
            words: Self.words(scored: scores),
            photos: withPhotos ? photos : []
        )
    }

    func receipt(handle: String) -> AteReceipt {
        AteReceipt(
            place: Self.place,
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

    /// The ink share sheet's row (``V2ReceiptShareRow``), drawn but not wired: the card shows the
    /// ways out, it does not share anything.
    static var shareActions: [AteShareRow.Action] {
        [
            .init(id: "stories", icon: .instagram, title: "Stories", brand: .instagram) {},
            .init(id: "tiktok", icon: .tiktok, title: "TikTok", brand: .tiktok) {},
            .init(id: "messages", icon: .messageCircle, title: "Messages", brand: .messages) {},
            .init(id: "instagram", icon: .instagram, title: "Instagram", brand: .instagram) {},
            .init(id: "link", icon: .link, title: "Copy link") {},
            .init(id: "save", icon: .download, title: "Save image") {},
            .init(id: "more", icon: .more, title: "More") {}
        ]
    }
}
