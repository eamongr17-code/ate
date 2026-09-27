import SwiftUI

/// **A settings row** — `Settings.dc.html`'s only repeating element, and design rule 3's "everything
/// else has no container": a hairline on top, 56 tall, the name on the left, an optional value and a
/// 15pt chevron on the right.
///
/// Its own component rather than a variant of ``AteListRow`` because the two are drawn differently
/// in the markup (56 on a 10pt gap here, 58 on 12 there, and a settings row never has a subtitle) —
/// and because everything that lists rows on top of Settings (Appearance, Blocked people) has to
/// look identical to the page it was pushed from, which is only true if there is one of these.
struct AteSettingsRow<Trailing: View>: View {
    let title: String
    /// The grey value on the right — `@eamon`, `System`. Absent draws nothing at all.
    var value: String?
    /// Destructive rows are lettered in `destructive` and carry no chevron: Delete account is the
    /// end of the page, not a way further into it.
    var isDestructive = false
    /// A row that only shows something has none. Present by default because eight of the nine do.
    var showsChevron = true
    @ViewBuilder var trailing: Trailing
    var action: (() -> Void)?

    @Environment(\.atePalette) private var palette

    var body: some View {
        Group {
            if let action {
                Button(action: action) { content }
                    .buttonStyle(.plain)
            } else {
                content
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("settings.\(title)")
    }

    private var content: some View {
        VStack(spacing: 0) {
            // Ruled at the TOP, the way the markup rules them: the first row is parted from the
            // title and the last one ends on the ground rather than on a line.
            AteHairline()
            HStack(spacing: AteMetrics.settingsRowGap) {
                Text(title)
                    .ateText(.rowTitle)
                    .foregroundStyle(isDestructive ? AteColor.destructive : palette.fg)
                    .frame(maxWidth: .infinity, alignment: .leading)
                if let value, value.isEmpty == false {
                    Text(value)
                        .ateText(.meta)
                        .foregroundStyle(palette.muted)
                        .lineLimit(1)
                }
                trailing
                if showsChevron {
                    AteIcon.chevron.view(size: AteMetrics.settingsChevron)
                        .foregroundStyle(palette.fg)
                }
            }
            .frame(minHeight: AteMetrics.settingsRowHeight)
            .contentShape(.rect)
        }
    }
}

extension AteSettingsRow where Trailing == EmptyView {
    init(
        title: String,
        value: String? = nil,
        isDestructive: Bool = false,
        showsChevron: Bool = true,
        action: (() -> Void)? = nil
    ) {
        self.init(
            title: title,
            value: value,
            isDestructive: isDestructive,
            showsChevron: showsChevron,
            trailing: { EmptyView() },
            action: action
        )
    }
}

#if DEBUG
private struct SettingsRowsPreview: View {
    var body: some View {
        VStack(spacing: 0) {
            AteSettingsRow(title: "Handle", value: "@eamon", action: {})
            AteSettingsRow(title: "Photo", action: {})
            AteSettingsRow(title: "Appearance", value: "System", action: {})
            AteSettingsRow(title: "Delete account", isDestructive: true, showsChevron: false, action: {})
        }
        .padding(.horizontal, AteMetrics.gutter)
        .frame(maxHeight: .infinity, alignment: .top)
        .ateGround()
    }
}

#Preview("Settings rows") { SettingsRowsPreview() }
#endif
