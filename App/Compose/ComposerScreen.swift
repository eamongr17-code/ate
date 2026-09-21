import AteKit
import SwiftUI

/// **`Composer`** — one screen, free prose, and the two things that are allowed to live inside it.
///
/// The whole input model is here: you type the way you'd text a friend, and a score or a place
/// becomes a pill *in the sentence* rather than a field beside it (PRODUCT.md decision 2). Nothing
/// blocks writing — no place step, no dish step, no rating step.
///
/// The screen is a control surface, not the app's ground (`Composer` is white; on a chip ground in
/// dark, `field` recesses to the ink ground so the Place key stays visible — see `AtePalette.surface`).
struct ComposerScreen: View {
    let presentation: ComposerPresentation
    let services: AteServices

    @State private var model = ComposerModel()
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(spacing: 0) {
            header
            editor
            toolbar
        }
        .ateSurface()
        .onAppear {
            services.analytics(EntryEvents.composerOpened(source: origin, isResumingDraft: false))
        }
    }

    private var origin: ComposerOrigin {
        switch presentation.origin {
        case .tabBar: .tabBar
        case .journalEmpty: .journalEmpty
        case .entryEdit: .entryEdit
        }
    }

    // MARK: - Bands

    private var header: some View {
        HStack {
            AteIconButton(icon: .close, label: "Close") { dismiss() }
            Spacer(minLength: AteMetrics.snug)
            Button {
                model.promotePendingScoreLiteral().map(services.analytics)
                dismiss()
            } label: {
                Text("Done")
                    .ateText(.control)
                    .padding(.horizontal, 18)
                    .frame(height: 38)
                    .background(AtePalette.surface.fg, in: .capsule)
                    .foregroundStyle(AtePalette.surface.inverted)
            }
            .buttonStyle(.plain)
            .disabled(model.hasContent == false)
            .opacity(model.hasContent ? 1 : 0.4)
            .padding(.trailing, AteMetrics.regular)
        }
        .padding(.top, AteMetrics.contentTop)
        .padding(.leading, AteMetrics.regular)
        .padding(.bottom, AteMetrics.tight)
    }

    private var editor: some View {
        ZStack(alignment: .top) {
            InlineTokenEditor(
                composition: Binding(get: { model.composition }, set: { model.composition = $0 }),
                revision: model.revision,
                caretAfterRender: model.caretAfterRender,
                style: .composerProse,
                placeholder: "What did you eat?",
                focusRequest: model.focusRequest,
                onTokenTap: reopen,
                onCaretChange: { model.caret = $0 }
            )
            .frame(maxWidth: .infinity, maxHeight: .infinity)

            if let scoring = model.scoring {
                StarSlider(
                    dishName: scoring.dishName,
                    rating: Binding(
                        get: { model.scoring?.rating },
                        set: { model.scoring?.rating = $0 }
                    )
                ) { rating in
                    model.commitScore(rating, for: scoring.id)
                }
                .padding(.top, 60)
                .transition(.scale(scale: 0.96).combined(with: .opacity))
            }
        }
        .padding(.horizontal, 22)
        .padding(.top, AteMetrics.snug)
    }

    private var toolbar: some View {
        HStack(spacing: AteMetrics.snug - 2) {
            HStack(spacing: 0) {
                AteIconButton(icon: .camera, label: "Camera") {}
                AteIconButton(icon: .library, label: "Photo library") {}
            }
            Spacer(minLength: 0)
            ComposerKey(
                title: "Score",
                icon: .starFilled,
                background: AteColor.butter,
                foreground: AteColor.ink
            ) {
                services.analytics(model.insertScore())
            }
            ComposerKey(
                title: "Place",
                icon: .place,
                background: AtePalette.surface.field,
                foreground: AtePalette.surface.fg
            ) {}
            Spacer(minLength: 0)
            AteIconButton(
                icon: model.isPublic ? .publicEntry : .privateEntry,
                label: model.isPublic ? "Public. Make private" : "Private. Make public"
            ) {
                model.isPublic.toggle()
            }
        }
        .padding(AteMetrics.snug)
    }

    private func reopen(_ token: EntryToken) {
        _ = model.reopen(token)
    }
}

/// A composer toolbar key: **Score** (butter, an accent, so it carries ink) and **Place** (the field
/// colour, so it carries the surface's own foreground).
///
/// The foreground is a parameter for exactly that reason. Hard-wiring ink — which the spike did —
/// made the Place key near-invisible in dark mode: ink text on a plum pill.
struct ComposerKey: View {
    let title: String
    let icon: AteIcon
    let background: Color
    let foreground: Color
    var isActive = false
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 5) {
                icon.view(size: 15, weight: .semibold)
                Text(title).ateText(.controlSmall)
            }
            .padding(.leading, 9)
            .padding(.trailing, 13)
            .frame(height: AteMetrics.keyHeight)
            .background(isActive ? AtePalette.surface.fg : background, in: .capsule)
            .foregroundStyle(isActive ? AteColor.butter : foreground)
        }
        .buttonStyle(.plain)
    }
}
