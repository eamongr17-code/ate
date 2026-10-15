import AteKit
import SwiftUI

/// **Add a dish** (`beta-saved` mockup): one you mean to eat, somewhere real. Dish and place are
/// needed; the link is optional and says where it came from (TikTok, Instagram, any other page). The
/// place is chosen on the composer's own place sheet, so it is never guessed.
struct SavedAddSheet: View {
    let app: AppModel

    @State private var dish = ""
    @State private var place: PlaceRef?
    @State private var link = ""
    @State private var isPickingPlace = false
    @State private var isSaving = false
    @State private var failure: ActionFailure?
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        AteSheetScaffold(
            title: "Add a dish",
            primary: AteSheetPrimary(
                icon: .check,
                label: "Save",
                isEnabled: draft != nil,
                isBusy: isSaving,
                action: save
            )
        ) {
            VStack(alignment: .leading, spacing: AteMetrics.sheetGap) {
                AteFieldPill(label: "Dish", text: $dish, identifier: "saved.add.dish")
                AtePickPill(
                    label: "Place",
                    icon: .place,
                    value: place?.name,
                    prompt: "Find the place",
                    identifier: "saved.add.place"
                ) { isPickingPlace = true }
                AteFieldPill(label: "Link", text: $link, prompt: "Paste a link", identifier: "saved.add.link")
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .keyboardType(.URL)
            }
        }
        .v2PlaceSheet(
            isPresented: $isPickingPlace,
            directory: app.services.places,
            title: V2PlaceSheet.savedTitle,
            selected: { place?.id },
            onPick: { picked in place = picked }
        )
        .v2FailureAlert($failure, analytics: app.services.analytics)
    }

    private var draft: OwnSaveDraft? {
        guard let place, let id = place.id else { return nil }
        let draft = OwnSaveDraft(dishName: dish, restaurantID: id, restaurantName: place.name, link: link)
        return draft.trimmedDishName == nil ? nil : draft
    }

    private func save() {
        guard let draft, isSaving == false else { return }
        isSaving = true
        Task {
            defer { isSaving = false }
            if await app.ownSaves.add(draft, from: .saved) {
                AteHaptics.success()
                dismiss()
            } else {
                failure = .addOwnSave
            }
        }
    }
}

/// **A dish you saved yourself, opened** — a sheet, not a page: nobody has reviewed it, so there is
/// nothing to read. The place, where it came from (the link opens it), and "I ate it", which starts
/// the review with the place and the dish already in.
struct SavedOwnSheet: View {
    let save: OwnSave
    let app: AppModel
    let onAteIt: () -> Void

    @Environment(\.openURL) private var openURL

    var body: some View {
        AteSheetScaffold(title: save.dishName) {
            VStack(alignment: .leading, spacing: AteMetrics.sheetGap) {
                Text(SavedOwnCopy.place(of: save))
                    .ateText(.meta)
                    .foregroundStyle(AtePalette.automatic.muted)
                if let url = save.sourceURL.flatMap(URL.init(string:)) {
                    AteOpenRow(
                        title: SavedOwnCopy.linkTitle(save),
                        subtitle: save.sourceCaption,
                        icon: save.source.mark,
                        identifier: "saved.own.link"
                    ) {
                        app.services.analytics(OwnSaveEvents.linkOpened(source: save.source))
                        openURL(url)
                    }
                }
                AteInkPill(title: "I ate it", identifier: "saved.own.ateIt", action: onAteIt)
            }
        }
        .onAppear { app.services.analytics(OwnSaveEvents.opened(source: save.source)) }
    }
}

enum SavedOwnCopy {
    /// The place, and its city after it.
    static func place(of save: OwnSave) -> String {
        guard let city = save.restaurantCity, city.isEmpty == false else { return save.restaurantName }
        return "\(save.restaurantName), \(city)"
    }

    /// "@sydneyeats on TikTok", "On Instagram", or the link's own site — the share card's own line.
    static func linkTitle(_ save: OwnSave) -> String {
        OwnSaveSourceLine.title(source: save.source, url: save.sourceURL, author: save.sourceAuthor)
    }
}
