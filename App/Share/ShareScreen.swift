import AteKit
import SwiftUI
import UIKit

/// **`Share`** — the coral screen an artefact is sent from.
///
/// The receipt as the hero, and two pills at the foot: **Done** (white, secondary) and **Share**
/// (ink, primary) — the layout `SummaryFinal.dc.html` gives the moment after Done in the composer,
/// and the one every share uses, so the same action looks and behaves the same wherever it starts
/// (the entry page, an actions sheet, a statement). The card is ``ShareCard``, which is also exactly
/// what is rendered to a PNG, so what a person approves and what lands in the thread are the same
/// picture. Colour is punctuation: the coral ground is the one place the app shouts.
struct ShareScreen: View {
    let artefact: ShareArtefact
    /// Where the share began — the entry page, an actions sheet, a statement. The north-star event's
    /// most interesting parameter.
    let source: ReceiptShareSource
    let analytics: AnalyticsRecorder

    @State private var photos: [AtePhoto] = []
    /// Share is off until the photos behind the paper have loaded: the picture that leaves must be
    /// the one on screen, and an export taken early would go without them.
    @State private var photosLoaded = false
    @State private var sender = ShareSender()
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        ShareStage(
            artefact: artefact,
            photos: photos,
            isPrinting: false,
            breathes: false,
            primary: .share(isEnabled: photosLoaded, didFail: sender.didFail),
            onDone: { dismiss() },
            onPrimary: send
        )
        .ateCoversThePage()
        .task {
            photos = await SharePhotos.resolve(artefact.photoURLs)
            photosLoaded = true
            #if DEBUG
            dumpForDriveIfRequested()
            // `-ate-fail-share-render` taps Share for the drive too: the failure is a state of the
            // button, and a simulator cannot be tapped from a shell.
            if ShareSender.forcesRenderFailure { send() }
            #endif
        }
        .sheet(item: $sender.sending) { sending in
            ShareSheet(sending: sending) { destination in
                analytics(EntryEvents.receiptShared(
                    entryID: artefact.entryID, source: destination == .instagramStories ? .instagramStories : source
                ))
            }
        }
    }

    private func send() {
        sender.send(artefact: artefact, photos: photos)
    }

    #if DEBUG
    /// `-ate-dump-share`: writes the exported PNG into the app container so a drive can look at the
    /// thing that actually leaves. A simulator cannot be tapped from a shell, and the export is the
    /// one part of this screen that is not on screen.
    private func dumpForDriveIfRequested() {
        guard ProcessInfo.processInfo.arguments.contains("-ate-dump-share"),
              let image = ShareImage.render(artefact: artefact, photos: photos),
              let data = image.pngData(),
              let documents = FileManager.default.urls(
                for: .documentDirectory, in: .userDomainMask
              ).first
        else { return }
        try? data.write(to: documents.appending(path: "share-export.png"), options: .atomic)
    }
    #endif
}

/// **The coral stage** a receipt stands on — `SummaryLoading` / `SummaryFinal`: the card tilted on
/// the ground with its two photos, `margin:180px 52px 0` from the top of the screen (`160` while it
/// is still printing, settling down to 180 as the lines arrive — the print's own motion), and the
/// two pills pinned `bottom:40px`, `left/right:20px`, `gap:10px`.
struct ShareStage: View {
    /// The ink pill: Share (with its icon, off while there is nothing to send), or — when a print
    /// could not finish — "Print it again", in the words the entry page already uses.
    enum Primary: Equatable {
        case share(isEnabled: Bool, didFail: Bool)
        case reprint(isEnabled: Bool)
    }

    let artefact: ShareArtefact
    var photos: [AtePhoto]
    var isPrinting: Bool
    var breathes: Bool
    var primary: Primary
    /// The receipt has no place and cannot print without one: its place slot is the Place key.
    var onAddPlace: (() -> Void)?
    let onDone: () -> Void
    let onPrimary: () -> Void
    /// **The Summary's stage** (round 4, Eamon): the receipt takes more of the screen — drawn larger,
    /// still tilted, centred in the band above the pills. `Share` keeps the artboard's own placement.
    var isHero = false
    /// **Round 5: the Summary's receipt enters once, whole** (``ReceiptEntrance``). Until its shape is
    /// final the band stands empty on the coral — never a skeleton that grows into a receipt.
    var showsCard = true

    @State private var bandHeight: CGFloat = 0
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    /// The Summary's pills come on once its ground is whole, so they never show through the
    /// composer's toolbar in the cross-fade.
    @State private var actionsShown = false

