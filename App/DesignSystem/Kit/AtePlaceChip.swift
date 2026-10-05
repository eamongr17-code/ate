import SwiftUI

/// **A nearby place, offered** — the pill under a photo sitting (`lists-notifications.html` E3,
/// `.pc`): the map pin and the place's name on the field colour. A tap attaches that place; nothing
/// is attached without one. Up to three sit in a row (``AtePlaceChipRow``).
///
/// `.pc{height:34px; gap:5px; padding:0 13px 0 10px; radius:999; background:var(--fld); 600 14px/1}`,
/// its pin 14. `.pc.on` is the ink pill.
struct AtePlaceChip: View {
    let name: String
    var isOn = false
    var identifier = "place.chip"
    let action: () -> Void

    @Environment(\.atePalette) private var palette

    var body: some View {
        Button(action: action) {
            HStack(spacing: AtePlaceChipMetrics.gap) {
                AteIcon.place.view(size: AtePlaceChipMetrics.pin)
                Text(name)
                    .ateText(.kitChip)
                    .lineLimit(1)
            }
            .padding(.leading, AtePlaceChipMetrics.leading)
            .padding(.trailing, AtePlaceChipMetrics.trailing)
            .frame(height: AtePlaceChipMetrics.height)
            .foregroundStyle(isOn ? palette.inverted : palette.fg)
            .background(isOn ? palette.solid : palette.field, in: .capsule)
            // A 44 target around the 34 pill.
            .padding(.vertical, AtePlaceChipMetrics.hitOutset)
            .contentShape(.rect)
            .padding(.vertical, -AtePlaceChipMetrics.hitOutset)
        }
        .buttonStyle(.plain)
        .fixedSize()
        .accessibilityLabel(name)
        .accessibilityAddTraits(isOn ? [.isButton, .isSelected] : .isButton)
        .accessibilityIdentifier(identifier)
    }
}

/// The chips in one row (`.pchips{display:flex; gap:8px; overflow:hidden}`): what does not fit is
/// clipped at the trailing edge, as the artboard's row is, never wrapped.
struct AtePlaceChipRow<Content: View>: View {
    @ViewBuilder var content: Content

    var body: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: AtePlaceChipMetrics.spacing) { content }
            ScrollView(.horizontal) {
                HStack(spacing: AtePlaceChipMetrics.spacing) { content }
            }
            .scrollIndicators(.hidden)
            .scrollClipDisabled()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

enum AtePlaceChipMetrics {
    static let height: CGFloat = 34
    static let gap: CGFloat = 5
    static let leading: CGFloat = 10
    static let trailing: CGFloat = 13
    static let pin: CGFloat = 14
    static let spacing: CGFloat = 8
    static let hitOutset: CGFloat = (AteMetrics.hit - height) / 2
}
