import AteKit
import SwiftUI

/// **Welcome's mark** (`design/rebuild/onboarding-calm.html`, Welcome A, Eamon 17 Oct): the logo
/// standing still, five stars popping in under it, then the line. Nothing else on the
/// coral: no photos, no receipt. Ink throughout, since the coral never changes with the mode.
struct AteWelcomeMark: View {
    @State private var showsStars = false
    @State private var showsLine = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        VStack(spacing: AteWelcomeCardMetrics.markGap) {
            AteWordmark(height: AteWelcomeCardMetrics.wordmark, colour: AteColor.ink)
            stars
            Text(AteWelcomeCardMetrics.line)
                .ateText(.welcomeLine)
                .multilineTextAlignment(.center)
                .foregroundStyle(AteColor.ink)
                .frame(maxWidth: AteWelcomeCardMetrics.lineWidth)
                .fixedSize(horizontal: false, vertical: true)
                .opacity(showsLine ? 1 : 0)
                .offset(y: showsLine ? 0 : AteWelcomeCardMetrics.lineRise)
        }
        .frame(maxWidth: .infinity)
        .accessibilityElement(children: .combine)
        .task { reveal() }
    }

    /// Five stars, popping in one after another as Welcome opens.
    private var stars: some View {
        HStack(spacing: AteWelcomeCardMetrics.starGap) {
            ForEach(0..<AteWelcomeCardMetrics.starCount, id: \.self) { index in
                AteIcon.starFilled.view(size: AteWelcomeCardMetrics.star)
                    .foregroundStyle(AteColor.ink)
                    .scaleEffect(showsStars ? 1 : AteWelcomeCardMetrics.starFrom)
                    .rotationEffect(.degrees(showsStars ? 0 : AteWelcomeCardMetrics.starTurn))
                    .opacity(showsStars ? 1 : 0)
                    .animation(reduceMotion ? nil : pop(index), value: showsStars)
            }
        }
        .accessibilityHidden(true)
    }

    private func pop(_ index: Int) -> Animation {
        AteWelcomeCardMetrics.starPop.delay(Double(index) * AteWelcomeCardMetrics.starStep)
    }

    private func reveal() {
        showsStars = true
        withAnimation(reduceMotion ? nil : AteWelcomeCardMetrics.lineFade) { showsLine = true }
    }
}

/// **Welcome's quiet way in** — "See what everyone's eating" (or "Not now" when Welcome is the
/// sign-in ask), ink on the coral, with the hairline under it the markup draws. The one underlined
/// line in the app, kept from the build.
struct AteWelcomeLink: View {
    let title: String
    /// Ink on Welcome's coral; first run's ground passes the surface's own foreground, so the link
    /// still reads in dark.
    var colour: Color = AteColor.ink
    var identifier = "welcome.browse"
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Text(title)
                .ateText(.control)
                .multilineTextAlignment(.center)
                .padding(.bottom, AteMetrics.hairspace)
                .overlay(alignment: .bottom) {
                    Rectangle().fill(colour).frame(height: AteWelcomeCardMetrics.underline)
                }
                .frame(minHeight: AteMetrics.hit)
                .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .foregroundStyle(colour)
        .accessibilityIdentifier(identifier)
    }
}

enum AteWelcomeCardMetrics {
    static let line = "A personal journal of the best food you've ever eaten."
    /// The logo 123 high (260 across), the stars and the line 26 apart under it.
    static let wordmark: CGFloat = 123
    static let markGap: CGFloat = 26
    static let lineWidth: CGFloat = 280
    static let lineRise: CGFloat = 6
    static let star: CGFloat = 22
    static let starGap: CGFloat = 6
    static let starCount = 5
    static let starFrom: CGFloat = 0.3
    static let starTurn: Double = -40
    static let starStep: Double = 0.12
    static let starPop = Animation.spring(response: 0.38, dampingFraction: 0.55)
    static let lineFade = Animation.easeOut(duration: 0.8).delay(0.8)
    static let underline: CGFloat = 1
    /// `left:20; right:20; bottom:40; gap:6` — Apple's button, then the link.
    static let doorsGap: CGFloat = 6
    static let doorsBottom: CGFloat = 40
}