    /// The card scrolls in its own band above the pills: a long receipt continues down that band
    /// and stops above them, never running underneath.
    var body: some View {
        VStack(spacing: Self.actionGap * 2) {
            ScrollView {
                if isHero {
                    heroCard
                } else {
                    card
                        .padding(.horizontal, ShareCard.inset)
                        .ateContentTop(isPrinting ? Self.printingTop : Self.cardTop)
                        // The lower photo hangs past the paper's foot; its tilt needs the room.
                        .padding(.bottom, Self.cardFoot)
                        .frame(maxWidth: .infinity)
                        .ateAnimation(AteMotion.settle, value: isPrinting)
                }
            }
            .scrollBounceBehavior(.basedOnSize)
            .scrollIndicators(.hidden)
            .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { bandHeight = $0 }
            actions
                .opacity(isHero && actionsShown == false ? 0 : 1)
        }
        .task { await showActions() }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .ateAccentGround(AteColor.coral)
    }

    private var card: some View {
        ShareCard(
            artefact: artefact, photos: photos, isPrinting: isPrinting, breathes: breathes,
            onAddPlace: onAddPlace
        )
    }

    /// The Summary's receipt: the same card, scaled as a whole (so what is seen is still exactly the
    /// picture that is shared), centred in the band, entering once.
    @ViewBuilder
    private var heroCard: some View {
        if showsCard {
            EnteringReceipt(
                artefact: artefact, photos: photos, isPrinting: isPrinting, breathes: breathes,
                onAddPlace: onAddPlace, scale: Self.heroScale, printingLift: Self.printingLift
            )
            .accessibilityElement(children: .contain)
            .accessibilityIdentifier("summary.receipt")
            .padding(.vertical, Self.heroAir)
            .frame(maxWidth: .infinity, minHeight: bandHeight)
        }
    }

    private func showActions() async {
        guard isHero, reduceMotion == false else {
            actionsShown = true
            return
        }
        try? await Task.sleep(for: Self.actionsLead)
        withAnimation(.easeOut(duration: 0.2)) { actionsShown = true }
    }

    /// The composer's cross-fade to the coral ground (0.25s), and a hair more.
    private static let actionsLead: Duration = .milliseconds(260)

    /// How much larger the Summary draws its receipt: the paper runs to 38 from each edge of the
    /// screen rather than the artboard's 52 (314 of 390, against 286).
    static var heroScale: CGFloat {
        let screen = AteScreen.width
        return max(1, (screen - 2 * heroInset) / ShareCard.width)
    }
    private static let heroInset: CGFloat = 38
    /// Room above and below for the photos, which hang past the paper.
    private static let heroAir: CGFloat = 44
    private static let printingLift: CGFloat = 20

    /// `SummaryFinal`: Done `width:118px`, white; Share fills the rest, ink, with its icon. While the
    /// receipt prints, Share is there but off (`opacity:.35`) — there is nothing to send yet.
    private var actions: some View {
        HStack(spacing: Self.actionGap) {
            AteButton(title: "Done", isSecondary: true, action: onDone)
                .frame(width: Self.doneWidth)
                .accessibilityIdentifier("share.done")
            switch primary {
            case .share(let isEnabled, let didFail):
                AteButton(icon: .share, title: didFail ? "Try again" : "Share", action: onPrimary)
                    .disabled(isEnabled == false)
                    .opacity(isEnabled ? 1 : Self.disabledOpacity)
                    .accessibilityIdentifier("share.send")
            case .reprint(let isEnabled):
                AteButton(title: "Print it again", action: onPrimary)
                    .disabled(isEnabled == false)
                    .opacity(isEnabled ? 1 : Self.disabledOpacity)
                    .accessibilityIdentifier("summary.reprint")
            }
        }
        .padding(.horizontal, AteMetrics.gutter)
        .ateContentBottom(Self.actionsBottom)
    }

    /// `margin-top:180px` — and `160` while printing (`SummaryLoading`).
    static let cardTop: CGFloat = 180
    static let printingTop: CGFloat = 160
    /// Below the paper, inside the scrolling band.
    private static let cardFoot: CGFloat = 30
    /// `bottom:40px`.
    private static let actionsBottom: CGFloat = 40
    private static let actionGap: CGFloat = 10
    private static let doneWidth: CGFloat = 118
    private static let disabledOpacity: Double = 0.35
}

/// **The Summary's receipt, entering: the printer feed** (``ReceiptEntrance``). It is only ever
/// made once its shape is final, so its first frame is the first frame of its entrance, and nothing
/// about it changes size after.
private struct EnteringReceipt: View {
    let artefact: ShareArtefact
    let photos: [AtePhoto]
    let isPrinting: Bool
    let breathes: Bool
    let onAddPlace: (() -> Void)?
    let scale: CGFloat
    let printingLift: CGFloat

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var pose = ReceiptPose.start
    @State private var isFeeding = true

