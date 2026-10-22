import AteKit
import SwiftUI

/// **Share to Ate** (`design/rebuild/share-to-ate.html`, approved): the card that rises over TikTok,
/// Instagram or Safari. "Save to Ate" between the close disc and nothing; where the post came from;
/// the Dish and the Place, prefilled from the post and both still the person's to change; one ink
/// Save, live only with a dish and a real place. Saved, it gives way to a tick and closes itself.
///
/// The place is chosen on the app's own place sheet, seeded with the venue the post named — so the
/// same action looks and works the same here as on Saved's Add and in the composer.
struct ShareCardScreen: View {
    let model: ShareCardModel
    let places: any PlaceDirectory
    let nearby: NearbyPlaces
    /// The card is done: `true` once the dish is in Saved.
    let onFinish: (_ saved: Bool) -> Void

    @State private var isUp = false
    @State private var drag: CGFloat = 0
    @State private var isClosing = false
    @State private var isPickingPlace = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        @Bindable var model = model
        ZStack(alignment: .bottom) {
            AteKitColor.shareScrim
                .ignoresSafeArea()
                .opacity(isUp ? 1 : 0)
            if isUp, model.phase != .saved {
                card
                    .offset(y: drag)
                    .transition(reduceMotion ? .identity : .move(edge: .bottom))
            }
            if model.phase == .saved {
                ShareSavedTick()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .transition(.opacity)
            }
        }
        .ateAnimation(AteMotion.cardRise, value: isUp)
        .ateAnimation(AteMotion.cardRise, value: model.phase)
        .onAppear { isUp = true }
        .task(id: model.phase) {
            guard model.phase == .saved else { return }
            AteHaptics.success()
            try? await Task.sleep(for: ShareCardMetrics.savedHold)
            onFinish(true)
        }
        .v2PlaceSheet(
            isPresented: $isPickingPlace,
            directory: places,
            nearby: nearby,
            title: V2PlaceSheet.savedTitle,
            initialQuery: { model.placeQuery },
            selected: { model.place?.id },
            onPick: { picked in model.pick(picked) }
        )
        .ateFailureAlert($model.failure)
    }

    // MARK: - The card

    private var card: some View {
        VStack(alignment: .leading, spacing: ShareCardMetrics.gap) {
            header
            if model.phase == .signedOut {
                signedOut
            } else {
                AteLinkCard(
                    title: model.sourceTitle,
                    detail: model.sourceDetail,
                    thumbnail: model.thumbnailURL,
                    mark: model.source.mark
                )
                fields
                AteInkPill(title: "Save", isEnabled: model.canSave, identifier: "share.save") {
                    Task { await model.save() }
                }
            }
        }
        .padding(.horizontal, ShareCardMetrics.inset)
        .padding(.top, ShareCardMetrics.inset)
        .ateContentBottom(ShareCardMetrics.bottom)
        .frame(maxWidth: .infinity)
        .background {
            UnevenRoundedRectangle(
                topLeadingRadius: ShareCardMetrics.corner,
                topTrailingRadius: ShareCardMetrics.corner,
                style: .continuous
            )
            .fill(AtePalette.surface.ground)
            .ignoresSafeArea(.container, edges: .bottom)
        }
        .overlay(alignment: .top) { grabber }
        .environment(\.atePalette, .surface)
        .foregroundStyle(AtePalette.surface.fg)
    }

    /// The close disc, the title centred over the card, and nothing on the right (`.top`: a 44
    /// spacer). Dragging it down closes the card, as a sheet's top does.
    private var header: some View {
        ZStack {
            Text("Save to Ate")
                .ateText(.kitShareTitle)
                .lineLimit(1)
                .accessibilityAddTraits(.isHeader)
            HStack(spacing: 0) {
                AteGlassDisc(icon: .close, label: "Close", identifier: "share.close", action: close)
                Spacer(minLength: 0)
            }
        }
        .frame(height: AteMetrics.hit)
        .padding(.top, ShareCardMetrics.headerTop)
        .contentShape(.rect)
        .gesture(dragToClose)
    }

    @ViewBuilder
    private var fields: some View {
        @Bindable var model = model
        if model.phase == .reading {
            ShareReadingField(label: "Dish", width: ShareCardMetrics.dishSkeleton)
            ShareReadingField(label: "Place", width: ShareCardMetrics.placeSkeleton)
        } else {
            AteFieldPill(label: "Dish", text: $model.dish, identifier: "share.dish")
            AtePickPill(
                label: "Place",
                icon: .place,
                value: model.place?.name,
                detail: model.placeDetail,
                prompt: "Find the place",
                identifier: "share.place"
            ) { isPickingPlace = true }
        }
    }

    /// Signed out on this phone: one line, nothing else.
    private var signedOut: some View {
        Text("Open Ate to sign in")
            .ateText(.rowTitle)
            .foregroundStyle(AtePalette.surface.muted)
            .frame(maxWidth: .infinity, minHeight: AteMetrics.fieldHeight)
            .accessibilityIdentifier("share.signedOut")
    }

    private var grabber: some View {
        RoundedRectangle(cornerRadius: ShareCardMetrics.grabberCorner, style: .continuous)
            .fill(AtePalette.surface.fg.opacity(AteKitColor.grabberOpacity))
            .frame(width: ShareCardMetrics.grabberWidth, height: ShareCardMetrics.grabberHeight)
            .padding(.top, ShareCardMetrics.grabberTop)
            .accessibilityHidden(true)
    }

    // MARK: - Going

    private var dragToClose: some Gesture {
        DragGesture()
            .onChanged { value in drag = max(0, value.translation.height) }
            .onEnded { value in
                let far = value.translation.height > ShareCardMetrics.closeDistance
                let flung = value.predictedEndTranslation.height > ShareCardMetrics.closeFling
                if far || flung {
                    close()
                } else {
                    withAnimation(reduceMotion ? nil : AteMotion.cardRise) { drag = 0 }
                }
            }
    }

    /// The card goes back down, then the request is cancelled — the other app is as it was.
    private func close() {
        // A save in flight finishes first: closing now could drop the note that refreshes Saved.
        guard isClosing == false, model.isSaving == false else {
            withAnimation(reduceMotion ? nil : AteMotion.cardRise) { drag = 0 }
            return
        }
        isClosing = true
        model.dismissed()
        isUp = false
        Task {
            try? await Task.sleep(for: reduceMotion ? .zero : ShareCardMetrics.closeHold)
            onFinish(false)
        }
    }
}

