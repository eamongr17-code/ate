import AteKit
import SwiftUI

/// **A row of the system's inset grouped list** — Settings and the pages it opens. The label leading
/// in the list face, after its line icon on Settings' own page (`settings-redesign.html` B, ink, no
/// tile); what is true on the right (a value, or a small view such as the avatar); the chevron where
/// the row goes somewhere, or the arrow where it leaves Ate (iOS Settings, Mail). A destructive row
/// is red and has neither. No line of explanation under anything (the build's rule for Settings).
///
/// The list itself is the system's: ``SwiftUICore/View/ateGroupedList()`` puts it on the linen ground.
struct AteGroupedRow<Trailing: View>: View {
    let title: String
    var icon: AteIcon?
    var isDestructive = false
    var showsChevron = true
    /// Opens outside Ate: the arrow instead of the chevron.
    var leavesApp = false
    /// Lit by another choice that covers it (Settings → Diet: Vegan covers Vegetarian): the name
    /// faded (`.gr.implied`), and not a button. The caller fades its own tick.
    var isCovered = false
    var identifier: String?
    let action: () -> Void
    @ViewBuilder var trailing: Trailing

    @Environment(\.atePalette) private var palette

    var body: some View {
        // A covered row answers nothing — not `.disabled`, which would dim it a second time.
        Button { if isCovered == false { action() } } label: {
            HStack(spacing: AteGroupedRowMetrics.gap) {
                AteGroupedRowLabel(title: title, icon: icon)
                    .foregroundStyle(isDestructive ? AteColor.destructive : palette.fg)
                    .opacity(isCovered ? AteKitColor.coveredRowOpacity : 1)
                Spacer(minLength: AteMetrics.snug)
                trailing
                if showsChevron, isDestructive == false {
                    (leavesApp ? AteIcon.arrowUpRight : AteIcon.chevron).view(size: AteMetrics.settingsChevron)
                        .foregroundStyle(palette.muted)
                }
            }
            .frame(minHeight: AteGroupedRowMetrics.height)
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .listRowInsets(AteGroupedRowMetrics.insets)
        .listRowBackground(palette.chip)
        .accessibilityIdentifier(identifier ?? "row.\(title)")
    }
}

extension AteGroupedRow where Trailing == AteGroupedRowValue {
    /// A row whose right side is a value — the handle, nothing at all.
    init(
        title: String,
        icon: AteIcon? = nil,
        value: String? = nil,
        isDestructive: Bool = false,
        showsChevron: Bool = true,
        leavesApp: Bool = false,
        identifier: String? = nil,
        action: @escaping () -> Void
    ) {
        self.title = title
        self.icon = icon
        self.isDestructive = isDestructive
        self.showsChevron = showsChevron
        self.leavesApp = leavesApp
        self.identifier = identifier
        self.action = action
        self.trailing = AteGroupedRowValue(value: value)
    }
}

/// A row's name, after its icon when it has one. The list's hairline starts under the name, not the
/// icon, as the system's own Settings draws it.
struct AteGroupedRowLabel: View {
    let title: String
    var icon: AteIcon?

    var body: some View {
        HStack(spacing: AteGroupedRowMetrics.iconGap) {
            if let icon {
                icon.view(size: AteGroupedRowMetrics.icon)
            }
            Text(title)
                .ateText(.kitListRow)
                .alignmentGuide(.listRowSeparatorLeading) { $0[.leading] }
        }
    }
}

/// A row's value: muted, on one line.
struct AteGroupedRowValue: View {
    let value: String?

    @Environment(\.atePalette) private var palette

    var body: some View {
        if let value {
            Text(value)
                .ateText(.kitListRow)
                .foregroundStyle(palette.muted)
                .lineLimit(1)
        }
    }
}

/// **A single choice in a row** — a native `Menu` (Appearance: System, Light, Dark) holding an inline
/// picker, so the choices keep the system's ticks. The row itself is drawn here rather than by a
/// `.menu` picker, whose value is set in the system font and cannot be given ours.
struct AteGroupedPicker<Value: Hashable, Options: View>: View {
    let title: String
    var icon: AteIcon?
    /// The chosen option's name, as the row shows it on the right.
    let value: String
    @Binding var selection: Value
    @ViewBuilder var options: Options

    @Environment(\.atePalette) private var palette

    var body: some View {
        Menu {
            Picker(title, selection: $selection) {
                options
            }
            .pickerStyle(.inline)
        } label: {
            HStack(spacing: AteGroupedRowMetrics.gap) {
                AteGroupedRowLabel(title: title, icon: icon)
                    .foregroundStyle(palette.fg)
                Spacer(minLength: AteMetrics.snug)
                AteGroupedRowValue(value: value)
                AteIcon.chevronsUpDown.view(size: AteMetrics.settingsChevron)
                    .foregroundStyle(palette.muted)
            }
            .frame(minHeight: AteGroupedRowMetrics.height)
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .accessibilityValue(value)
        .listRowInsets(AteGroupedRowMetrics.insets)
        .listRowBackground(palette.chip)
    }
}

extension View {
    /// The system's inset grouped list on the app's linen ground.
    func ateGroupedList() -> some View {
        listStyle(.insetGrouped)
            .scrollContentBackground(.hidden)
            .ateGround()
    }
}

enum AteGroupedRowMetrics {
    /// The current build's Settings row: 56 high, a 10pt gap. The row sets its own height, so the
    /// list's own vertical insets are taken out (they made a row about 74).
    static let height: CGFloat = AteMetrics.settingsRowHeight
    static let gap: CGFloat = AteMetrics.settingsRowGap
    static let insets = EdgeInsets(top: 0, leading: AteMetrics.gutter, bottom: 0, trailing: AteMetrics.gutter)
    /// A row's line icon (`settings-redesign.html` B: 22, 12 from the name).
    static let icon: CGFloat = AteMetrics.settingsIcon
    static let iconGap: CGFloat = AteMetrics.settingsIconGap
    /// A row's small picture — the Settings photo — at a byline avatar's size.
    static let avatar: CGFloat = AteMetrics.avatar
}
