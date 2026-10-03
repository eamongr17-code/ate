import AteKit
import SwiftUI

/// **A row of the system's inset grouped list** — Settings and the pages it opens. The label leading
/// in the list face; what is true on the right (a value, or a small view such as the avatar); the
/// chevron where the row goes somewhere. A destructive row is red and has no chevron. No icons and
/// no line of explanation under anything (the build's rule for Settings).
///
/// The list itself is the system's: ``SwiftUICore/View/ateGroupedList()`` puts it on the linen ground.
struct AteListRow<Trailing: View>: View {
    let title: String
    var isDestructive = false
    var showsChevron = true
    var identifier: String?
    let action: () -> Void
    @ViewBuilder var trailing: Trailing

    @Environment(\.atePalette) private var palette

    var body: some View {
        Button(action: action) {
            HStack(spacing: AteListRowMetrics.gap) {
                Text(title)
                    .ateText(.kitListRow)
                    .foregroundStyle(isDestructive ? AteColor.destructive : palette.fg)
                Spacer(minLength: AteMetrics.snug)
                trailing
                if showsChevron, isDestructive == false {
                    AteIcon.chevron.view(size: AteMetrics.settingsChevron)
                        .foregroundStyle(palette.muted)
                }
            }
            .frame(minHeight: AteListRowMetrics.height)
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .listRowBackground(palette.chip)
        .accessibilityIdentifier(identifier ?? "row.\(title)")
    }
}

extension AteListRow where Trailing == AteListRowValue {
    /// A row whose right side is a value — the handle, nothing at all.
    init(
        title: String,
        value: String? = nil,
        isDestructive: Bool = false,
        showsChevron: Bool = true,
        identifier: String? = nil,
        action: @escaping () -> Void
    ) {
        self.title = title
        self.isDestructive = isDestructive
        self.showsChevron = showsChevron
        self.identifier = identifier
        self.action = action
        self.trailing = AteListRowValue(value: value)
    }
}

/// A row's value: muted, on one line.
struct AteListRowValue: View {
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

/// **A single choice in a row** — a native `Menu` picker (Appearance: System, Light, Dark), its label
/// leading and the system's own value and chevrons trailing.
struct AteListPicker<Value: Hashable, Options: View>: View {
    let title: String
    @Binding var selection: Value
    @ViewBuilder var options: Options

    @Environment(\.atePalette) private var palette

    var body: some View {
        Picker(selection: $selection) {
            options
        } label: {
            Text(title)
                .ateText(.kitListRow)
                .foregroundStyle(palette.fg)
        }
        .pickerStyle(.menu)
        .tint(palette.muted)
        .frame(minHeight: AteListRowMetrics.height)
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

enum AteListRowMetrics {
    static let height: CGFloat = 44
    static let gap: CGFloat = AteMetrics.regular
    /// A row's small picture — the Settings photo — at a byline avatar's size.
    static let avatar: CGFloat = AteMetrics.avatar
}
