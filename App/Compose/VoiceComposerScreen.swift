import AteKit
import SwiftUI

/// **`ComposerVoice`** — the composer with the microphone open.
///
/// The same screen as `Composer`, with two differences and no third: the keyboard's place is taken by a
/// waveform and a stop key, and the words are read-only while they are being said. Everything else is
/// the composer — the same white surface, the same header, the same prose at 19pt with the same pills
/// in it, the same draft on disk.
///
/// The three keys mean what they mean everywhere else, which is why there is no copy explaining them:
/// **stop** goes back to the keyboard with the words in place, **Done** saves the entry (as it does on
/// `Composer`), and **close** leaves the composer with the draft kept. Tapping the words is the fourth,
/// unlabelled way back: it is where you would reach to correct one, so it goes to the keyboard too.
///
/// It is laid over `Composer` rather than presented: the editor underneath stays mounted, so the
/// words come back into the same text view, with the same undo stack, in one edit.
struct VoiceComposerScreen: View {
    let composer: ComposerModel
    /// Owned by the composer and made once per spell of dictation — never per render, which would
    /// build a new audio engine and recogniser for every partial result.
    let model: DictationController
    /// Back to the keyboard — the stop key, or a tap on the words.
    var onStop: () -> Void
    /// Done — the entry is finished. The composer's own save path, so the two Dones are one behaviour.
    var onDone: () -> Void
    /// The close key: leave the composer entirely. The words stay in the draft, as they do everywhere.
    var onClose: () -> Void

    @Environment(\.openURL) private var openURL
    @Environment(\.scenePhase) private var scenePhase

    var body: some View {
        VStack(spacing: 0) {
            header
            words
            band
        }
        .ateSurface()
        // The keyboard is not part of this screen; the band keeps its place when one is dismissing.
        // And the artboard's `padding-bottom:72px` is measured from the bottom of the *screen*, home
        // indicator included — inside the safe area the key sat 34 points high.
        .ignoresSafeArea(.keyboard)
        .ignoresSafeArea(.container, edges: .bottom)
        .task { await model.start() }
        // Back from Settings with the microphone allowed: listen, rather than make them tap again.
        .onChange(of: scenePhase) { _, phase in
            guard phase == .active, case .denied = model.state else { return }
            Task { await model.retry() }
        }
        // Closed from under us: the words said so far belong in the composer rather than in a
        // session nobody can see.
        .onDisappear { model.stop(refocus: false) }
    }

    private func backToKeyboard() {
        model.stop(refocus: true)
        onStop()
    }

    // MARK: - Bands

    /// `padding:60px 12px 4px`, close on the left and Done on the right — the composer's own header,
    /// key for key.
    private var header: some View {
        HStack {
            AteIconButton(icon: .close, label: "Close") {
                model.stop(refocus: false)
                onClose()
            }
            Spacer(minLength: AteMetrics.snug)
            ComposerDoneButton(isEnabled: composer.hasContent) {
                model.stop(refocus: false)
                onDone()
            }
            .accessibilityIdentifier("voice.done")
        }
        .ateContentTop()
        .padding(.leading, AteMetrics.regular)
        .padding(.bottom, AteMetrics.tight)
    }

