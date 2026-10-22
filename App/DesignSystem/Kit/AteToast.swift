import SwiftUI

/// **The toast** — one line on glass at the top of the page, for something finished out of sight
/// (a bug report, which sends itself after the sheet has gone). It drops in, holds for two seconds
/// and goes; VoiceOver reads it. Nothing on it to tap.
struct AteToast: View {
    let icon: AteIcon
    let text: String

    @Environment(\.atePalette) private var palette

    var body: some View {
        HStack(spacing: AteMetrics.tight) {
            icon.view(size: AteToastMetrics.glyph)
            Text(text)
                .ateText(.control)
                .lineLimit(1)
        }
        .foregroundStyle(palette.fg)
        .padding(.horizontal, AteToastMetrics.inset)
        .frame(height: AteToastMetrics.height)
        .glassEffect(.regular, in: .capsule)
        .accessibilityElement(children: .combine)
    }
}

extension View {
    /// Shows `text` as an ``AteToast`` while it is set, and clears it after two seconds.
    func ateToast(_ text: Binding<String?>, icon: AteIcon = .check) -> some View {
        modifier(AteToastModifier(text: text, icon: icon))
    }
}

private struct AteToastModifier: ViewModifier {
    @Binding var text: String?
    let icon: AteIcon

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func body(content: Content) -> some View {
        content
            .overlay(alignment: .top) {
                if let shown = text {
                    AteToast(icon: icon, text: shown)
                        .padding(.top, AteMetrics.tight)
                        .transition(reduceMotion ? .opacity : .move(edge: .top).combined(with: .opacity))
                        .onAppear { AccessibilityNotification.Announcement(shown).post() }
                        .task(id: shown) {
                            try? await Task.sleep(for: AteToastMetrics.hold)
                            text = nil
                        }
                }
            }
            .animation(reduceMotion ? nil : .snappy, value: text)
    }
}

enum AteToastMetrics {
    static let height: CGFloat = 44
    static let inset: CGFloat = 18
    static let glyph: CGFloat = 18
    static let hold = Duration.seconds(2)
}
