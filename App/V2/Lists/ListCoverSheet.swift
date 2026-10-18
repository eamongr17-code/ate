import AteKit
import SwiftUI
import UIKit

/// **Change cover** (`list-cover-edit.html` 2–3, approved 18 Oct) — close, "Cover", the ink tick.
/// The preview is exactly what the list will look like. Under it, Upload from Photos (Apple's
/// picker, then the photo squared up in the cover's own shape), then the list's dish photos, each
/// once. Nothing is ticked while the cover is automatic; tapping the pick again unticks it and the
/// preview goes back to the mosaic. The tick saves; the close leaves the cover as it was.
struct ListCoverSheet: View {
    let list: ListStore

    /// What the sheet will save: the cover as it opened, or a change.
    private enum Pick: Equatable {
        case automatic
        case item(UUID)
        /// The upload already on the list.
        case kept
        /// A photo just squared up, not yet sent.
        case fresh(Data)
    }

    @State private var pick: Pick
    @State private var picked: UIImage?
    @State private var isChoosing = false
    @State private var isSaving = false
    @State private var photoFailed = false
    @Environment(\.dismiss) private var dismiss

    private let opened: Pick

    init(list: ListStore) {
        self.list = list
        let opened: Pick = if let item = list.list?.coverItemID {
            .item(item)
        } else if list.list?.coverURL != nil {
            .kept
        } else {
            .automatic
        }
        self.opened = opened
        _pick = State(initialValue: opened)
    }

    var body: some View {
        AteSheetScaffold(
            title: ListsCopy.cover,
            primary: AteSheetPrimary(
                icon: .check, label: ListsCopy.done, isEnabled: pick != opened, isBusy: isSaving, action: save
            )
        ) {
            VStack(alignment: .leading, spacing: 0) {
                preview
                    .frame(maxWidth: .infinity)
                    .padding(.bottom, ListCoverSheetMetrics.previewBottom)
                AteCoverUploadRow(title: ListsCopy.uploadFromPhotos, isOn: isUpload, action: upload)
                if candidates.isEmpty == false {
                    AteHairline()
                    AteBandHeading(title: ListsCopy.photosInThisList)
                        .padding(.top, ListCoverSheetMetrics.bandTop)
                        .padding(.bottom, ListCoverSheetMetrics.bandBottom)
                        .accessibilityAddTraits(.isHeader)
                    grid
                }
            }
        }
        .ateCoverPicker(isPresented: $isChoosing, onFailure: { photoFailed = true }, onPicked: took)
        .alert(ListsCopy.photoFailed, isPresented: $photoFailed) {
            Button("OK", role: .cancel) {}
        }
        .listsFailureAlert(failure: list.failure) { list.clearFailure() }
    }

    // MARK: - Parts

    private var preview: some View {
        AteListCover(
            id: list.listID,
            name: list.name,
            covers: list.list?.covers ?? [],
            cover: previewCover,
            image: pickedImage,
            style: .preview
        )
        .animation(.easeOut(duration: ListCoverSheetMetrics.fade), value: pick)
    }

    private var grid: some View {
        LazyVGrid(
            columns: Array(
                repeating: GridItem(.flexible(), spacing: AteListPeopleMetrics.cellGap),
                count: AteListPeopleMetrics.columns
            ),
            spacing: AteListPeopleMetrics.cellGap
        ) {
            ForEach(candidates) { item in
                if let photo = item.photoURL {
                    AteCoverPhotoCell(url: photo, name: item.dishName, isOn: pick == .item(item.id)) {
                        choose(item)
                    }
                }
            }
        }
    }

    // MARK: - State

    private var candidates: [ListItem] { list.coverCandidates }

    private var isUpload: Bool {
        switch pick {
        case .kept, .fresh: true
        case .automatic, .item: false
        }
    }

    private var previewCover: String? {
        switch pick {
        case .automatic, .fresh: nil
        case let .item(id): candidates.first { $0.id == id }?.photoURL
        case .kept: list.list?.coverURL
        }
    }

    private var pickedImage: UIImage? {
        if case .fresh = pick { return picked }
        return nil
    }

    // MARK: - Doing

    /// The upload row: Photos when nothing is uploaded, and unticks an upload already picked.
    private func upload() {
        if isUpload {
            AteHaptics.tick()
            pick = .automatic
        } else {
            isChoosing = true
        }
    }

    /// The crop's tick: the squared photo, shown in the preview until the sheet's own tick sends it.
    private func took(_ jpeg: Data) {
        picked = UIImage(data: jpeg)
        pick = .fresh(jpeg)
        AteHaptics.tick()
    }

    private func choose(_ item: ListItem) {
        AteHaptics.tick()
        pick = pick == .item(item.id) ? .automatic : .item(item.id)
    }

    private func save() {
        let choice: ListCoverChoice
        switch pick {
        case .automatic: choice = .automatic
        case let .item(id): choice = .item(id)
        case let .fresh(data): choice = .upload(AvatarUpload(data: data))
        case .kept:
            dismiss()
            return
        }
        AteHaptics.key()
        isSaving = true
        Task {
            let saved = await list.setCover(choice)
            isSaving = false
            // A refusal keeps the sheet up, said once in the alert.
            if saved { dismiss() }
        }
    }
}

enum ListCoverSheetMetrics {
    /// `.prev{top:78px; height:176px}` to `.opts{top:278px}`: 24 under the preview.
    static let previewBottom: CGFloat = 24
    /// `.band{padding-top:22px; padding-bottom:12px}`.
    static let bandTop: CGFloat = 22
    static let bandBottom: CGFloat = 12
    /// `.prev>div{transition:opacity .15s}`.
    static let fade: Double = 0.15
}
