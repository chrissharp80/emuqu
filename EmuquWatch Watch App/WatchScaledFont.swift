import SwiftUI

// Dynamic Type for fixed-point system fonts on the watch.
//
// `.font(.system(size: N))` does not respond to the user's text-size setting.
// watchOS has its own Text Size control (Settings → Display & Brightness →
// Text Size, and the Digital Crown in Accessibility), and a screen this small
// is where a number that refuses to grow hurts most: on `WatchLiveView` the
// 44 pt heart rate sat beside a `.caption2` "bpm" label that scaled without
// it, so at large text sizes the unit grew while the reading it labelled did
// not.
//
// ## Why this is not the app's `ScaledFont.swift`
//
// It is the same idea, deliberately re-stated rather than shared. The watch is
// a separate target whose sources come from a `PBXFileSystemSynchronizedRootGroup`
// — every `.swift` file in this folder is compiled, and nothing outside it is.
// Reaching into `Emuqu/Sources` would mean adding a cross-target exception to
// the project file by hand, and a hand-edited `project.pbxproj` has already
// cost this repository a broken build once.
//
// The duplication is nine lines of implementation. The alternative is a
// project-file edit that no gate can check.
//
// `@ScaledMetric` is a `DynamicProperty` and only drives invalidation when it
// is stored on a `View` or `ViewModifier`, which is why this is a modifier
// rather than a `Font` extension: a `Font`-returning helper would compute the
// right size once and never update when the wearer changed their text size.

extension View {
    /// A system font at `size` that scales with the wearer's text-size setting.
    ///
    /// Drop-in for `.font(.system(size:weight:design:))`.
    ///
    /// - Parameters:
    ///   - size: Point size at the default text setting. Unchanged at the
    ///     default, so adopting this does not alter the shipped appearance.
    ///   - weight: As `.system(size:weight:)`.
    ///   - design: As `.system(size:design:)`.
    ///   - monospacedDigit: Fixed-width digits. A parameter rather than a
    ///     chained call because this returns a `View`, not a `Font` — and every
    ///     site it replaces is a live metric that must not jitter as it counts.
    ///   - textStyle: Whose scaling curve to follow. Stated explicitly at each
    ///     call site rather than inferred: watchOS text styles do not share
    ///     iOS's default point sizes, so guessing a "nearest" style from the
    ///     literal — which is what the iOS helper does — would be guessing
    ///     against the wrong table.
    func watchScaledFont(
        size: CGFloat,
        weight: Font.Weight = .regular,
        design: Font.Design = .default,
        monospacedDigit: Bool = false,
        relativeTo textStyle: Font.TextStyle = .body
    ) -> some View {
        modifier(
            WatchScaledSystemFont(
                size: size,
                weight: weight,
                design: design,
                monospacedDigit: monospacedDigit,
                textStyle: textStyle
            )
        )
    }
}

private struct WatchScaledSystemFont: ViewModifier {
    @ScaledMetric private var size: CGFloat
    private let weight: Font.Weight
    private let design: Font.Design
    private let monospacedDigit: Bool

    init(
        size: CGFloat,
        weight: Font.Weight,
        design: Font.Design,
        monospacedDigit: Bool,
        textStyle: Font.TextStyle
    ) {
        _size = ScaledMetric(wrappedValue: size, relativeTo: textStyle)
        self.weight = weight
        self.design = design
        self.monospacedDigit = monospacedDigit
    }

    func body(content: Content) -> some View {
        let font = Font.system(size: size, weight: weight, design: design)
        return content.font(monospacedDigit ? font.monospacedDigit() : font)
    }
}
