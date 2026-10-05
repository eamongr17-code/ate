import AteKit
import SwiftUI

/// **Name it** (`lists-notifications.html` C2) — New list, or Rename holding the name: close top left,
/// the tick top right, the title, one field. The tick wakes on the first letter. Nothing else is
/// asked: no colour, no cover, no description — the card's colour is given, like an avatar's.
struct ListNameSheet: View {
    let title: String
    let initial: String
    /// The tick: answers whether the name landed (the sheet closes) or was refused (it stays up).
    let onCommit: (String) async -> Bool

    @State private var name: String
    @State private var isBusy = false
    @FocusState private var isFocused: Bool
    @Environment(\.dismiss) private var dismiss

    init(title: String, initial: String, onCommit: @escaping (String) async -> Bool) {
        self.title = title
        self.initial = initial
        self.onCommit = onCommit
        _name = State(initialValue: initial)
    }

    private var trimmed: String { name.trimmingCharacters(in: .whitespacesAndNewlines) }

    var body: some View {
        AteSheetScaffold(
            title: title,
            primary: AteSheetPrimary(
                icon: .check,
                label: ListsCopy.done,
                isEnabled: trimmed.isEmpty == false && isBusy == false,
                isBusy: isBusy,
                action: commit
            )
        ) {
            ListNameField(text: $name, isFocused: $isFocused, onSubmit: commit)
        }
        .onAppear { isFocused = true }
        .onChange(of: name) { _, now in
            if now.count > ListsMetrics.nameLimit { name = String(now.prefix(ListsMetrics.nameLimit)) }
        }
        .interactiveDismissDisabled(isBusy)
    }

    private func commit() {
        guard trimmed.isEmpty == false, isBusy == false else { return }
        isBusy = true
        let name = trimmed
        Task {
            let landed = await onCommit(name)
            isBusy = false
            if landed { dismiss() }
        }
    }
}

/// The one field: the sheet's 50pt pill in the field colour, the name in the row voice.
private struct ListNameField: View {
    @Binding var text: String
    var isFocused: FocusState<Bool>.Binding
    let onSubmit: () -> Void

    @Environment(\.atePalette) private var palette

    var body: some View {
        TextField(text: $text) {
            Text(ListsCopy.namePrompt).foregroundStyle(palette.muted)
        }
        .ateText(.rowTitle)
        .textFieldStyle(.plain)
        .foregroundStyle(palette.fg)
        .tint(AteColor.coral)
        .focused(isFocused)
        .submitLabel(.done)
        .onSubmit(onSubmit)
        .textInputAutocapitalization(.sentences)
        .padding(.horizontal, AteMetrics.loose)
        .atePillHeight(AteMetrics.fieldHeight)
        .background(palette.field, in: .capsule)
        .accessibilityLabel(ListsCopy.namePrompt)
        .accessibilityIdentifier("lists.name")
    }
}