    var body: some View {
        ScaledToFit(scale: scale) {
            ShareCard(
                artefact: artefact, photos: photos, isPrinting: isPrinting, breathes: breathes,
                onAddPlace: onAddPlace, pose: pose, isFeeding: isFeeding
            )
        }
        // A placeless receipt sits a little high, and settles once a place prints it.
        .offset(y: isPrinting ? -printingLift : 0)
        .ateAnimation(AteMotion.settle, value: isPrinting)
        .task { await enter() }
    }

    private func enter() async {
        guard reduceMotion == false else {
            pose = .settled
            isFeeding = false
            return
        }
        try? await Task.sleep(for: ReceiptEntrance.groundLead)
        withAnimation(ReceiptEntrance.feedRise) { pose.fed = 1 }
        try? await Task.sleep(for: ReceiptEntrance.feedRiseTime)
        // All the way out: one receipt again, the same pixels, torn off.
        isFeeding = false
        withAnimation(ReceiptEntrance.tear) { pose.tilt = ReceiptPose.restingTilt }
        try? await Task.sleep(for: ReceiptEntrance.tearLead)
        withAnimation(ReceiptEntrance.photosLand) { pose.photos = 1 }
    }
}

/// Render, and hand it to the system. **A render that fails is never silent**: it does not open the
/// sheet and does not count as a share; the pill says "Try again" — one word on the control itself,
/// no toast, no banner (design rule 1).
struct ShareSender {
    /// The rendered picture — `Identifiable` so it can present the system sheet.
    struct Sending: Identifiable {
        let id = UUID()
        let image: UIImage
        /// The card on a transparent ground, for an Instagram Stories sticker.
        var sticker: UIImage?
    }

    var sending: Sending?
    var didFail = false

    /// Renders and opens the sheet. The share is counted by the sheet itself, when the picture
    /// actually leaves — and by where it went, so Instagram Stories reads as its own source.
    @MainActor
    mutating func send(artefact: ShareArtefact, photos: [AtePhoto]) {
        guard let image = Self.render(artefact: artefact, photos: photos) else {
            didFail = true
            return
        }
        didFail = false
        sending = Sending(
            image: image,
            sticker: ShareImage.sticker(artefact: artefact, photos: photos)
        )
    }

    @MainActor
    private static func render(artefact: ShareArtefact, photos: [AtePhoto]) -> UIImage? {
        #if DEBUG
        if forcesRenderFailure { return nil }
        #endif
        return ShareImage.render(artefact: artefact, photos: photos)
    }

    #if DEBUG
    /// `-ate-fail-share-render`: the one state that cannot be reached by using the app, made
    /// reachable so it can be driven and looked at like every other.
    static var forcesRenderFailure: Bool {
        ProcessInfo.processInfo.arguments.contains("-ate-fail-share-render")
    }
    #endif
}

/// Turning the photo URLs behind a receipt into something ``ImageRenderer`` can actually draw.
///
/// An `AsyncImage` inside a renderer captures its placeholder, so the two photos are fetched *before*
/// the card is drawn — on screen and in the export alike, which is what makes the two identical.
enum SharePhotos {
    @MainActor
    static func resolve(_ urls: [URL]) async -> [AtePhoto] {
        var resolved: [AtePhoto] = []
        for url in urls.prefix(2) {
            guard let scheme = url.scheme, scheme == "http" || scheme == "https" else {
                // A bundled fixture (`asset://`, `preview://`) — ``AtePhotoContent`` draws those
                // synchronously, so the renderer sees a real picture without a round trip.
                resolved.append(AtePhoto(url: url))
                continue
            }
            guard let (data, _) = try? await URLSession.shared.data(from: url),
                  let image = UIImage(data: data) else { continue }
            resolved.append(AtePhoto(image: Image(uiImage: image)))
        }
        return resolved
    }
}

#if DEBUG
#Preview("Share") {
    ShareScreen(
        artefact: .entry(.preview, photos: []),
        source: .entry,
        analytics: { _ in }
    )
}
#endif

/// A view drawn at `scale` **and laid out at that size** — `scaleEffect` alone draws larger but
/// still takes the old room, so a larger receipt would overlap whatever sits around it.
private struct ScaledToFit<Content: View>: View {
    let scale: CGFloat
    @ViewBuilder let content: Content

    var body: some View {
        ScaledLayout(scale: scale) {
            content.scaleEffect(scale)
        }
    }
}

private struct ScaledLayout: Layout {
    let scale: CGFloat

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        guard let child = subviews.first else { return .zero }
        let inner = child.sizeThatFits(ProposedViewSize(
            width: proposal.width.map { $0 / scale }, height: proposal.height.map { $0 / scale }
        ))
        return CGSize(width: inner.width * scale, height: inner.height * scale)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        guard let child = subviews.first else { return }
        let inner = ProposedViewSize(width: bounds.width / scale, height: bounds.height / scale)
        child.place(at: CGPoint(x: bounds.midX, y: bounds.midY), anchor: .center, proposal: inner)
    }
}
