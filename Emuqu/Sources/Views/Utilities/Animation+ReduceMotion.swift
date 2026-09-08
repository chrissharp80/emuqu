import SwiftUI

// MARK: - Reduce Motion–aware Animation helpers
//
// Interactive transitions must not go through
// `withAnimation(.easeOut(...))` or `.animation(.easeInOut, value:)` without
// consulting `UIAccessibility.isReduceMotionEnabled`. Apple HIG: short
// "essential" feedback transitions (cross-fades, scrolls) are still allowed
// when the user has Reduce Motion on; longer or parallax-style transitions
// must collapse to instant. The helpers below give callers one knob to set
// that policy uniformly without copy-pasting `@Environment` access into
// every view.
//
// Usage:
//
//   @Environment(\.accessibilityReduceMotion) private var reduceMotion
//   ...
//   withAnimation(.zenInterface(.easeOut(duration: 0.25), reduceMotion: reduceMotion)) {
//       // state mutation
//   }
//
// Or, when you'd rather keep the call site as a plain modifier chain, use
// the `Animation?` form on the `.animation(_:value:)`
// modifier:
//
//   .animation(.zenInterface(.easeInOut(duration: 0.4), reduceMotion: reduceMotion),
//              value: someValue)
//
// The helper returns `nil` when Reduce Motion is active, which SwiftUI
// interprets as "apply the change instantly" — that's the standard
// behaviour the platform expects.

extension Animation {
    /// Returns `animation` when the user does not have Reduce Motion on,
    /// otherwise `nil` so the change is applied without animation.
    /// Centralising this lets us tune the policy in one place if Apple's
    /// guidance shifts (e.g. allow specific cross-fades through).
    static func zenInterface(_ animation: Animation, reduceMotion: Bool) -> Animation? {
        reduceMotion ? nil : animation
    }
}
