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
        modifier(AvatarPicking(isPresented: isPresented, onFailure: onFailure, onPicked: onPicked))
    }
}

private struct AvatarPicking: ViewModifier {
    @Binding var isPresented: Bool
    let onFailure: () -> Void
    let onPicked: (Data) -> Void

    @State private var item: PhotosPickerItem?
    @State private var photo: PickedPhoto?

    func body(content: Content) -> some View {
        content
            .photosPicker(isPresented: $isPresented, selection: $item, matching: .images, photoLibrary: .shared())
            .onChange(of: item) { _, item in
                guard let item else { return }
                Task { await load(item) }
            }
            .fullScreenCover(item: $photo) { photo in
                AteAvatarCropper(image: photo.image) {
                    self.photo = nil
                } onDone: { square in
                    self.photo = nil
                    if let jpeg = AvatarImage.jpeg(from: photo.image, cropping: square) {
                        onPicked(jpeg)
                    } else {
                        onFailure()
                    }
                }
            }
    }

    private func load(_ item: PhotosPickerItem) async {
        defer { self.item = nil }
        guard let data = try? await item.loadTransferable(type: Data.self), let image = UIImage(data: data) else {
            onFailure()
            return
        }
        // The picker is still sliding away; a cover asked for before it has gone is never shown.
        try? await Task.sleep(for: AvatarPickingMetrics.pickerAway)
        photo = PickedPhoto(image: image)
    }
}

private struct PickedPhoto: Identifiable {
    let id = UUID()
    let image: UIImage
}

private enum AvatarPickingMetrics {
    static let pickerAway: Duration = .milliseconds(450)
}
