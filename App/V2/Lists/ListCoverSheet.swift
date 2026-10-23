import AteKit
import SwiftUI
import UIKit

/// **Change cover** (`list-cover-sheet.html` A, approved 23 Oct; replaces `list-cover-edit.html` 2–3)
/// — a sheet that picks one row, built like Add dishes: close, the title, then Automatic (the mosaic
/// it makes), the upload when the cover is one, "Dish photos" over each of the list's dish photos once,
/// and Upload from Photos last. A tap is the answer: the cover changes on the page behind and the sheet
/// closes. Upload goes through Apple's picker and the square crop; its row spins until the photo is up.
struct ListCoverSheet: View {
    let list: ListStore

    /// The cover as the sheet opened.
    private enum Pick: Equatable {
        case automatic
        case item(UUID)
        case upload
    }

    @State private var isChoosing = false
    @State private var isUploading = false
    /// The squared photo while it uploads, shown in the upload's row.
    @State private var fresh: UIImage?
    @State private var photoFailed = false
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        AteSheetScaffold(title: ListsCopy.changeCover) {
            VStack(alignment: .leading, spacing: 0) {
                automatic
                if fresh != nil || current == .upload { uploaded }
                if candidates.isEmpty == false {
                    AteSheetSectionLabel(title: ListsCopy.dishPhotos)
                        .padding(.top, AteMetrics.regular)
                    ForEach(candidates) { item in
                        if let photo = item.photoURL {
                            dish(item, photo: photo)
                        }
                    }
                }
                AteAddRow(
                    title: ListsCopy.uploadFromPhotos, icon: .library,
                    isEnabled: isUploading == false, identifier: "cover.upload"
                ) { isChoosing = true }
            }
            .disabled(isUploading)
        }
        .interactiveDismissDisabled(isUploading)
        .ateCoverPicker(isPresented: $isChoosing, onFailure: { photoFailed = true }, onPicked: upload)
        .alert(ListsCopy.photoFailed, isPresented: $photoFailed) {
            Button("OK", role: .cancel) {}
        }
        .listsFailureAlert(failure: list.failure) { list.clearFailure() }
    }

    // MARK: - Rows

    private var automatic: some View {
        AteCoverChoiceRow(
            title: ListsCopy.automatic,
            subtitle: ListsCopy.automaticFrom(photos: covers.count),
            isOn: current == .automatic && fresh == nil,
            isFirst: true,
            identifier: "cover.automatic"
        ) {
            AteListCover(id: list.listID, name: list.name, covers: covers, style: .row)
        } action: {
            choose(.automatic)
        }
    }

    private var uploaded: some View {
        AteCoverChoiceRow(
            title: ListsCopy.uploadedPhoto,
            isOn: true,
            isBusy: isUploading,
            identifier: "cover.uploaded"
        ) {
            AteListCover(
                id: list.listID, name: list.name, covers: covers,
                cover: list.list?.coverURL, image: fresh, style: .row
            )
        } action: {
            dismiss()
        }
    }

    private func dish(_ item: ListItem, photo: String) -> some View {
        AteCoverChoiceRow(
            title: item.dishName,
            subtitle: item.restaurantName,
            titleStyle: .kitRankedDish,
            isOn: current == .item(item.id) && fresh == nil,
            identifier: "cover.photo"
        ) {
            AteThumb(photo: .dish(item.dishID, name: item.dishName, cover: photo))
        } action: {
            choose(.item(item.id))
        }
    }

    // MARK: - State

    private var candidates: [ListItem] { list.coverCandidates }
    private var covers: [String] { list.list?.covers ?? [] }

    private var current: Pick {
        if let item = list.list?.coverItemID { return .item(item) }
        if list.list?.coverURL != nil { return .upload }
        return .automatic
    }

    // MARK: - Doing

    /// The page behind shows the new cover at once (the store is optimistic); a refusal puts the old
    /// one back and is said there, once the sheet is down.
    private func choose(_ pick: Pick) {
        guard pick != current else {
            dismiss()
            return
        }
        AteHaptics.tick()
        let choice: ListCoverChoice = if case let .item(id) = pick { .item(id) } else { .automatic }
        Task { _ = await list.setCover(choice) }
        dismiss()
    }

    /// The crop's tick: the photo goes up with the sheet still open, its row spinning; a refusal keeps
    /// the sheet up, said once in the alert.
    private func upload(_ jpeg: Data) {
        AteHaptics.key()
        fresh = UIImage(data: jpeg)
        isUploading = true
        Task {
            let saved = await list.setCover(.upload(AvatarUpload(data: jpeg)))
            isUploading = false
            if saved {
                dismiss()
            } else {
                fresh = nil
            }
        }
    }
}
