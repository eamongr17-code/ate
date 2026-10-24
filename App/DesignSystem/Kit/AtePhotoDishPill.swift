import SwiftUI

/// **Fix which dishes this photo is** — the faint pencil at the right of your own photo's caption
/// in the viewer (design/rebuild/own-photo-caption.html, A; Eamon, 24 Oct). The caption itself is
/// the one everybody sees (``AtePhotoDishCaption``); the pencil is a native menu of the entry's
/// dishes, a tick for each one in the photo, and "No dish", so a wrong pairing is one tap to fix.
/// Read-only (`onPick` nil, or no dishes to pick from) it is not drawn.
///
/// The receipt itself never captions its photos (Eamon, 13 Oct): the name shows only in the viewer.
struct AtePhotoDishPill: View {
    struct Dish: Identifiable, Hashable {
        let id: UUID
        let name: String
    }

    /// The dishes this photo is, in receipt order.
    let dishes: [Dish]
    /// The entry's dishes, in receipt order. Empty: not drawn.
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
                AteIcon.edit.view(size: AtePhotoDishPillMetrics.icon)
                    .opacity(AtePhotoDishPillMetrics.opacity)
                    .frame(width: AteMetrics.hit, height: AteMetrics.hit)
                    .contentShape(.rect)
            }
            .menuActionDismissBehavior(.disabled)
            .menuStyle(.button)
            .buttonStyle(.plain)
            .foregroundStyle(AteColor.overPhoto)
            .accessibilityLabel("Change dish")
            .accessibilityValue(title)
            .accessibilityIdentifier("photo.dish.edit")
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
}

enum AtePhotoDishPillMetrics {
    static let icon: CGFloat = 17
    /// Faint: there to find, never the first thing you read.
    static let opacity: Double = 0.6
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
    }
    .padding()
    .background(AteColor.viewerGround)
}
#endif
