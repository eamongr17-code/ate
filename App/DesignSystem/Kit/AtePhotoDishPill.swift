import SwiftUI

/// **Which dishes this photo is** — the glass pill under a photo in the viewer
/// (design/rebuild/date-and-photos.html, "Fix a match"; photo-dish-tags.html, 6). It names the dish
/// the photo was paired with, or counts them when it shows several; on your own entry it is a
/// native menu of the entry's dishes, a tick for each one in the photo, and "No dish", so a wrong
/// pairing is one tap to fix. On anybody else's it only names, and with no dish it is not drawn.
///
/// The receipt itself never captions its photos (Eamon, 13 Oct): the name shows only here.
struct AtePhotoDishPill: View {
    struct Dish: Identifiable, Hashable {
        let id: UUID
        let name: String
    }

    /// The dishes this photo is, in receipt order.
    let dishes: [Dish]
    /// The entry's dishes, in receipt order. Empty: names only, never a menu.
    var choices: [Dish] = []
    /// Every dish now ticked, in receipt order; empty is No dish. `nil` is read-only.
    var onPick: (([Dish]) -> Void)?

    var body: some View {
        if let onPick, choices.isEmpty == false {
            Menu {
                // A toggle per dish: the system draws the tick, and the menu stays up so a photo of
                // two dishes is two taps (0083).
                ForEach(choices) { choice in
                    Toggle(choice.name, isOn: Binding(
                        get: { dishes.contains(choice) },
                        set: { on in onPick(Self.ticked(choice, on: on, in: dishes, choices: choices)) }
                    ))
                }
                Divider()
                Toggle("No dish", isOn: Binding(
                    get: { dishes.isEmpty },
                    set: { on in if on { onPick([]) } }
                ))
            } label: {
                face(showsChevron: true)
            }
            .menuActionDismissBehavior(.disabled)
            .menuStyle(.button)
            .buttonStyle(.plain)
            .accessibilityLabel("Dish: \(title)")
            .accessibilityIdentifier("photo.dish")
        } else if dishes.isEmpty == false {
            face(showsChevron: false)
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(dishes.map(\.name).joined(separator: ", "))
                .accessibilityIdentifier("photo.dish")
        }
    }

    /// One dish by name; several by count ("2 dishes"); none is No dish.
    private var title: String {
        switch dishes.count {
        case 0: "No dish"
        case 1: dishes[0].name
        default: "\(dishes.count) dishes"
        }
    }

    /// The ticks after one changes, kept in receipt order.
    static func ticked(_ choice: Dish, on: Bool, in dishes: [Dish], choices: [Dish]) -> [Dish] {
        let ids = Set(dishes.map(\.id)).symmetricDifference(dishes.contains(choice) == on ? [] : [choice.id])
        return choices.filter { ids.contains($0.id) }
    }

    private func face(showsChevron: Bool) -> some View {
        HStack(spacing: AtePhotoDishPillMetrics.gap) {
            AteIcon.dish.view(size: AtePhotoDishPillMetrics.icon)
            Text(title)
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
        AtePhotoDishPill(dishes: [dishes[1]], choices: dishes, onPick: { _ in })
        AtePhotoDishPill(dishes: dishes, choices: dishes, onPick: { _ in })
        AtePhotoDishPill(dishes: [], choices: dishes, onPick: { _ in })
        AtePhotoDishPill(dishes: [dishes[0]])
    }
    .padding()
    .background(AteColor.viewerGround)
}
#endif
