import SwiftUI

/// **Which dish this photo is** — the glass pill under a photo in the viewer
/// (design/rebuild/date-and-photos.html, "Fix a match"). It names the dish the photo was paired with;
/// on your own entry it is a native menu of the entry's dishes and "No dish", so a wrong pairing is
/// one tap to fix. On anybody else's it only names, and with no dish it is not drawn.
///
/// The receipt itself never captions its photos (Eamon, 13 Oct): the name shows only here.
struct AtePhotoDishPill: View {
    struct Dish: Identifiable, Hashable {
        let id: UUID
        let name: String
    }

    /// The dish this photo is, if any.
    let dish: Dish?
    /// The entry's dishes, in receipt order. Empty: names only, never a menu.
    var choices: [Dish] = []
    /// `nil` is read-only.
    var onPick: ((Dish?) -> Void)?

    var body: some View {
        if let onPick, choices.isEmpty == false {
            Menu {
                // A picker in a menu: the system draws the check on the dish it is now.
                Picker("Dish", selection: Binding(
                    get: { dish?.id },
                    set: { id in onPick(choices.first { $0.id == id }) }
                )) {
                    ForEach(choices) { choice in
                        Text(choice.name).tag(Optional(choice.id))
                    }
                    Text("No dish").tag(UUID?.none)
                }
                .pickerStyle(.inline)
            } label: {
                face(showsChevron: true)
            }
            .menuStyle(.button)
            .buttonStyle(.plain)
            .accessibilityLabel("Dish: \(dish?.name ?? "No dish")")
            .accessibilityIdentifier("photo.dish")
        } else if let dish {
            face(showsChevron: false)
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(dish.name)
                .accessibilityIdentifier("photo.dish")
        }
    }

    private func face(showsChevron: Bool) -> some View {
        HStack(spacing: AtePhotoDishPillMetrics.gap) {
            AteIcon.dish.view(size: AtePhotoDishPillMetrics.icon)
            Text(dish?.name ?? "No dish")
                .ateText(.kitInkPill)
                .lineLimit(1)
                .truncationMode(.tail)
            if showsChevron {
                AteIcon.chevronsUpDown.view(size: AtePhotoDishPillMetrics.chevron)
                    .opacity(AtePhotoDishPillMetrics.chevronOpacity)
            }
        }
        .foregroundStyle(AteColor.overPhoto)
        .padding(.horizontal, AtePhotoDishPillMetrics.padding)
        .frame(height: AteMetrics.hit)
        .glassEffect(.regular.interactive(), in: .capsule)
        .contentShape(.capsule)
    }
}

enum AtePhotoDishPillMetrics {
    static let gap: CGFloat = 6
    static let icon: CGFloat = 16
    static let chevron: CGFloat = 14
    static let chevronOpacity: Double = 0.7
    static let padding: CGFloat = 16
    /// Above the page dots and the home indicator.
    static let bottom: CGFloat = 44
}

#if DEBUG
#Preview("Photo dish pill") {
    let dishes = [
        AtePhotoDishPill.Dish(id: UUID(), name: "Tagliatelle al ragù"),
        AtePhotoDishPill.Dish(id: UUID(), name: "Tiramisu")
    ]
    VStack(spacing: 24) {
        AtePhotoDishPill(dish: dishes[1], choices: dishes, onPick: { _ in })
        AtePhotoDishPill(dish: nil, choices: dishes, onPick: { _ in })
        AtePhotoDishPill(dish: dishes[0])
    }
    .padding()
    .background(AteColor.viewerGround)
}
#endif
