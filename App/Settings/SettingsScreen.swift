import AteKit
import PhotosUI
import SwiftUI

/// **`Settings`** — eight rows and a ninth in red, exactly as they are drawn.
///
/// No tab bar (the artboard has none: this is a page you are in, not a place you are), no section
/// headings, no explanatory lines under anything. Every row either shows what is true on the right
/// or goes somewhere.
struct SettingsScreen: View {
    let model: SettingsModel
    var onOpen: (SettingsPage) -> Void = { _ in }
    var onSignedOut: () -> Void = {}
    /// Delete account finished; carries whose account it was.
    var onDeleted: (UUID?) -> Void = { _ in }
    var onBack: () -> Void = {}

    @State private var photo: PhotosPickerItem?
    @State private var isConfirmingDelete = false
    /// The data went but the login survived: the session is already over, once the alert is read.
    @State private var endsSessionAfterAlert = false
    @State private var deletedUserID: UUID?
    @Environment(\.openURL) private var openURL

    var body: some View {
        AteSettingsPage(title: "Settings", onBack: onBack) {
            VStack(spacing: 0) {
                AteSettingsRow(title: "Handle", value: model.displayHandle) { onOpen(.handle(current: model.handle)) }
                photoRow
                AteSettingsRow(title: "Appearance", value: model.appearance.title) { onOpen(.appearance) }
                AteSettingsRow(title: "How Ate uses AI") { onOpen(.artificialIntelligence) }
                AteSettingsRow(title: "Blocked people") { onOpen(.blocked) }
                AteSettingsRow(title: "Privacy") { openURL(AteLegal.privacy) }
                AteSettingsRow(title: "Terms") { openURL(AteLegal.terms) }
                AteSettingsRow(title: "Sign out") {
                    Task {
                        await model.signOut()
                        onSignedOut()
                    }
                }
                AteSettingsRow(title: "Delete account", isDestructive: true, showsChevron: false) {
                    isConfirmingDelete = true
                }
            }
        }
        // The one confirmation in the app. Apple requires account deletion to be confirmed, and a
        // soft delete is still the end of somebody's journal — so this is a native dialog with the
        // fewest words that can carry it, and no explanatory paragraph.
        .confirmationDialog("Delete your account?", isPresented: $isConfirmingDelete, titleVisibility: .visible) {
            Button("Delete account", role: .destructive) {
                Task {
                    // Read before the call: afterwards there is no session to ask.
                    deletedUserID = model.userID
                    let outcome = await model.deleteAccount()
                    // The half-deletion waits for its alert to be read before the page goes away.
                    if outcome == .deleted { onDeleted(deletedUserID) }
                    endsSessionAfterAlert = outcome == .loginSurvived
                }
            }
            Button("Cancel", role: .cancel) {}
        }
        // Not drawn on the artboard. Either the server refused (still signed in, nothing gone) or
        // it took the data but not the login — and either way the person has to know that what they
        // asked for did not happen, in the fewest words that say so.
        .alert(
            endsSessionAfterAlert ? "Your account wasn't fully deleted." : "Couldn't delete your account.",
            isPresented: Binding(
                get: { model.didFailToDelete && isConfirmingDelete == false },
                set: { if $0 == false { model.acknowledgeFailure() } }
            )
        ) {
            Button("OK", role: .cancel) {
                if endsSessionAfterAlert { onDeleted(deletedUserID) }
            }
        }
        .task { await model.loadIfNeeded() }
        // Back from the handle page: the row shows what the server now holds.
        .onAppear { Task { await model.reloadIfLoaded() } }
        .onChange(of: photo) { _, item in
            guard let item else { return }
            Task { await upload(item) }
        }
    }

    /// Photo. The row is drawn with a chevron and no value, so the picker is put *behind* it rather
    /// than replacing it with a control of its own.
    private var photoRow: some View {
        PhotosPicker(selection: $photo, matching: .images, photoLibrary: .shared()) {
            AteSettingsRow(title: "Photo")
        }
        .buttonStyle(.plain)
    }

    /// Whatever the library hands over (a 12MP HEIC, usually) is drawn down to an avatar before it
    /// leaves the phone: 512 on the long side, JPEG — the largest an avatar is ever shown is 76pt.
    private func upload(_ item: PhotosPickerItem) async {
        defer { photo = nil }
        guard let data = try? await item.loadTransferable(type: Data.self),
              let image = UIImage(data: data) else { return }
        let side = SettingsScreen.avatarPixels
        let scale = min(1, side / max(image.size.width, image.size.height))
        let size = CGSize(width: image.size.width * scale, height: image.size.height * scale)
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        let drawn = UIGraphicsImageRenderer(size: size, format: format).image { _ in
            image.draw(in: CGRect(origin: .zero, size: size))
        }
        guard let jpeg = drawn.jpegData(compressionQuality: 0.85) else { return }
        await model.setAvatar(AvatarUpload(data: jpeg))
    }

    private static let avatarPixels: CGFloat = 512
}

#if DEBUG
#Preview("Settings") {
    SettingsScreen(model: SettingsModel(
        account: InMemoryAccountService(),
        preferences: AtePreferences(store: InMemoryKeyValueStore())
    ))
}
#endif
