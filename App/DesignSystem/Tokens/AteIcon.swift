import SwiftUI

/// **Every icon in the app, named once.**
///
/// Design rule 1 is "icons before labels", which makes the icon set load-bearing — so it goes through
/// one enum rather than being spelled at call sites. Today each one resolves to the closest SF Symbol
/// (native, weight-matched, free Dynamic Type and VoiceOver); if the brand later wants the
/// prototype's own 1.8pt line drawings, they land in this file and nowhere else.
enum AteIcon: String {
    // Tabs
    case journal = "text.page"
    case feed = "person.2"
    case search = "magnifyingglass"
    case you = "person"
    case compose = "plus"

    // The atoms
    case star = "star"
    case starFilled = "star.fill"
    case place = "mappin"
    case photoStack = "photo.stack"

    // Visibility
    case publicEntry = "globe"
    case privateEntry = "lock"

    // Actions
    case share = "square.and.arrow.up"
    case edit = "pencil"
    case save = "bookmark"
    case saved = "bookmark.fill"
    case camera = "camera"
    case library = "photo.on.rectangle"
    case voice = "mic"
    case close = "xmark"
    case back = "chevron.left"
    case more = "ellipsis"

    var image: Image { Image(systemName: rawValue) }
}

extension AteIcon {
    /// An icon at a size, in the current foreground colour. Icons are stroked to match the display
    /// voice's weight rather than left at the system default.
    func view(size: CGFloat, weight: Font.Weight = .medium) -> some View {
        image
            .font(.system(size: size, weight: weight))
            .accessibilityHidden(true)
    }
}

/// A 44pt tappable icon — the app's standard toolbar/bar-button unit (design: 44pt minimum targets).
struct AteIconButton: View {
    let icon: AteIcon
    let label: String
    var size: CGFloat = 22
    var tint: Color?
    let action: () -> Void

    @Environment(\.atePalette) private var palette

    var body: some View {
        Button(action: action) {
            icon.view(size: size)
                .frame(width: AteMetrics.hit, height: AteMetrics.hit)
                .contentShape(.rect)
        }
        .foregroundStyle(tint ?? palette.fg)
        .accessibilityLabel(label)
    }
}
