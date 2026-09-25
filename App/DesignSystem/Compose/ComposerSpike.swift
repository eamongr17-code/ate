#if DEBUG || BETA
import AteKit
import SwiftUI

/// The composer, as far as the spike goes: the real editor, the real toolbar, the real star slider,
/// and a live readout of the model underneath so the round-trip can be *seen* — the words on the left
/// exactly as typed, the tokens on the right as structured data.
///
/// This is not the shipping Composer screen (that arrives with milestone 1's flow). It exists so the
/// riskiest interaction in the product can be driven with a thumb before anything is built on top of
/// it.
struct ComposerSpike: View {
    @State private var composition: EntryComposition
    @State private var revision = 0
    @State private var caretAfterRender: Int?
    @State private var caret = 0
    @State private var scoring: ScoringToken?
    @State private var isPickingPlace = false
    @State private var showsModel = true
    @State private var photos: [AtePhoto] = []

    /// Which token the slider is open on, and the value under the finger.
    private struct ScoringToken: Identifiable {
        let id: UUID
        var dishName: String
        var rating: Rating?
    }

    /// `-ate-gallery-composer-seed` starts on the prototype's own sentence, tokens and all, so the
    /// editor's rendering can be captured without typing it out first; adding
    /// `-ate-gallery-composer-score` opens the slider on its first score.
    init() {
        let arguments = ProcessInfo.processInfo.arguments
        let seeded = arguments.contains("-ate-gallery-composer-seed")
        let composition = seeded ? EntryComposition.previewWordsWithPlace : EntryComposition()
        _composition = State(initialValue: composition)
        if arguments.contains("-ate-gallery-composer-score"),
           let span = composition.spans.first(where: { $0.token.score != nil }) {
            _scoring = State(initialValue: ScoringToken(
                id: span.token.id,
                dishName: "Tagliatelle al ragù",
                rating: span.token.score
            ))
        }
        _photos = State(initialValue: seeded ? [AtePhoto.swatch(AteColor.butter),
                                                AtePhoto.swatch(AteColor.green)] : [])
    }

    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(spacing: 0) {
            header
            editor
            if showsModel { modelReadout }
            toolbar
        }
        .background(AtePalette.automatic.chip)
        .sheet(isPresented: $isPickingPlace) { placeSheet }
    }

    // MARK: - Bands

    private var header: some View {
        HStack {
            AteIconButton(icon: .close, label: "Close") { dismiss() }
            Spacer()
            Button {
                showsModel.toggle()
            } label: {
                Text(showsModel ? "Hide model" : "Show model")
                    .ateText(.meta)
            }
            Button {
                finishPendingLiteral()
            } label: {
                Text("Done")
                    .ateText(.control)
                    .padding(.horizontal, 18)
                    .frame(height: 38)
                    .background(AtePalette.automatic.fg, in: .capsule)
                    .foregroundStyle(AtePalette.automatic.ground)
            }
            .padding(.trailing, AteMetrics.regular)
        }
        .ateContentTop()
        .padding(.leading, AteMetrics.regular)
        .padding(.bottom, AteMetrics.tight)
    }

    private var editor: some View {
        ZStack(alignment: .top) {
            InlineTokenEditor(
                composition: $composition,
                revision: revision,
                caretAfterRender: caretAfterRender,
                style: .composerProse,
                placeholder: "What did you eat?",
                onTokenTap: reopen,
                onCaretChange: { caret = $0 }
            )
            .frame(maxWidth: .infinity, maxHeight: .infinity)

            if let scoring {
                StarSlider(
                    dishName: scoring.dishName,
                    rating: Binding(
                        get: { scoring.rating },
                        set: { self.scoring?.rating = $0 }
                    )
                ) { rating in
                    commit(rating, for: scoring.id)
                }
                .padding(.top, 60)
                .transition(.scale(scale: 0.96).combined(with: .opacity))
            }
        }
        .padding(.horizontal, 22)
        .padding(.top, AteMetrics.snug)
        .overlay(alignment: .bottomLeading) { photoStrip }
    }

    @ViewBuilder
    private var photoStrip: some View {
        if photos.isEmpty == false {
            PhotoCluster(
                photos: photos,
                side: AteMetrics.clusterPhotoComposer,
                surface: AtePalette.automatic.chip
            )
                .padding(.leading, 22)
                .padding(.bottom, AteMetrics.snug)
        }
    }

    /// The spike's own instrument: the model, printed. The words are never rewritten (design rule 9),
    /// and this is what proves it.
    private var modelReadout: some View {
        VStack(alignment: .leading, spacing: AteMetrics.tight) {
            Text("Plain text (saved verbatim)")
                .ateText(.receiptLabel)
                .foregroundStyle(AtePalette.automatic.muted)
            Text(composition.plain.isEmpty ? "—" : composition.plain)
                .ateText(.receiptLine)
                .textSelection(.enabled)
            Text("Tokens · caret \(caret)")
                .ateText(.receiptLabel)
                .foregroundStyle(AtePalette.automatic.muted)
                .padding(.top, AteMetrics.tight)
            ForEach(composition.spans) { span in
                Text(verbatim: describe(span))
                    .ateText(.receiptLine)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(AteMetrics.regular)
        .background(AtePalette.automatic.field)
    }

    private func describe(_ span: EntryTokenSpan) -> String {
        let kind = span.token.score.map { "score \(ScoreFormat.halfStep($0.value))" }
            ?? span.token.place.map { "place \($0.name)" } ?? "?"
        return "[\(span.span.location)..<\(span.span.endLocation)] \(kind)"
    }

    private var toolbar: some View {
        HStack(spacing: 6) {
            HStack(spacing: 0) {
                AteIconButton(icon: .camera, label: "Camera") { addPhoto() }
                AteIconButton(icon: .library, label: "Photo library") { addPhoto() }
                AteIconButton(icon: .voice, label: "Dictate") { }
            }
            Spacer(minLength: 0)
            ComposerKey(
                title: "Score", icon: .starFilled,
                background: AteColor.butter, foreground: AteColor.ink,
                action: insertScore
            )
            ComposerKey(
                title: "Place", icon: .place,
                background: AtePalette.surface.field, foreground: AtePalette.surface.fg
            ) { isPickingPlace = true }
        }
        .padding(.horizontal, AteMetrics.snug)
        .padding(.vertical, AteMetrics.snug)
    }

    // MARK: - Actions

    /// The Score key: puts a token at the caret and opens the slider on it.
    private func insertScore() {
        let token = EntryToken(kind: .score(.minimum))
        let (next, newCaret) = composition.inserting(token, atDisplayOffset: caret)
        composition = next
        caretAfterRender = newCaret
        revision += 1
        // On the token's ACTUAL value: a fresh one is 0.5, so the first star is half filled and the
        // numeral agrees with the pill already in the words.
        scoring = ScoringToken(id: token.id, dishName: dishName(before: token), rating: .minimum)
    }

    /// Tapping an existing token: the slider reopens on it, or the place sheet does.
    private func reopen(_ token: EntryToken) {
        if let rating = token.score {
            scoring = ScoringToken(id: token.id, dishName: dishName(before: token), rating: rating)
        } else if token.place != nil {
            isPickingPlace = true
        }
    }

    private func commit(_ rating: Rating, for tokenID: UUID) {
        composition = composition.replacing(tokenID: tokenID, with: .score(rating))
        revision += 1
        caretAfterRender = nil
        withAnimation(.snappy(duration: 0.2)) { scoring = nil }
    }

    /// Done: anything the person typed that is still only a number becomes a token, exactly as it
    /// would when they moved on by typing.
    private func finishPendingLiteral() {
        guard let found = ScoreLiteral.candidate(
            in: composition.plain,
            caretUTF16: composition.plainOffset(forDisplayOffset: caret)
        ) else { return }
        composition = composition.promoting(plainSpan: found.span, to: EntryToken(kind: .score(found.rating)))
        revision += 1
        caretAfterRender = nil
    }

    /// The words just before a token, as the name of what is being scored. A stand-in for the sorter,
    /// which is what will actually name the dish.
    private func dishName(before token: EntryToken) -> String {
        guard let span = composition.spans.first(where: { $0.token.id == token.id }) else { return "This dish" }
        let units = Array(composition.plain.utf16)
        let prefix = String(decoding: units[0..<min(span.span.location, units.count)], as: UTF16.self)
        let words = prefix
            .split(whereSeparator: { $0.isWhitespace || $0 == "," || $0 == "." })
            .suffix(3)
            .joined(separator: " ")
        return words.isEmpty ? "This dish" : words
    }

    private func addPhoto() {
        photos.append(AtePhoto.swatch(AteColor.accents[photos.count % AteColor.accents.count]))
    }

    private var placeSheet: some View {
        AteSheet(title: "Which place?") {
            VStack(spacing: 0) {
                ForEach(Self.places, id: \.self) { place in
                    AteRadioRow(title: place, isSelected: composition.place?.name == place) {
                        attach(place: place)
                    }
                }
            }
        }
        .presentationDetents([.medium])
    }

    private static let places = ["Tipo 00", "Kisume", "Butchers Diner", "400 Gradi"]

    /// Design rule 8: a place is attached because it was tapped. If one is already there it is
    /// replaced in place; otherwise it goes at the very front, which is where the design puts it.
    private func attach(place name: String) {
        let ref = PlaceRef(id: UUID(), name: name)
        if let existing = composition.spans.first(where: { $0.token.place != nil }) {
            composition = composition.replacing(tokenID: existing.token.id, with: .place(ref))
            caretAfterRender = nil
        } else {
            let (next, newCaret) = composition.inserting(EntryToken(kind: .place(ref)), atDisplayOffset: 0)
            composition = next
            caretAfterRender = newCaret
        }
        revision += 1
        isPickingPlace = false
    }
}

#Preview("Composer spike") { ComposerSpike() }
#endif
