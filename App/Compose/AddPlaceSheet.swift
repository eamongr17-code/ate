import AteKit
import SwiftUI

/// **`AddPlace`** — "New place". Three pill fields and one ink pill.
///
/// The escape hatch for somewhere Google does not have, which in a launch market of small Melbourne
/// rooms is not an edge case. It writes through `add_manual_restaurant`, the only restaurant-create
/// path that is not `places-search?op=details`.
struct AddPlaceSheet: View {
    let directory: any PlaceDirectory
    var suggestedName: String = ""
    let onAdded: (PlaceRef) -> Void

    @State private var name = ""
    @State private var suburb = ""
    @State private var street = ""
    @State private var isSaving = false
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        AteSheet(
            title: "New place",
            primary: ("Add place", add)
        ) {
            VStack(alignment: .leading, spacing: AteMetrics.loose) {
                field("Name", text: $name)
                field("Suburb", text: $suburb)
                field("Street", text: $street, prompt: "Optional")
            }
            .padding(.top, AteMetrics.tight)
        }
        .ateSurface()
        // `AddPlace.dc.html` is 560 of 844.
        .presentationDetents([.height(AteScreen.sheetHeight(560))])
        .onAppear { if name.isEmpty { name = suggestedName } }
    }

    private func field(_ label: String, text: Binding<String>, prompt: String? = nil) -> some View {
        VStack(alignment: .leading, spacing: AteMetrics.snug - 2) {
            Text(label)
                .ateText(.meta)
                .foregroundStyle(AtePalette.surface.muted)
            TextField(text: text) {
                Text(prompt ?? "").foregroundStyle(AtePalette.surface.muted)
            }
            .ateText(.control)
            .textFieldStyle(.plain)
            .padding(.horizontal, AteMetrics.loose)
            .frame(height: 52)
            .background(AtePalette.surface.field, in: .capsule)
        }
    }

    private func add() {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.isEmpty == false, isSaving == false else { return }
        isSaving = true
        Task {
            defer { isSaving = false }
            guard let place = try? await directory.add(
                name: trimmed,
                suburb: suburb.trimmingCharacters(in: .whitespacesAndNewlines),
                street: street.trimmingCharacters(in: .whitespacesAndNewlines)
            ) else { return }
            onAdded(place)
            dismiss()
        }
    }
}
