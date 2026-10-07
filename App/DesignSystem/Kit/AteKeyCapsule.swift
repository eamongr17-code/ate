import AteKit
import SwiftUI

/// **The composer's keys, floating in one glass capsule above the keyboard** (pattern contract §3,
/// locked): camera and library, then Score and Place with their labels, then Diet as a leaf alone.
/// The Diet key unfolds the capsule into the five codes behind a back arrow, springing out of the key
/// (``ComposerDietUnfold``, round 5 "unfold B"), and a code folds it straight back.
///
/// The capsule is iOS 26's own Liquid Glass (`GlassEffectContainer` + `.glassEffect`); the keys keep
/// their butter and field fills on it. The library key is the caller's (it is a `PhotosPicker`, which
/// needs the caller's selection), handed in as `library`.
struct AteKeyCapsule<Library: View>: View {
    /// What the Place key holds, if a place is attached.
    let place: String?
    /// The Score key inverts (ink) while its slider is open.
    let isScoring: Bool
    @Binding var isChoosingDiet: Bool
    var isCameraEnabled = true
    let onCamera: () -> Void
    let onScore: () -> Void
    let onPlace: () -> Void
    /// The Diet key was pressed: anything open (the slider) closes before the codes unfold.
    let onDiet: () -> Void
    let onCode: (DietTag) -> Void
    /// The codes the dish at the caret already wears: on in the unfold, and a press takes one off.
    var worn: [DietTag] = []
    /// "Ate with": the people on the With key, and what it opens. No key at all without `onWith`.
    var with: [AteWithPerson] = []
    var onWith: (() -> Void)?
    @ViewBuilder var library: Library

    @Environment(\.atePalette) private var palette
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    var body: some View {
        GlassEffectContainer {
            ComposerDietUnfold(isChoosingDiet: isChoosingDiet, keys: keys, back: back, code: code)
                .padding(.vertical, AteKeyCapsuleMetrics.inset)
                .padding(.leading, AteKeyCapsuleMetrics.inset)
                .padding(.trailing, AteKeyCapsuleMetrics.trailing)
                .glassEffect(.regular, in: .rect(cornerRadius: AteKeyCapsuleMetrics.radius))
        }
        .padding(.horizontal, AteKeyCapsuleMetrics.margin)
        .padding(.bottom, AteKeyCapsuleMetrics.inset)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("composer.keys")
    }

    private var keys: some View {
        // At the accessibility sizes the keys need the whole width: they take a line of their own
        // under the media keys (the current composer's rule).
        let layout = dynamicTypeSize.isAccessibilitySize
            ? AnyLayout(VStackLayout(alignment: .leading, spacing: AteKeyCapsuleMetrics.gap))
            : AnyLayout(HStackLayout(spacing: AteKeyCapsuleMetrics.gap))
        return layout {
            HStack(spacing: 0) {
                AteIconButton(icon: .camera, label: "Camera", tint: palette.fg, action: onCamera)
                    .disabled(isCameraEnabled == false)
                    .accessibilityIdentifier("composer.camera")
                library
                    .foregroundStyle(palette.fg)
                    .accessibilityLabel("Photo library")
                    .accessibilityIdentifier("composer.library")
            }
            .fixedSize()
            HStack(spacing: AteKeyCapsuleMetrics.gap) {
                AteKey(kind: .score, isActive: isScoring, action: onScore)
                AteKey(kind: .place(place), action: onPlace)
                    // The place gives way first: Score and Diet keep their size, the name truncates.
                    .layoutPriority(-1)
                AteKey(kind: .diet) {
                    onDiet()
                    isChoosingDiet = true
                }
                if let onWith {
                    AteKey(kind: .with(with), action: onWith)
                }
            }
            .frame(maxWidth: .infinity, alignment: .trailing)
        }
    }

    private var back: some View {
        AteIconButton(icon: .back, label: "Back", tint: palette.fg) { isChoosingDiet = false }
            .accessibilityIdentifier("composer.diet.back")
    }

    private func code(_ tag: DietTag) -> some View {
        AteKey(kind: .code(tag), isActive: worn.contains(tag)) {
            isChoosingDiet = false
            onCode(tag)
        }
    }
}

/// The library key's face — the image glyph in a 44 target — for the caller's `PhotosPicker`.
struct AteLibraryKeyFace: View {
    var body: some View {
        AteIcon.library.view(size: AteGlassDiscMetrics.glyph)
            .frame(width: AteMetrics.hit, height: AteMetrics.hit)
            .contentShape(.rect)
    }
}

enum AteKeyCapsuleMetrics {
    /// The capsule's inset around its keys, and its distance from the keyboard: 8.
    static let inset: CGFloat = 8
    /// The keys sit in a little further from the trailing edge: 10.
    static let trailing: CGFloat = 10
    /// Between the groups and between the keys: `gap:6px`.
    static let gap: CGFloat = 6
    /// The capsule's distance from the screen's sides.
    static let margin: CGFloat = 8
    /// A key is 40 high in an 8 inset: half of 56 rounds the ends.
    static let radius: CGFloat = 28
}
