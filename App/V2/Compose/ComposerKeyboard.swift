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
