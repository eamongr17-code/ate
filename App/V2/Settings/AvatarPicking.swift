import PhotosUI
import SwiftUI

extension View {
    /// **Choosing your photo**, the same from Settings and from first run: Apple's picker, then the
    /// photo in its circle (``AteAvatarCropper``). `onPicked` gets the JPEG to upload only once the
    /// tick is pressed; the close changes nothing.
    func ateAvatarPicker(
        isPresented: Binding<Bool>,
        onFailure: @escaping () -> Void,
        onPicked: @escaping (Data) -> Void
    ) -> some View {
        modifier(AvatarPicking(isPresented: isPresented, frame: .circle, onFailure: onFailure, onPicked: onPicked))
    }

    /// **A list's cover from Photos** — the same picker and crop, squared to the cover's shape.
    func ateCoverPicker(
        isPresented: Binding<Bool>,
        onFailure: @escaping () -> Void,
        onPicked: @escaping (Data) -> Void
    ) -> some View {
        modifier(AvatarPicking(isPresented: isPresented, frame: .cover, onFailure: onFailure, onPicked: onPicked))
    }
}

/// Apple's picker is embedded in a sheet of our own rather than presented with `.photosPicker`:
/// the system one closes itself the moment a photo is tapped, which dropped the person back on the
/// page underneath until the crop could follow it up (~2s). Here the picker stays put and the crop
/// covers it on the tap, drawing the photo in as soon as it has loaded.
private struct AvatarPicking: ViewModifier {
    @Binding var isPresented: Bool
    let frame: AteAvatarCropper.Frame
    let onFailure: () -> Void
    let onPicked: (Data) -> Void

    /// A failure is said once the sheet has gone: an alert asked for while it closes is never shown.
    @State private var failed = false

    private func sayFailure() {
        guard failed else { return }
        failed = false
        onFailure()
    }

    func body(content: Content) -> some View {
        content
            .sheet(isPresented: $isPresented, onDismiss: sayFailure) {
                AvatarPickerSheet(frame: frame) {
                    isPresented = false
                } onFailure: {
                    failed = true
                    isPresented = false
                } onPicked: { jpeg in
                    isPresented = false
                    onPicked(jpeg)
                }
            }
    }
}

private struct AvatarPickerSheet: View {
    let frame: AteAvatarCropper.Frame
    let onClose: () -> Void
    let onFailure: () -> Void
    let onPicked: (Data) -> Void

    @State private var item: PhotosPickerItem?
    @State private var crop: Cropping?

    var body: some View {
        PhotosPicker(
            selection: $item,
            matching: .images,
            // The library's own bytes: asking for `.compatible` re-encodes every HEIC first.
            preferredItemEncoding: .current,
            photoLibrary: .shared()
        ) {
            EmptyView()
        }
        .photosPickerStyle(.inline)
        .photosPickerDisabledCapabilities(.selectionActions)
        .ignoresSafeArea(edges: .bottom)
        .overlay(alignment: .topLeading) {
            AteGlassDisc(icon: .close, label: "Close", identifier: "avatarPicker.close", action: onClose)
                .padding(.leading, AteMetrics.gutter)
                .padding(.top, AteMetrics.snug)
        }
        .onChange(of: item) { _, picked in
            guard let picked else { return }
            let cropping = Cropping()
            crop = cropping
            Task { await load(picked, into: cropping) }
        }
        .fullScreenCover(item: $crop) { cropping in
            CropStage(cropping: cropping, frame: frame) {
                crop = nil
            } onDone: { image, square in
                let pixels = frame == .cover ? AvatarImage.coverPixels : AvatarImage.pixels
                if let jpeg = AvatarImage.jpeg(from: image, cropping: square, pixels: pixels) {
                    onPicked(jpeg)
                } else {
                    onFailure()
                }
            }
        }
    }

    private func load(_ picked: PhotosPickerItem, into cropping: Cropping) async {
        defer { item = nil }
        let image: UIImage?
        if let data = try? await picked.loadTransferable(type: Data.self) {
            image = await Task.detached(priority: .userInitiated) { AvatarImage.decoded(data) }.value
        } else {
            image = nil
        }
        guard crop?.id == cropping.id else { return }
        if let image {
            cropping.image = image
        } else {
            crop = nil
            onFailure()
        }
    }
}

/// One tap's crop: up before the photo is, so nothing waits on the load to cover the picker.
@Observable
private final class Cropping: Identifiable {
    let id = UUID()
    var image: UIImage?
}

private struct CropStage: View {
    let cropping: Cropping
    let frame: AteAvatarCropper.Frame
    let onCancel: () -> Void
    let onDone: (UIImage, CGRect) -> Void

    var body: some View {
        if let image = cropping.image {
            AteAvatarCropper(image: image, frame: frame, onCancel: onCancel, onDone: { onDone(image, $0) })
        } else {
            // The cropper's own ground and close, while the photo arrives.
            AteColor.viewerGround
                .ignoresSafeArea()
                .overlay { ProgressView().tint(.white) }
                .overlay(alignment: .top) {
                    HStack {
                        AteGlassDisc(icon: .close, label: "Close", identifier: "avatarCrop.close", action: onCancel)
                        Spacer()
                    }
                    .padding(.horizontal, AteMetrics.gutter)
                    .padding(.top, AteMetrics.snug)
                }
                .environment(\.colorScheme, .dark)
        }
    }
}
