import AteKit
import PhotosUI
import SwiftUI

/// **Settings** — the system's inset grouped list on the linen ground, the build's rows in its order:
/// Handle, Photo, Appearance · How Ate uses AI, Blocked people · Privacy, Terms · Sign out · Delete
/// account, red, last, on its own, confirmed once. Every row either shows what is true on the right
/// or goes somewhere; nothing explains itself.
struct V2SettingsList: View {
    let model: SettingsModel
    let context: V2PageContext

    @State private var photo: PhotosPickerItem?
    @State private var isPickingPhoto = false
    @State private var isConfirmingDelete = false
    /// The data went but the login survived: the session is already over, once the alert is read.
    @State private var endsSessionAfterAlert = false
    @State private var deletedUserID: UUID?
    /// The photo just picked, drawn in the row while it uploads and after it lands.
    @State private var avatarPreview: UIImage?
    /// A write that did not happen, said once.
    @State private var failure: ActionFailure?
    @Environment(\.openURL) private var openURL

    var body: some View {
        List {
            Section {
                AteGroupedRow(title: "Handle", value: model.displayHandle, identifier: "settings.handle") {
                    context.open(.settings(.handle(current: model.handle)))
                }
                AteGroupedRow(title: "Photo", identifier: "settings.photo") {
                    isPickingPhoto = true
                } trailing: {
                    avatar
                }
                AteGroupedPicker(title: "Appearance", selection: Bindable(model).appearance) {
                    ForEach(AteAppearance.allCases, id: \.self) { appearance in
                        Text(appearance.title).tag(appearance)
                    }
                }
                .accessibilityIdentifier("settings.appearance")
            }
            Section {
                AteGroupedRow(title: "How Ate uses AI") { context.open(.settings(.artificialIntelligence)) }
                AteGroupedRow(title: "Blocked people") { context.open(.settings(.blocked)) }
            }
            Section {
                AteGroupedRow(title: "Privacy") { openURL(AteLegal.privacy) }
                AteGroupedRow(title: "Terms") { openURL(AteLegal.terms) }
            }
            Section {
                AteGroupedRow(title: "Sign out", identifier: "settings.signOut") {
                    Task {
                        await AtePush.shared.forgetToken()
                        await model.signOut()
                        context.app.endSession()
                    }
                }
            }
            Section {
                AteGroupedRow(title: "Delete account", isDestructive: true, identifier: "settings.delete") {
                    isConfirmingDelete = true
                }
            }
            builds
        }
        .ateGroupedList()
        .ateInlineTitle("Settings")
        .photosPicker(isPresented: $isPickingPhoto, selection: $photo, matching: .images, photoLibrary: .shared())
        // Apple requires account deletion to be confirmed, and a soft delete is still the end of
        // somebody's journal: a native dialog with the fewest words that can carry it.
        .confirmationDialog("Delete your account?", isPresented: $isConfirmingDelete, titleVisibility: .visible) {
            Button("Delete account", role: .destructive) {
                Task { await deleteAccount() }
            }
            Button("Cancel", role: .cancel) {}
        }
        // Either the server refused (still signed in, nothing gone) or it took the data but not the
        // login — and either way the person has to know that what they asked for did not happen.
        .alert(
            endsSessionAfterAlert ? "Your account wasn't fully deleted." : "Couldn't delete your account.",
            isPresented: Binding(
                get: { model.didFailToDelete && isConfirmingDelete == false },
                set: { if $0 == false { model.acknowledgeFailure() } }
            )
        ) {
            Button("OK", role: .cancel) {
                if endsSessionAfterAlert { context.app.endSession(deleting: deletedUserID) }
            }
        }
        .ateFailureAlert($failure)
        .task { await model.loadIfNeeded() }
        // Back from the handle page: the row shows what the server now holds.
        .onAppear { Task { await model.reloadIfLoaded() } }
        .onChange(of: photo) { _, item in
            guard let item else { return }
            Task { await upload(item) }
        }
    }

    /// In Debug and Beta, the builds with the staging door: the component kit, and Replay first run —
    /// Handle, the onboarding and every tip again, as a new person sees them.
    @ViewBuilder
    private var builds: some View {
        Section {
            if context.services.debugSignIn != nil {
                AteGroupedRow(title: "Component kit") { context.open(.settings(.kit)) }
                AteGroupedRow(title: "Replay first run", identifier: "settings.replayFirstRun") {
                    context.app.replayFirstRun()
                }
            }
        }
    }

    // MARK: - Photo

    /// What is on file, or what was just picked — dimmed while it uploads; the person's letter when
    /// there is no photo at all.
    @ViewBuilder
    private var avatar: some View {
        Group {
            if let avatarPreview {
                Image(uiImage: avatarPreview)
                    .resizable()
                    .scaledToFill()
            } else if let url = model.avatarURL {
                AsyncImage(url: url) { image in
                    image.resizable().scaledToFill()
                } placeholder: {
                    AtePalette.automatic.field
                }
            } else if let userID = model.userID, let handle = model.handle {
                AteAvatar(userID: userID, handle: handle, size: .byline)
            }
        }
        .frame(width: AteGroupedRowMetrics.avatar, height: AteGroupedRowMetrics.avatar)
        .clipShape(.circle)
        .opacity(model.isUploadingAvatar ? AteKitColor.disabledOpacity : 1)
        .accessibilityHidden(true)
    }

    /// Whatever the library hands over (a 12MP HEIC, usually) is drawn down to an avatar before it
    /// leaves the phone: 512 on the long side, JPEG — the largest an avatar is ever shown is 76pt.
    private func upload(_ item: PhotosPickerItem) async {
        defer { photo = nil }
        guard let data = try? await item.loadTransferable(type: Data.self),
              let image = UIImage(data: data),
              let jpeg = AvatarImage.jpeg(from: image) else {
            failure = .avatar
            return
        }
        let previous = avatarPreview
        avatarPreview = UIImage(data: jpeg) ?? image
        await model.setAvatar(AvatarUpload(data: jpeg))
        if model.didFail {
            // The row goes back to what the server still has, and the person is told.
            avatarPreview = previous
            model.acknowledgeFailure()
            failure = .avatar
        }
    }

    // MARK: - Delete

    private func deleteAccount() async {
        // Read before the call: afterwards there is no session to ask.
        deletedUserID = model.userID
        let outcome = await model.deleteAccount()
        // The half-deletion waits for its alert to be read before the session ends.
        if outcome == .deleted { context.app.endSession(deleting: deletedUserID) }
        endsSessionAfterAlert = outcome == .loginSurvived
    }
}

/// An avatar, drawn down from whatever the library gave.
private enum AvatarImage {
    static let pixels: CGFloat = 512
    static let quality: CGFloat = 0.85

    static func jpeg(from image: UIImage) -> Data? {
        let scale = min(1, pixels / max(image.size.width, image.size.height))
        let size = CGSize(width: image.size.width * scale, height: image.size.height * scale)
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        let drawn = UIGraphicsImageRenderer(size: size, format: format).image { _ in
            image.draw(in: CGRect(origin: .zero, size: size))
        }
        return drawn.jpegData(compressionQuality: quality)
    }
}
