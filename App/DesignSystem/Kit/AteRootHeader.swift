import SwiftUI

/// **A tab root's header** — the title leading and the root's glass group trailing, on ONE row: the
/// header wastes no space. The Journal's title is the wordmark (never typeset); Feed, Search and You
/// use their names; the Feed's city rides as the subtitle. No eyebrow text, no frost.
///
/// ``SwiftUICore/View/ateRootToolbar(title:subtitle:controls:)`` puts the same row into the native
/// navigation bar — the title as a leading item with no glass of its own, the controls as the
/// system's own trailing glass group — which is how a screen uses it. The view is the gallery's
/// stand-in for that bar and the title item's contents.
struct AteRootHeader<Controls: View>: View {
    let title: AteRootHeaderTitle
    var subtitle: String?
    @ViewBuilder var controls: Controls

    var body: some View {
        HStack(spacing: AteMetrics.snug) {
            AteRootTitle(title: title, subtitle: subtitle)
            Spacer(minLength: 0)
            AteGlassGroup { controls }
        }
        .padding(.leading, title == .wordmark ? AteRootHeaderMetrics.wordmarkLeading : AteMetrics.gutter)
        .padding(.trailing, AteRootHeaderMetrics.trailing)
        .frame(height: AteMetrics.hit)
    }
}

/// What a root is titled by: the Journal's wordmark, or a name.
enum AteRootHeaderTitle: Equatable {
    case wordmark
    case text(String)
}

/// The header's title: the wordmark, or the name with its subtitle beside it on the baseline.
struct AteRootTitle: View {
    let title: AteRootHeaderTitle
    var subtitle: String?

    @Environment(\.atePalette) private var palette

    var body: some View {
        switch title {
        case .wordmark:
            AteWordmark(height: AteRootHeaderMetrics.wordmark)
        case .text(let name):
            HStack(alignment: .firstTextBaseline, spacing: AteMetrics.snug) {
                Text(name)
                    .ateText(.kitRootTitle)
                    .foregroundStyle(palette.fg)
                    .lineLimit(1)
                    .accessibilityAddTraits(.isHeader)
                if let subtitle {
                    Text(subtitle)
                        .ateText(.kitRootSubtitle)
                        .foregroundStyle(palette.muted)
                        .lineLimit(1)
                }
            }
        }
    }
}

enum AteRootHeaderMetrics {
    /// `.wm{left:16px; height:32px}`; `.lt{left:20px}`; the group `right:16px`.
    static let wordmark: CGFloat = 32
    static let wordmarkLeading: CGFloat = 16
    static let trailing: CGFloat = 16
}

extension View {
    /// Installs a tab root's header in the **native** navigation bar: the title as a leading toolbar
    /// item with its shared glass hidden, and the controls as the system's trailing glass group.
    func ateRootToolbar<Controls: View>(
        title: AteRootHeaderTitle,
        subtitle: String? = nil,
        @ViewBuilder controls: () -> Controls
    ) -> some View {
        let controls = controls()
        return toolbar {
            ToolbarItem(placement: .topBarLeading) {
                AteRootTitle(title: title, subtitle: subtitle)
            }
            .sharedBackgroundVisibility(.hidden)
            ToolbarItemGroup(placement: .topBarTrailing) {
                controls
            }
        }
        .navigationBarTitleDisplayMode(.inline)
    }
}
