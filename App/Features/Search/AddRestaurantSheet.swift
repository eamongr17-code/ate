import AteKit
import SwiftUI

/// §11.2: "a small stock Form sheet (Name prefilled · Suburb · Cuisine, only Name required)".
///
/// Stock `Form` on a medium detent — no custom chrome. On success it resolves and continues, so the
/// user lands where they were going rather than back in a list they already gave up on.
struct AddRestaurantSheet: View {
    let name: String
    /// Performs the `add_manual_restaurant` RPC. Returns nil on failure — the model owns the error.
    let add: (String, String, String) async -> PickedRestaurant?
    let onAdded: (PickedRestaurant) -> Void

    @State private var editedName: String
    @State private var suburb = ""
    @State private var cuisine = ""
    @State private var isSaving = false
    @Environment(\.dismiss) private var dismiss

    init(
        name: String,
        add: @escaping (String, String, String) async -> PickedRestaurant?,
        onAdded: @escaping (PickedRestaurant) -> Void
    ) {
        self.name = name
        self.add = add
        self.onAdded = onAdded
        _editedName = State(initialValue: name)
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("Name", text: $editedName)
                        .textInputAutocapitalization(.words)
                    TextField("Suburb", text: $suburb)
                        .textInputAutocapitalization(.words)
                    TextField("Cuisine", text: $cuisine)
                        .textInputAutocapitalization(.words)
                } footer: {
                    Text("Only the name is required.")
                }
            }
            .navigationTitle("Add a restaurant")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    if isSaving {
                        ProgressView()
                    } else {
                        Button("Add", action: save)
                            .disabled(editedName.nilIfBlank == nil)
                    }
                }
            }
        }
        .presentationDetents([.medium])
    }

    private func save() {
        guard let trimmed = editedName.nilIfBlank, !isSaving else { return }
        isSaving = true
        Task {
            defer { isSaving = false }
            if let picked = await add(trimmed, suburb, cuisine) {
                dismiss()
                onAdded(picked)
            }
        }
    }
}
