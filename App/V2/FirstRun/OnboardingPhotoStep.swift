import AteKit
import PhotosUI
import SwiftUI

/// **"Add a photo of you."** (`design/rebuild/onboarding-v2.html`, steps 2 and 2b) — straight after
/// Handle. The avatar as it will be drawn everywhere, the monogram until there is a photo, with a
/// camera disc on its edge. Choose a photo opens Apple's picker (no permission asked); the photo
/// uploads the way Settings → Photo does, and the ink tick top right goes on. Not now keeps the
/// monogram.
struct OnboardingPhotoStep: View {
    let app: AppModel
    /// The tick (a photo is on file) or Not now.
    let onDone: (OnboardingEvents.Photo) -> Void

    @State private var account: SettingsModel
    @State private var item: PhotosPickerItem?
    @State private var isPicking = false
    /// The photo just picked, drawn in the circle while it uploads and after it lands.
    @State private var picked: UIImage?
    @State private var failure: ActionFailure?
    @Environment(\.atePalette) private var palette

    init(app: AppModel, onDone: @escaping (OnboardingEvents.Photo) -> Void) {
        self.app = app
        self.onDone = onDone
        _account = State(initialValue: SettingsModel(
            account: app.services.account,
            preferences: app.services.preferences,
            analytics: app.services.analytics
        ))
    }

    var body: some View {
        VStack(spacing: 0) {
            Spacer(minLength: AteMetrics.section)
            Button { isPicking = true } label: { avatar }
                .buttonStyle(.plain)
                .accessibilityLabel(OnboardingCopy.choosePhoto)
                .accessibilityIdentifier("onboarding.photo.avatar")
            AteTitle(text: OnboardingCopy.photo, style: .handleTitle)
                .padding(.horizontal, OnboardingMetrics.titleInset)
                .padding(.top, OnboardingMetrics.avatarToTitle)
            Spacer(minLength: AteMetrics.section)
            doors
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .accessibilityIdentifier("v2.onboarding.photo")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            if picked != nil {
                ToolbarItem(placement: .confirmationAction) {
                    AteGlassDisc(
                        icon: .check,
                        label: "Done",
                        role: .primary,
                        isEnabled: account.isUploadingAvatar == false,
                        isBusy: account.isUploadingAvatar,
                        identifier: "onboarding.photo.done"
                    ) {
                        onDone(.picked)
                    }
                }
                .sharedBackgroundVisibility(.hidden)
            }
        }
        .photosPicker(isPresented: $isPicking, selection: $item, matching: .images, photoLibrary: .shared())
        .onChange(of: item) { _, item in
            guard let item else { return }
            Task { await upload(item) }
        }
        .ateFailureAlert($failure)
    }

    @ViewBuilder
    private var avatar: some View {
        if let picked {
            Image(uiImage: picked)
                .resizable()
                .scaledToFill()
                .frame(width: OnboardingMetrics.avatar, height: OnboardingMetrics.avatar)
                .clipShape(.circle)
                .opacity(account.isUploadingAvatar ? AteKitColor.disabledOpacity : 1)
        } else {
            monogram
                .overlay(alignment: .bottomTrailing) {
                    AteIconView(icon: .camera, size: OnboardingMetrics.badgeIcon)
                        .foregroundStyle(palette.inverted)
                        .frame(width: AteMetrics.hit, height: AteMetrics.hit)
                        .background(palette.solid, in: .circle)
                        .padding(OnboardingMetrics.badgeRing)
                        .background(palette.ground, in: .circle)
                        .offset(x: -OnboardingMetrics.badgeInset, y: -OnboardingMetrics.badgeInset)
                }
        }
    }

    /// The person's letter on their accent, as every byline draws it — the same component, larger.
    @ViewBuilder
    private var monogram: some View {
        if let userID = app.services.api.currentUserID {
            AteAvatar(
                userID: userID,
                handle: app.handle ?? "",
                side: OnboardingMetrics.avatar,
                textStyle: .onboardingMonogram
            )
        } else {
            Circle().fill(palette.field)
                .frame(width: OnboardingMetrics.avatar, height: OnboardingMetrics.avatar)
        }
    }

    private var doors: some View {
        VStack(spacing: AteWelcomeCardMetrics.doorsGap) {
            if picked == nil {
                AteInkPill(title: OnboardingCopy.choosePhoto, identifier: "onboarding.photo.choose") {
                    isPicking = true
                }
                AteWelcomeLink(
                    title: OnboardingCopy.notNow, colour: palette.fg, identifier: "onboarding.photo.notNow"
                ) {
                    onDone(.skipped)
                }
            } else {
                AteWelcomeLink(
                    title: OnboardingCopy.chooseAnother, colour: palette.fg, identifier: "onboarding.photo.another"
                ) {
                    isPicking = true
                }
            }
        }
        .padding(.horizontal, AteMetrics.gutter)
        .ateContentBottom(AteWelcomeCardMetrics.doorsBottom)
    }

    /// Drawn down and sent exactly as Settings → Photo sends it. A failure puts the circle back and
    /// says so once.
    private func upload(_ item: PhotosPickerItem) async {
        defer { self.item = nil }
        guard let data = try? await item.loadTransferable(type: Data.self),
              let image = UIImage(data: data),
              let jpeg = AvatarImage.jpeg(from: image) else {
            failure = .avatar
            return
        }
        let previous = picked
        picked = UIImage(data: jpeg) ?? image
        await account.setAvatar(AvatarUpload(data: jpeg))
        if account.didFail {
            picked = previous
            account.acknowledgeFailure()
            failure = .avatar
        }
    }
}

extension AteTextStyle {
    /// The letter in first run's 176pt avatar: the profile monogram's proportion (34 in 76).
    static let onboardingMonogram = AteTextStyle(
        voice: .display, size: 80, weight: 800, trackingEm: 0, lineHeight: 1.0,
        textStyle: .largeTitle, maximumSize: 80
    )
}
