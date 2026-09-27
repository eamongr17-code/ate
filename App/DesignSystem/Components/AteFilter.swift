import SwiftUI

// MARK: - The control

/// **The filter control** — one chip-coloured disc with the filter mark, ink when anything is set.
/// It sits beside the control it narrows (the Journal | Saved segment, Search's scopes) and opens
/// ``AteFilterSheet``. The same control on every screen that filters (round 4, Eamon: "use the same
/// filter logic").
struct AteFilterButton: View {
    let isActive: Bool
    var identifier = "filter"
    let action: () -> Void

    @Environment(\.atePalette) private var palette

    var body: some View {
        Button(action: action) {
            AteIcon.filter.view(size: 20)
                .frame(width: AteMetrics.hit, height: AteMetrics.hit)
                .background(isActive ? palette.fg : palette.chip, in: .circle)
                .foregroundStyle(isActive ? palette.inverted : palette.fg)
                .contentShape(.circle)
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Filter")
        .accessibilityValue(isActive ? "On" : "Off")
        .accessibilityIdentifier(identifier)
    }
}

// MARK: - The pills

/// **A filter pill** — 36 tall. On the chip colour when it is a choice that is off; ink when it is
/// on. An active filter under the control carries a ✕ that takes it away.
struct AteFilterPill: View {
    let title: String
    var isOn = false
    var onRemove: (() -> Void)?

    @Environment(\.atePalette) private var palette

    static let height: CGFloat = 36

    var body: some View {
        HStack(spacing: 6) {
            Text(title)
                .ateText(.controlSmall)
                .lineLimit(1)
            if let onRemove {
                Button(action: onRemove) {
                    AteIcon.close.view(size: 12)
                        .frame(width: 24, height: 24)
                        .contentShape(.rect)
                }
                .buttonStyle(.plain)
                .padding(.trailing, -6)
                .accessibilityLabel("Remove \(title)")
            }
        }
        .padding(.leading, 14)
        .padding(.trailing, onRemove == nil ? 14 : 10)
        .frame(height: Self.height)
        .background(isOn ? palette.fg : palette.chip, in: .capsule)
        .foregroundStyle(isOn ? palette.inverted : palette.fg)
        .fixedSize()
    }
}

/// One active filter, as the row under the control shows it.
struct AteActiveFilter: Identifiable, Hashable {
    let id: String
    let title: String
}

/// **The active filters** — removable ink pills in a row that scrolls sideways, on the list gutter.
/// Nothing at all when nothing is on.
struct AteActiveFilters: View {
    let filters: [AteActiveFilter]
    var identifier = "filter.pill"
    let onRemove: (AteActiveFilter) -> Void

    var body: some View {
        if filters.isEmpty == false {
            ScrollView(.horizontal) {
                HStack(spacing: AteMetrics.snug) {
                    ForEach(filters) { filter in
                        AteFilterPill(title: filter.title, isOn: true) { onRemove(filter) }
                            .accessibilityIdentifier("\(identifier).\(filter.id)")
                    }
                }
                .padding(.horizontal, AteMetrics.listGutter)
            }
            .scrollIndicators(.hidden)
        }
    }
}

// MARK: - The sheet

/// **The filter sheet** — the app's own sheet (``AteSheet``) titled Filter, its sections, and one
/// ink Done. Nothing is applied until Done: the list behind it is read again once, not per tap. The
/// caller holds the draft and lays out its sections with ``AteFilterSection``, ``AteFilterChoice``
/// and ``AteSegments``; the sheet is the same wherever it opens.
struct AteFilterSheet<Content: View>: View {
    /// A section's options are still arriving: the sheet stands at full height (``AteSheet``).
    var isLoading = false
    @ViewBuilder var content: Content
    let onDone: () -> Void

    @Environment(\.dismiss) private var dismiss

    var body: some View {
        AteSheet(title: "Filter", primary: ("Done", {
            onDone()
            dismiss()
        }), isLoading: isLoading) {
            VStack(alignment: .leading, spacing: AteMetrics.section) {
                content
            }
            .padding(.top, AteMetrics.tight)
            .padding(.bottom, AteMetrics.loose)
        }
    }
}

/// One section of the sheet: a muted label, then its choices. Pills run in a row that scrolls
/// sideways; `scrolls: false` stacks the content (radio rows).
struct AteFilterSection<Content: View>: View {
    let title: String
    var scrolls = true
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(title)
                .ateText(.meta)
                .foregroundStyle(AtePalette.surface.muted)
                .padding(.bottom, AteMetrics.snug)
                .accessibilityAddTraits(.isHeader)
            if scrolls {
                ScrollView(.horizontal) {
                    HStack(spacing: AteMetrics.snug) { content }
                }
                .scrollIndicators(.hidden)
            } else {
                content
            }
        }
    }
}

/// A choice in a section: a pill that is on (ink) or off (the field colour, which reads on the
/// sheet's white where a chip would vanish).
struct AteFilterChoice: View {
    let title: String
    let isOn: Bool
    var accessibilityName: String?
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            AteFilterPill(title: title, isOn: isOn)
                .environment(\.atePalette, isOn ? .surface : Self.onSurface)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(accessibilityName ?? title)
        .accessibilityAddTraits(isOn ? [.isButton, .isSelected] : .isButton)
    }

    private static var onSurface: AtePalette {
        var palette = AtePalette.surface
        palette.chip = palette.field
        return palette
    }
}
