import AteKit
import SwiftUI

/// `sheet(item:)` needs an `Identifiable` payload. Carries the name to start from and the names
/// already on screen, so the sheet's guard is evaluated against the same candidate set the standing
/// row's state was decided from — one rule, one spelling.
struct AddDishRequest: Identifiable, Hashable {
    let id = UUID()
    let name: String
    let existingNames: [String]
}

/// §6's minimal add-a-dish form, mirroring ``AddRestaurantSheet``: stock `Form`, one required field,
/// medium detent, no custom chrome.
///
/// **The exact-match guard is the only rule here.** A dish's identity is per-restaurant and
/// case-insensitive (`dishes_identity_uq`), so a second "Margherita" at this restaurant is not a new
/// dish — it's the one already in the list. Rather than fail on Add, the sheet says so and keeps Add
/// disabled *while the name still matches*: the way out is to pick the existing row or to give this
/// one a different name, and both are one edit away. Near-duplicates ("Marg's" vs "Margs") are NOT
/// blocked — that's a merge concern, server-side.
struct AddDishSheet: View {
    let request: AddDishRequest
    /// Resolves inline (insert-or-return). Returns nil on failure — the model owns the error.
    let add: (String) async -> PickedDish?
    /// Parks the result; the host delivers it from the sheet's `onDismiss` so a navigation push
    /// never races a dismissal (the same rule ``AddRestaurantSheet`` documents).
    let onAdded: (PickedDish) -> Void

    @State private var name: String
    @State private var isSaving = false
    @Environment(\.dismiss) private var dismiss

    init(
        request: AddDishRequest,
        add: @escaping (String) async -> PickedDish?,
        onAdded: @escaping (PickedDish) -> Void
    ) {
        self.request = request
        self.add = add
        self.onAdded = onAdded
        _name = State(initialValue: request.name)
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("Dish name", text: $name)
                        .textInputAutocapitalization(.words)
                        .submitLabel(.done)
                        .onSubmit { if canAdd { save() } }
                } footer: {
                    if let existing = exactMatch {
                        Text("There's already a “\(existing)” here — pick it above, or give this one a different name.")
                    }
                }
            }
            .navigationTitle("Add a dish")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    if isSaving {
                        ProgressView()
                    } else {
                        Button("Add", action: save).disabled(!canAdd)
                    }
                }
            }
        }
        .presentationDetents([.medium])
    }

    /// The existing dish this name currently collides with, in its own spelling — quoting what is
    /// already there is more useful than echoing what was typed.
    private var exactMatch: String? {
        request.existingNames.first { DishDedup.isSameName($0, name) }
    }

    private var canAdd: Bool {
        !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && exactMatch == nil
    }

    private func save() {
        guard canAdd, !isSaving else { return }
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        isSaving = true
        Task {
            defer { isSaving = false }
            if let picked = await add(trimmed) {
                onAdded(picked)
                dismiss()
            }
        }
    }
}

#Preview("Exact match") {
    AddDishSheet(
        request: AddDishRequest(name: "Margherita", existingNames: ["Margherita", "Marinara"]),
        add: { _ in nil },
        onAdded: { _ in }
    )
}
