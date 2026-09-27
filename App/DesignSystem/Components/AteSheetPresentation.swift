import AteKit
import SwiftUI

// MARK: - Presenting a sheet once its rows are in hand

extension View {
    /// **A sheet that rises full, not blank** (round 5). Where `.sheet(isPresented:)` puts the sheet
    /// up at once, this runs `prepare` — the sheet's first read — and presents when it answers, or
    /// after ``SheetReadiness/limit`` if it has not. A sheet that goes up before its rows (the slow
    /// case) is drawn at full height with still rows (``AteSheet``'s `isLoading`), so either way it
    /// never jumps. The read is usually already in hand: its owner reads it ahead.
    ///
    /// `name` is the `sheet` parameter of `sheet_opened`.
    func ateSheet<Sheet: View>(
        isPresented: Binding<Bool>,
        name: String,
        prepare: @escaping @MainActor () async -> Void,
        @ViewBuilder content: @escaping () -> Sheet
    ) -> some View {
        modifier(AtePreparedSheet(isPresented: isPresented, name: name, prepare: prepare, sheet: content))
    }

    /// The same, for a sheet about one thing — `prepare` is handed the thing.
    func ateSheet<Item: Identifiable, Sheet: View>(
        item: Binding<Item?>,
        name: String,
        prepare: @escaping @MainActor (Item) async -> Void,
        @ViewBuilder content: @escaping (Item) -> Sheet
    ) -> some View {
        modifier(AtePreparedItemSheet(item: item, name: name, prepare: prepare, sheet: content))
    }
}

private struct AtePreparedSheet<Sheet: View>: ViewModifier {
    @Binding var isPresented: Bool
    let name: String
    let prepare: @MainActor () async -> Void
    let sheet: () -> Sheet

    /// What the system is actually showing. Trails `isPresented` by the read.
    @State private var isShowing = false
    @State private var preparing: Task<Void, Never>?

    func body(content: Content) -> some View {
        content
            .sheet(isPresented: Binding(
                get: { isShowing },
                set: { shown in
                    isShowing = shown
                    if shown == false { isPresented = false }
                }
            ), content: sheet)
            .onChange(of: isPresented, initial: true) { _, wanted in
                if wanted {
                    begin()
                } else {
                    preparing?.cancel()
                    preparing = nil
                    isShowing = false
                }
            }
    }

    private func begin() {
        guard isShowing == false, preparing == nil else { return }
        let name = name
        preparing = Task {
            let ready = await SheetReadiness.wait(for: prepare)
            preparing = nil
            guard Task.isCancelled == false, isPresented else { return }
            AteTelemetry.record(LinkEvents.sheetOpened(name, ready: ready))
            isShowing = true
        }
    }
}

private struct AtePreparedItemSheet<Item: Identifiable, Sheet: View>: ViewModifier {
    @Binding var item: Item?
    let name: String
    let prepare: @MainActor (Item) async -> Void
    let sheet: (Item) -> Sheet

    @State private var showing: Item?
    @State private var preparing: Task<Void, Never>?

    func body(content: Content) -> some View {
        content
            .sheet(item: Binding(
                get: { showing },
                set: { next in
                    showing = next
                    if next == nil { item = nil }
                }
            ), content: sheet)
            .onChange(of: item?.id, initial: true) { _, id in
                preparing?.cancel()
                preparing = nil
                guard let wanted = item, id != nil else {
                    showing = nil
                    return
                }
                guard showing?.id != wanted.id else { return }
                let name = name
                preparing = Task {
                    let ready = await SheetReadiness.wait { await prepare(wanted) }
                    preparing = nil
                    guard Task.isCancelled == false, item?.id == wanted.id else { return }
                    AteTelemetry.record(LinkEvents.sheetOpened(name, ready: ready))
                    showing = wanted
                }
            }
    }
}

// MARK: - What a prepared sheet shows

/// What a prepared sheet opens on, made by its `prepare` and read by its content — by reference, so
/// the sheet sees it the moment it is made rather than through a copy of its presenter captured
/// before (a sheet that rose on a stale copy drew nothing at all).
@MainActor
@Observable
final class AteSheetHolder<Value: AnyObject> {
    var value: Value?
}

/// Draws a prepared sheet's content once its holder has a value.
struct AteSheetHolderView<Value: AnyObject, Content: View>: View {
    let holder: AteSheetHolder<Value>
    @ViewBuilder let content: (Value) -> Content

    var body: some View {
        if let value = holder.value {
            content(value)
        }
    }
}

// MARK: - Still rows

/// **Rows that have not arrived**, drawn still in a sheet that went up before them: a radio row's
/// shape — the hairline over it, a title bar and a shorter subtitle bar — `count` times.
struct AteSheetSkeletonRows: View {
    var count = 5
    var hasSubtitle = true

    @Environment(\.atePalette) private var palette

    /// Title widths, so the column does not read as a ruled grid.
    private static let widths: [CGFloat] = [148, 112, 176, 96, 132, 160, 120]

    var body: some View {
        VStack(spacing: 0) {
            ForEach(0..<count, id: \.self) { index in
                VStack(spacing: 0) {
                    AteHairline()
                    HStack(spacing: AteMetrics.regular) {
                        VStack(alignment: .leading, spacing: AteMetrics.snug - 2) {
                            AteSkeletonBar(width: Self.widths[index % Self.widths.count], height: 12, palette: palette)
                            if hasSubtitle {
                                AteSkeletonBar(width: 64, height: 9, palette: palette)
                            }
                        }
                        Spacer(minLength: 0)
                    }
                    .frame(minHeight: AteMetrics.rowHeight)
                }
            }
        }
        .accessibilityHidden(true)
    }
}
