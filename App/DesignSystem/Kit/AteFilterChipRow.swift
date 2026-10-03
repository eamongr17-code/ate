import SwiftUI

/// **The filter chips** — only while a filter is on, in a row under the bar (`safeAreaInset(edge:
/// .top)`): each one an ink pill saying its value, with an ✕ that takes it off. No row at all when
/// nothing is on. The filters themselves live in the one filter sheet behind the root's filter icon.
struct AteFilterChipRow: View {
    struct Chip: Identifiable, Equatable {
        let id: String
        let title: String
    }

    let chips: [Chip]
    /// A tap on the chip's value — the filter sheet, opened.
    var onOpen: (() -> Void)?
    let onClear: (Chip) -> Void

    @Environment(\.atePalette) private var palette

    var body: some View {
        if chips.isEmpty == false {
            ScrollView(.horizontal) {
                HStack(spacing: AteFilterChipRowMetrics.spacing) {
                    ForEach(chips) { chip(for: $0) }
                }
                .padding(.horizontal, AteMetrics.listGutter)
            }
            .scrollIndicators(.hidden)
            .scrollClipDisabled()
        }
    }

    private func chip(for chip: Chip) -> some View {
        HStack(spacing: AteFilterChipRowMetrics.innerGap) {
            Button { onOpen?() } label: {
                Text(chip.title)
                    .ateText(.kitChip)
                    .lineLimit(1)
                    .padding(.leading, AteFilterChipRowMetrics.leading)
                    .frame(height: AteFilterChipRowMetrics.height)
                    .contentShape(.rect)
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier("chip.\(chip.id)")
            Button { onClear(chip) } label: {
                AteIcon.close.view(size: AteFilterChipRowMetrics.clear)
                    .opacity(AteKitColor.chipClearOpacity)
                    .padding(.trailing, AteFilterChipRowMetrics.trailing)
                    .frame(height: AteFilterChipRowMetrics.height)
                    .contentShape(.rect)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Clear \(chip.title)")
            .accessibilityIdentifier("chip.\(chip.id).clear")
        }
        .foregroundStyle(palette.inverted)
        .background(palette.solid, in: .capsule)
        .fixedSize()
    }
}

enum AteFilterChipRowMetrics {
    /// `.chip{height:34px; gap:6px; padding:0 10px 0 12px}`, its ✕ 14; `.chips{gap:8px}`.
    static let height: CGFloat = 34
    static let innerGap: CGFloat = 6
    static let leading: CGFloat = 12
    static let trailing: CGFloat = 10
    static let clear: CGFloat = 14
    static let spacing: CGFloat = 8
}
