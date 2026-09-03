import AteKit
import SwiftUI

/// "＋ Log a dish" — the diary's own door into the log flow (§3.1).
///
/// Deliberately plain. An earlier draft of this row pre-resolved the restaurant from GPS ("Log a
/// dish at Tipo 00"); that was cut because a confident *wrong* guess in a dense strip costs more
/// than the one tap it saves. So the label never changes and the row never asks for location — the
/// location prompt belongs to the WHERE step, the first time it is opened.
///
/// Present and enabled in every phase except signed out, **including loading and failed**: logging a
/// dish must never wait on a read of your history.
struct DiaryComposerRow: View {
    /// Which door this is, for the funnel. The first-run diary reports `diaryEmpty` — same button,
    /// but the first one ever tapped, and that is the number that says whether the empty state works.
    let origin: LogCTAOrigin
    let action: @MainActor () -> Void

    var body: some View {
        Button(action: action) {
            Label("Log a dish", systemImage: "plus.circle")
                .font(Theme.Text.itemTitle)
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(.rect)
        }
        .accessibilityIdentifier("diary.composer")
    }
}

/// "↻ Continue at Tipo 00 · 2 dishes · 20m ago  ✕" (§3.1).
///
/// Two **sibling** controls, never nested: a discard button inside a resume button is a hit-target
/// lottery, and the one thing this row must not do is throw away a sitting somebody meant to reopen.
struct DiaryResumeRow: View {
    let draft: LogDraft
    let onResume: @MainActor () -> Void
    let onDiscard: @MainActor () -> Void

    var body: some View {
        HStack(spacing: Theme.Spacing.regular) {
            Button(action: onResume) {
                HStack(spacing: Theme.Spacing.snug) {
                    Image(systemName: "arrow.counterclockwise")
                    VStack(alignment: .leading, spacing: Theme.Spacing.hairline) {
                        Text("Continue at \(draft.sitting.restaurant.name)")
                            .font(Theme.Text.itemTitle)
                            .foregroundStyle(Theme.Color.textPrimary)
                        Text(summary)
                            .font(Theme.Text.caption)
                            .foregroundStyle(Theme.Color.textSecondary)
                    }
                    Spacer(minLength: 0)
                }
                .contentShape(.rect)
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier("diary.resume")

            Button(action: onDiscard) {
                Image(systemName: "xmark")
                    .foregroundStyle(Theme.Color.textSecondary)
                    .contentShape(.rect)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Discard saved sitting")
            .accessibilityIdentifier("diary.resume.discard")
        }
    }

    /// "2 dishes · 20m ago". The count is the draft's own wording; the age is formatted here so it
    /// follows the reader's locale.
    private var summary: String {
        let age = draft.savedAt.formatted(.relative(presentation: .numeric, unitsStyle: .narrow))
        return "\(draft.dishCountSummary) · \(age)"
    }
}
