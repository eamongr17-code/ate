import AteKit
import SwiftUI

/// **When you ate it** (design/rebuild/date-and-photos.html): the native calendar in a sheet fitted
/// to it, close top left and the tick top right. Future days are not offered. Date only: the time
/// of day stays whatever the entry already had.
struct ComposerDateSheet: View {
    let initial: Date
    let onPick: (Date) -> Void

    @State private var day: Date
    @Environment(\.dismiss) private var dismiss

    init(initial: Date, onPick: @escaping (Date) -> Void) {
        self.initial = initial
        self.onPick = onPick
        _day = State(initialValue: min(initial, Date()))
    }

    var body: some View {
        AteSheetScaffold(
            title: nil,
            primary: AteSheetPrimary(icon: .check, label: "Done") {
                onPick(day)
                dismiss()
            }
        ) {
            DatePicker("Date", selection: $day, in: ...Date(), displayedComponents: .date)
                .datePickerStyle(.graphical)
                .labelsHidden()
                .tint(AteColor.coral)
                .accessibilityIdentifier("composer.date.calendar")
        }
    }
}

extension View {
    /// The composer's date sheet.
    func v2DateSheet(isPresented: Binding<Bool>, initial: @escaping @MainActor () -> Date,
                     onPick: @escaping @MainActor (Date) -> Void) -> some View {
        sheet(isPresented: isPresented) {
            ComposerDateSheet(initial: initial(), onPick: onPick)
        }
    }
}
