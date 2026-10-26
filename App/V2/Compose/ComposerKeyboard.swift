import SwiftUI
import UIKit

/// **Whether the keyboard is actually on screen** — from UIKit's own notifications, which are
/// never wrong about it.
///
/// SwiftUI's keyboard avoidance is what keeps the composer's toolbar riding on top of the keyboard,
/// and it tracks an interactive dismissal to the point. What it can get wrong is the *end*: when the
/// keyboard goes down while something covers the composer (the photo picker, the camera, a sheet),
/// the composer can come back with the keyboard's old inset still applied — the toolbar stranded
/// mid-screen over a band of white (round 4, bug b). So the composer keeps SwiftUI's avoidance
/// while the keyboard is up, and **ignores the keyboard's safe area outright once UIKit says it has
/// gone** — the toolbar drops to the bottom safe area, whatever inset SwiftUI was left holding.
@MainActor
@Observable
final class KeyboardPresence {
    private(set) var isVisible = false
    /// Counts the keyboard coming to rest on screen: a layout held for it can let go with nothing
    /// left to move (``V2ComposerWrite``'s hold while a photo is up).
    private(set) var arrivals = 0
    @ObservationIgnored private var observers: [NSObjectProtocol] = []

    init() {
        let center = NotificationCenter.default
        let fixed: [(Notification.Name, (visible: Bool, animated: Bool))] = [
            (UIResponder.keyboardWillShowNotification, (true, false)),
            (UIResponder.keyboardWillHideNotification, (false, true)),
            (UIResponder.keyboardDidHideNotification, (false, false))
        ]
        observers = fixed.map { name, state in
            center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.set(state.visible, animated: state.animated) }
            }
        }
        observers.append(
            center.addObserver(
                forName: UIResponder.keyboardDidShowNotification, object: nil, queue: .main
            ) { [weak self] _ in
                MainActor.assumeIsolated { self?.arrivals += 1 }
            }
        )
        observers.append(
            center.addObserver(
                forName: UIResponder.keyboardWillChangeFrameNotification, object: nil, queue: .main
            ) { [weak self] note in
                let end = (note.userInfo?[UIResponder.keyboardFrameEndUserInfoKey] as? NSValue)?.cgRectValue
                MainActor.assumeIsolated {
                    guard let end else { return }
                    // A frame that ends off the bottom of the screen is a keyboard going away.
                    let screen = UIScreen.main.bounds
                    self?.set(end.minY < screen.maxY - 1 && end.height > 0, animated: true)
                }
            }
        )
    }

    isolated deinit {
        observers.forEach(NotificationCenter.default.removeObserver)
    }

    private func set(_ visible: Bool, animated: Bool) {
        guard visible != isVisible else { return }
        // The keyboard's own curve (7) — a critically damped spring — so the toolbar lands with it.
        withAnimation(animated ? .interpolatingSpring(mass: 3, stiffness: 1000, damping: 500) : nil) {
            isVisible = visible
        }
    }
}

extension View {
    /// The composer's keyboard rule: avoid it while it is up, ignore its safe area once it has gone.
    func ateComposerKeyboard(_ keyboard: KeyboardPresence) -> some View {
        ignoresSafeArea(.keyboard, edges: keyboard.isVisible ? [] : .bottom)
    }
}

/// **The page holds still while a staged photo is up.** Opening one full screen takes the keyboard
/// down behind it, and closing it brings the keyboard back. Left to follow, the page jumped twice: the
/// words scrolled back to the top and the photos dropped to the bottom as the photo grew, and jumped
/// back up just after it had landed in the old place (26 Oct). So the composer keeps the height it had
/// when the photo opened, keyboard room and all, until the keyboard is back at rest — or, if it does
/// not come back, a moment after the photo is down.
private struct ComposerPhotoHold: ViewModifier {
    let keyboard: KeyboardPresence
    @State private var restingHeight: CGFloat = 0
    @State private var isHolding = false
    @Environment(\.atePhotoViewerIsUp) private var photoIsUp
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func body(content: Content) -> some View {
        content
            // Held, it is proposed exactly this height, so nothing moves the measure meanwhile.
            .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { restingHeight = $0 }
            .frame(height: photoIsUp || isHolding ? restingHeight : nil, alignment: .top)
            .frame(maxHeight: .infinity, alignment: .top)
            .onChange(of: photoIsUp) { _, isUp in if isUp { isHolding = true } }
            // Back and at rest: the keyboard's room is the held room, so letting go moves nothing.
            .onChange(of: keyboard.arrivals) { if photoIsUp == false { isHolding = false } }
            .task(id: photoIsUp) {
                guard photoIsUp == false, isHolding else { return }
                try? await Task.sleep(for: .seconds(1))
                guard Task.isCancelled == false, photoIsUp == false else { return }
                withAnimation(reduceMotion ? nil : V2ComposerMotion.slider) { isHolding = false }
            }
    }
}

extension View {
    /// Holds the composer's layout through a staged photo's trip full screen and back.
    func ateComposerHoldsForPhoto(_ keyboard: KeyboardPresence) -> some View {
        modifier(ComposerPhotoHold(keyboard: keyboard))
    }
}
