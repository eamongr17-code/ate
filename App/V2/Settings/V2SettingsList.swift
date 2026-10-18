import AteKit
import SwiftUI

/// **Settings** — the system's inset grouped list on the linen ground, the build's rows in its order:
/// Handle, Photo, Appearance · Blocked people, Tutorial · Privacy, Terms · Sign out · Delete account,
/// red, last, on its own, confirmed once. Every row either shows what is true on the right
/// or goes somewhere; nothing explains itself.
struct V2SettingsList: View {
    let model: SettingsModel
    let context: V2PageContext

    @State private var isPickingPhoto = false
    @State private var isConfirmingDelete = false
    @State private var isShowingTutorial = false
    /// The data went but the login survived: the session is already over, once the alert is read.
    @State private var endsSessionAfterAlert = false
    @State private var deletedUserID: UUID?
    /// The photo just picked, drawn in the row while it uploads and after it lands.
    @State private var avatarPreview: UIImage?
    /// A write that did not happen, said once.
    @State private var failure: ActionFailure?

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
                AteGroupedRow(title: "Blocked people") { context.open(.settings(.blocked)) }
                AteGroupedRow(title: "Tutorial", identifier: "settings.tutorial") { isShowingTutorial = true }
            }
            Section {
                AteGroupedRow(title: "Privacy", identifier: "settings.privacy") { context.open(.settings(.privacy)) }
                AteGroupedRow(title: "Terms", identifier: "settings.terms") { context.open(.settings(.terms)) }
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
        }
        .ateGroupedList()
        .ateInlineTitle("Settings")
        // Apple's picker, then the photo placed in its circle; nothing is sent until the tick.
        .ateAvatarPicker(
            isPresented: $isPickingPhoto,
            onFailure: { failure = .avatar },
            onPicked: { jpeg in Task { await upload(jpeg) } }
        )
        // The onboarding's three cards again, on their own: no handle, no photo ask, no sign-out.
        .fullScreenCover(isPresented: $isShowingTutorial) {
            V2Tutorial(handle: context.app.handle ?? model.handle ?? "") { reached, skipped in
                context.services.analytics(OnboardingEvents.tutorial(reached: reached, skipped: skipped))
                isShowingTutorial = false
            }
        }
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
        // What the server holds is everybody's: a new photo shows on You, your bylines, everywhere.
        .onChange(of: model.avatarURL) { _, url in
            guard let userID = model.userID else { return }
            AteAvatarDirectory.shared.note(userID, url: url)
        }
        // Back from the handle page: the row shows what the server now holds.
        .onAppear { Task { await model.reloadIfLoaded() } }
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

    /// What is in the circle, already drawn down to an avatar (``AvatarImage``): shown at once, dimmed
    /// while it uploads.
    private func upload(_ jpeg: Data) async {
        let previous = avatarPreview
        avatarPreview = UIImage(data: jpeg)
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
