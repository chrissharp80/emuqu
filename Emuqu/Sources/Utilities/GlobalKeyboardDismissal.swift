import UIKit

/// Installs a window-level `UITapGestureRecognizer` that dismisses
/// the keyboard whenever the user taps a non-control area. Works
/// on every screen in the app — no per-view modifier required.
///
/// **Why this exists.** User report: the keyboard refuses
/// to dismiss on Profile, Settings → Reports email field, contact
/// list, and other Forms. SwiftUI's default behavior is `.automatic`
/// which only fires on certain interactions. Most chat / messaging
/// apps install a global tap-outside-to-dismiss in addition to per-
/// scroll dismissal.
///
/// **Why `cancelsTouchesInView = false`.** Without this, the gesture
/// recognizer would swallow taps before they reach buttons, list
/// rows, etc. With `false`, taps still propagate to whatever else
/// wants to handle them — we're just *additionally* listening so
/// we can resign first responder.
///
/// **Why `delaysTouchesBegan = false` and `delaysTouchesEnded = false`**.
/// Both are false by default for `UITapGestureRecognizer`, but we
/// set them explicitly so a future iOS change can't introduce a
/// touch delay that makes the rest of the UI feel laggy.
///
/// Idempotent — safe to call multiple times. Only installs once
/// per app launch.
@MainActor
final class GlobalKeyboardDismissal: NSObject {
    static let shared = GlobalKeyboardDismissal()

    private var installed = false
    private var recognizer: UITapGestureRecognizer?

    /// Install the global tap-to-dismiss gesture. Retries if no key
    /// window is available yet (rare cold-launch timing).
    func install() {
        guard !installed else { return }
        guard let window = UIApplication.activeKeyWindow else {
            DispatchQueue.main.asyncAfter(deadline: .now() + .milliseconds(250)) { [weak self] in
                self?.install()
            }
            return
        }
        installed = true

        let tap = UITapGestureRecognizer(target: self, action: #selector(handleTap))
        tap.cancelsTouchesInView = false
        tap.delaysTouchesBegan = false
        tap.delaysTouchesEnded = false
        // Make sure we don't get in the way of other gestures
        // (scroll, drag, button highlight, swipe-to-go-back).
        tap.delegate = self
        window.addGestureRecognizer(tap)
        recognizer = tap

        NSLog("[GlobalKeyboardDismissal] installed window-level tap-to-dismiss")
    }

    @objc private func handleTap() {
        // Standard "resign first responder, whoever you are" call.
        UIApplication.shared.sendAction(
            #selector(UIResponder.resignFirstResponder),
            to: nil, from: nil, for: nil
        )
    }

    /// Pre-warm the UIKit keyboard / input daemon shortly after launch so the
    /// first tap on a text field doesn't pay the daemon's cold-start latency.
    ///
    /// Warm-and-release: an off-screen field becomes first responder to create
    /// the input session (the expensive daemon IPC), then resigns on the next
    /// runloop — before the keyboard animates up — so it never occupies the
    /// first-responder slot (the failure mode of a warmer that holds it)
    /// and no keyboard flashes on screen.
    ///
    /// Skipped when something is already editing: taking first responder
    /// would dismiss the keyboard the user is typing on.
    func prewarmKeyboard() {
        guard let window = UIApplication.activeKeyWindow, !Self.containsFirstResponder(window) else { return }
        let field = UITextField(frame: .zero)
        window.addSubview(field)
        field.becomeFirstResponder()
        DispatchQueue.main.async {
            field.resignFirstResponder()
            field.removeFromSuperview()
        }
    }

    private static func containsFirstResponder(_ view: UIView) -> Bool {
        view.isFirstResponder || view.subviews.contains { containsFirstResponder($0) }
    }
}

extension UIApplication {
    /// The key window of the frontmost scene — foreground-active first, then
    /// foreground-inactive, then whatever is connected — so a UIKit helper
    /// attaches to the window the user is looking at. Nil with no scene.
    @MainActor
    static var activeKeyWindow: UIWindow? {
        let scenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
        let preferred = scenes.first { $0.activationState == .foregroundActive }
            ?? scenes.first { $0.activationState == .foregroundInactive }
            ?? scenes.first
        guard let scene = preferred else { return nil }
        return scene.windows.first(where: { $0.isKeyWindow }) ?? scene.windows.first
    }
}

extension GlobalKeyboardDismissal: UIGestureRecognizerDelegate {
    /// Allow simultaneous recognition with everything else — we are
    /// only listening, not stealing. This is what makes `Button`,
    /// `List` row taps, scroll gestures, and `simultaneousGesture`
    /// modifiers all keep working alongside our tap-to-dismiss.
    func gestureRecognizer(
        _: UIGestureRecognizer,
        shouldRecognizeSimultaneouslyWith _: UIGestureRecognizer
    ) -> Bool {
        true
    }

    /// Don't fire when the user taps inside a `UITextField` or
    /// `UITextView` — that's their attempt to focus / edit the
    /// field, not dismiss it. Lets caret-positioning taps work
    /// normally. A tap on any other control (a switch, a stepper)
    /// belongs to that control alone.
    func gestureRecognizer(
        _: UIGestureRecognizer,
        shouldReceive touch: UITouch
    ) -> Bool {
        var view: UIView? = touch.view
        while let v = view {
            if v is UITextField || v is UITextView || v is UIControl {
                return false
            }
            view = v.superview
        }
        return true
    }
}
