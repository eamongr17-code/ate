import AteKit
import SwiftUI

/// **Settings** (`design/rebuild/settings-redesign.html` B, Eamon's pick 26 Oct) — the system's inset
/// grouped list on the linen ground, each row after its line icon: Photo, Handle, Diet · This iPhone:
/// Appearance and what iOS allows (Notifications, Photos, Location, Camera) · Blocked people · Help:
/// Tutorial, Send feedback, Email us, Replay onboarding (TestFlight only) · Legal · Sign out · Delete
/// account, red, on its own, confirmed once · the version. Every row either shows what is true on
/// the right or goes somewhere; nothing explains itself.
struct V2SettingsList: View {
    let model: SettingsModel
    let context: V2PageContext

    @State private var isPickingPhoto = false
    @State private var isConfirmingDelete = false
    @State private var isShowingTutorial = false
    @State private var isSendingFeedback = false
    @State private var permissions = DevicePermissions()
    @State private var toast: String?
    /// The data went but the login survived: the session is already over, once the alert is read.
    @State private var endsSessionAfterAlert = false
    @State private var deletedUserID: UUID?
    /// The photo just picked, drawn in the row while it uploads and after it lands.
    @State private var avatarPreview: UIImage?
    /// A write that did not happen, said once.
    @State private var failure: ActionFailure?
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.openURL) private var openURL
    @Environment(\.atePalette) private var palette

    var body: some View {
        List {
            Section {
                AteGroupedRow(title: "Photo", icon: .library, identifier: "settings.photo") {
                    isPickingPhoto = true
                } trailing: {
                    avatar
                }
                AteGroupedRow(
                    title: "Handle", icon: .atSign, value: model.displayHandle, identifier: "settings.handle"
                ) {
                    context.open(.settings(.handle(current: model.handle)))
                }
                // What is saved: "Vegan", "Gluten free, Nut free", "None" — nothing until it is known.
                AteGroupedRow(
                    title: "Diet", icon: .diet, value: context.app.diet.choice?.summary, identifier: "settings.diet"
                ) {
                    context.open(.settings(.diet))
                }
            }
            Section("This iPhone") {
                AteGroupedPicker(
                    title: "Appearance", icon: .moon, value: model.appearance.title,
                    selection: Bindable(model).appearance
                ) {
                    ForEach(AteAppearance.allCases, id: \.self) { appearance in
                        Text(appearance.title).tag(appearance)
                    }
                }
                .accessibilityIdentifier("settings.appearance")
                // What iOS allows right now; the Settings app is where it changes.
                ForEach(DevicePermission.allCases, id: \.self) { permission in
                    AteGroupedRow(
                        title: permission.title, icon: permission.icon,
                        value: permissions.state(of: permission).title, leavesApp: true,
                        identifier: "settings.permission.\(permission.rawValue)"
                    ) {
                        Task { await permissions.open(permission, services: context.services) }
                    }
                }
            }
            Section {
                AteGroupedRow(title: "Blocked people", icon: .block, identifier: "settings.blocked") {
                    context.open(.settings(.blocked))
                }
            }
            Section("Help") {
                AteGroupedRow(title: "Tutorial", icon: .circlePlay, identifier: "settings.tutorial") {
                    isShowingTutorial = true
                }
                AteGroupedRow(title: "Send feedback", icon: .messageCircle, identifier: "settings.feedback") {
                    isSendingFeedback = true
                }
                AteGroupedRow(title: "Email us", icon: .mail, leavesApp: true, identifier: "settings.email") {
                    emailUs()
                }
                #if DEBUG || BETA
                // The whole first run again, from Handle, and every tip after it. Testers only.
                AteGroupedRow(title: "Replay onboarding", icon: .rotateCcw, identifier: "settings.replayOnboarding") {
                    context.app.replayOnboarding()
                }
                #endif
            }
            Section("Legal") {
                AteGroupedRow(title: "Privacy policy", icon: .shield, identifier: "settings.privacy") {
                    context.open(.settings(.privacy))
                }
                AteGroupedRow(title: "Terms of use", icon: .fileText, identifier: "settings.terms") {
                    context.open(.settings(.terms))
                }
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
            } footer: {
                // The build, so a tester can quote it.
                Text(Self.version)
                    .ateText(.meta)
                    .foregroundStyle(palette.muted)
                    .frame(maxWidth: .infinity)
                    .padding(.top, AteMetrics.regular)
                    .accessibilityIdentifier("settings.version")
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
        } message: {
            Text("Your entries, photos, lists and tags are deleted. This can’t be undone.")
        }
        // The same sheet as the testers' bug on You, here in every build.
        .sheet(isPresented: $isSendingFeedback) {
            FeedbackSheet(app: context.app) { toast = "Report sent. Thank you." }
        }
        .ateToast($toast)
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
        .task { await context.app.loadDiet() }
        .task { await permissions.refresh() }
        // Back from the Settings app: the rows say what was changed there.
        .onChange(of: scenePhase) { _, phase in
            if phase == .active { Task { await permissions.refresh() } }
        }
        // What the server holds is everybody's: a new photo shows on You, your bylines, everywhere.
        .onChange(of: model.avatarURL) { _, url in
            guard let userID = model.userID else { return }
            AteAvatarDirectory.shared.note(userID, url: url)
        }
        // Back from the handle page: the row shows what the server now holds.
        .onAppear { Task { await model.reloadIfLoaded() } }
    }

    // MARK: - Help

    /// Mail, to the address the privacy policy names. No mail app: the address is copied instead.
    private func emailUs() {
        guard let url = URL(string: "mailto:\(LegalDocument.contactEmail)") else { return }
        openURL(url) { opened in
            if opened == false {
                UIPasteboard.general.string = LegalDocument.contactEmail
                toast = "Email address copied"
            }
            context.services.analytics(AccountEvents.supportEmailTapped(opened: opened))
        }
    }

    /// "Ate 1.0 (238)".
    private static var version: String {
        let info = Bundle.main.infoDictionary
        let short = info?["CFBundleShortVersionString"] as? String ?? ""
        let build = info?["CFBundleVersion"] as? String ?? ""
        return "Ate \(short) (\(build))"
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

private extension DevicePermission {
    /// The row's line icon.
    var icon: AteIcon {
        switch self {
        case .notifications: .bell
        case .photos: .photoStack
        case .location: .place
        case .camera: .camera
        }
    }
}