/// A field whose suggestion is still being read: its label, and the pill with one still bar in it.
private struct ShareReadingField: View {
    let label: String
    let width: CGFloat

    @Environment(\.atePalette) private var palette

    var body: some View {
        VStack(alignment: .leading, spacing: AteFieldPillMetrics.labelGap) {
            Text(label)
                .ateText(.meta)
                .foregroundStyle(palette.muted)
            AteSkeletonBar(width: width, height: ShareCardMetrics.skeletonBar, palette: palette)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, AteMetrics.loose)
                .atePillHeight(AteMetrics.fieldHeight)
                .background(palette.field, in: .capsule)
        }
        .accessibilityHidden(true)
    }
}

/// **Saved** (`.done`): the ink tick over the word, in a square of glass, while the card closes.
private struct ShareSavedTick: View {
    @Environment(\.atePalette) private var palette

    var body: some View {
        VStack(spacing: ShareCardMetrics.doneGap) {
            AteIcon.check.view(size: AteGlassDiscMetrics.glyph)
                .foregroundStyle(palette.inverted)
                .frame(width: ShareCardMetrics.tick, height: ShareCardMetrics.tick)
                .ateBackground(palette.solid, in: Circle(), shadow: .tick)
            Text("Saved")
                .ateText(.kitShareDone)
                .foregroundStyle(palette.fg)
        }
        .frame(width: ShareCardMetrics.done, height: ShareCardMetrics.done)
        .glassEffect(.regular, in: .rect(cornerRadius: ShareCardMetrics.doneCorner))
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("share.saved")
    }
}

/// `share-to-ate.html`'s own numbers.
enum ShareCardMetrics {
    /// `.ext{border-radius:38px 38px 0 0;padding:20px 20px 40px;gap:16px}`.
    static let corner: CGFloat = 38
    static let inset: CGFloat = 20
    static let bottom: CGFloat = 40
    static let gap: CGFloat = 16
    /// `.top{padding-top:4px}`.
    static let headerTop: CGFloat = 4
    /// The grabber: `top:7px;width:36px;height:5px;border-radius:3px`.
    static let grabberTop: CGFloat = 7
    static let grabberWidth: CGFloat = 36
    static let grabberHeight: CGFloat = 5
    static let grabberCorner: CGFloat = 3
    /// `.done{width:170px;height:170px;border-radius:36px;gap:12px}`, its tick 56.
    static let done: CGFloat = 170
    static let doneCorner: CGFloat = 36
    static let doneGap: CGFloat = 12
    static let tick: CGFloat = 56
    /// The still bars in a field still being read.
    static let skeletonBar: CGFloat = 12
    static let dishSkeleton: CGFloat = 148
    static let placeSkeleton: CGFloat = 112
    /// How long the tick shows before the card closes itself.
    static let savedHold = Duration.milliseconds(1100)
    /// The card's way back down, before the request ends.
    static let closeHold = Duration.milliseconds(350)
    /// A drag past this, or flung past the second, closes the card.
    static let closeDistance: CGFloat = 120
    static let closeFling: CGFloat = 260
}