    /// The words as they are being said: settled in full ink, the recogniser's current guess muted.
    ///
    /// Scrolling is the one thing the artboard does not draw and cannot — it holds one short sentence.
    /// Dictation grows, and words you cannot see are words you cannot correct, so the tail is kept in
    /// view. A short entry sits exactly where the artboard puts it: at the top of the column.
    private var words: some View {
        ScrollViewReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: Self.columnGap) {
                    InlineTokenText(
                        composition: composer.composition,
                        style: .composerProse,
                        volatileFromPlainOffset: model.volatilePlainStart
                    )
                    .frame(maxWidth: .infinity, alignment: .topLeading)
                    // The artboard's draft has no photos; one that does keeps them under the words,
                    // exactly where `Composer` puts them, so nothing jumps when the microphone opens.
                    if composer.photos.isEmpty == false {
                        PhotoCluster(
                            photos: composer.photos.map(\.photo),
                            side: AteMetrics.clusterPhotoComposer,
                            surface: AtePalette.surface.ground
                        )
                    }
                }
                Color.clear.frame(height: 1).id(Self.tailID)
            }
            .contentShape(.rect)
            .onTapGesture { backToKeyboard() }
            .scrollIndicators(.hidden)
            .onChange(of: composer.composition) { _, _ in
                proxy.scrollTo(Self.tailID, anchor: .bottom)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .padding(.horizontal, 22)
        .padding(.vertical, AteMetrics.snug)
        .accessibilityIdentifier("voice.words")
    }

    private static let tailID = "voice.tail"
    /// `.col{gap:16px}` — the voice artboard's column.
    private static let columnGap: CGFloat = 16

    /// `align-items:center;gap:26px;padding:0 0 72px` — the waveform, then the key.
    private var band: some View {
        VStack(spacing: 26) {
            VoiceWaveform(levels: model.levels, isLive: isListening)
            key
        }
        .padding(.bottom, 72)
    }

    private var isListening: Bool {
        if case .listening = model.state { return true }
        return false
    }

    /// The 120pt coral pulse with the 64pt ink circle inside it. Refused, there is no pulse and no
    /// square: the key is the field colour — the app's own way of saying a control is present but not
    /// live — and it goes to Settings. No copy, per design rule 1.
    @ViewBuilder
    private var key: some View {
        switch model.state {
        case .denied:
            Button {
                if let url = URL(string: UIApplication.openSettingsURLString) { openURL(url) }
            } label: {
                AteIcon.voice.view(size: 28)
                    .frame(width: Self.keySide, height: Self.keySide)
                    .background(AtePalette.surface.field, in: .circle)
                    .foregroundStyle(AtePalette.surface.fg)
            }
            .buttonStyle(.plain)
            .frame(width: Self.pulseSide, height: Self.pulseSide)
            .accessibilityLabel("Microphone is off. Open Settings")
            .accessibilityIdentifier("voice.denied")
        case .starting, .listening, .stopped:
            ZStack {
                VoicePulse(isAnimating: isListening)
                Button {
                    backToKeyboard()
                } label: {
                    // The key sits on the coral pulse, an accent ground: ink circle, white square —
                    // `background:#24141F; color:#FFFFFF` — in both modes.
                    AteIcon.stop.view(size: 30)
                        .frame(width: Self.keySide, height: Self.keySide)
                        .background(Self.onPulse.fg, in: .circle)
                        .foregroundStyle(Self.onPulse.inverted)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Stop dictating")
                .accessibilityIdentifier("voice.stop")
            }
            .frame(width: Self.pulseSide, height: Self.pulseSide)
        }
    }

    /// `ComposerVoice.dc.html`: a 120pt box, a 64pt key inside it, the coral square's 40pt radius.
    private static let pulseSide: CGFloat = 120
    private static let onPulse = AtePalette.accent(AteColor.coral)
    private static let keySide: CGFloat = 64
    fileprivate static let pulseRadius: CGFloat = 40
}

/// The coral square behind the stop key, breathing. `@keyframes pulse{50%{transform:scale(1.1)}}` at
/// 1.6s — one of the four motions the design allows, and gated on Reduce Motion like the other three.
private struct VoicePulse: View {
    let isAnimating: Bool

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var isExpanded = false

    var body: some View {
        RoundedRectangle(cornerRadius: VoiceComposerScreen.pulseRadius, style: .continuous)
            .fill(AteColor.coral)
            .scaleEffect(isExpanded ? 1.1 : 1)
            .onAppear {
                guard reduceMotion == false, isAnimating else { return }
                withAnimation(
                    .easeInOut(duration: AteMotion.voicePulse / 2).repeatForever(autoreverses: true)
                ) {
                    isExpanded = true
                }
            }
            .accessibilityHidden(true)
    }
}

/// **The waveform.** Nineteen 4pt bars on a 5pt gap inside a 64pt row, exactly as the artboard draws
/// them; the heights are how loud the room has been, newest on the right, and the every-third-bar
/// half-opacity is the artboard's own rhythm rather than anything about the sound.
struct VoiceWaveform: View {
    let levels: [Float]
    var isLive = true

    @Environment(\.atePalette) private var palette
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        HStack(spacing: Self.gap) {
            ForEach(0..<DictationController.barCount, id: \.self) { index in
                Capsule(style: .continuous)
                    .fill(palette.fg)
                    .opacity(index.isMultiple(of: 3) ? 0.4 : 1)
                    .frame(width: Self.barWidth, height: height(at: index))
            }
        }
        .frame(height: Self.rowHeight)
        .ateAnimation(.easeOut(duration: 0.12), value: levels)
        .accessibilityHidden(true)
    }

    /// The oldest bars sit on the left, so a history shorter than the row starts flat rather than
    /// bunched at one end.
    private func height(at index: Int) -> CGFloat {
        let missing = DictationController.barCount - levels.count
        guard isLive, index >= missing, index - missing < levels.count else { return Self.minimum }
        let level = CGFloat(levels[index - missing])
        return Self.minimum + (Self.maximum - Self.minimum) * min(1, max(0, level))
    }

    /// `width:4px`, `gap:5px`, `height:64px`, and the artboard's own 10…60 range of bar heights.
    private static let barWidth: CGFloat = 4
    private static let gap: CGFloat = 5
    private static let rowHeight: CGFloat = 64
    private static let minimum: CGFloat = 10
    private static let maximum: CGFloat = 60
}
