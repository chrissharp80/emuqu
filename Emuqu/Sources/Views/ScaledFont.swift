import SwiftUI

// Dynamic Type for fixed-point system fonts.
//
// The app's semantic styles (`.body`, `.caption`, …) already scale with the
// user's text-size setting. Hard-coded `.font(.system(size: N))` does not: at
// AX5 the surrounding text grows while those numbers stay put, which breaks
// layout AND leaves the largest figures on screen rendered at their smallest
// size for exactly the users who enlarged their text.
//
// SwiftUI has no `Font.system(size:relativeTo:)` overload, so the fix has to
// come from `@ScaledMetric`. `@ScaledMetric` is a `DynamicProperty`, and a
// `DynamicProperty` only drives invalidation when it is stored on a `View` or
// a `ViewModifier` — which is why this is a modifier rather than a
// `Font` extension. A `Font`-returning helper backed by `UIFontMetrics` would
// compute the right value on first render and then never update when the user
// changes their text size, because nothing in the view would be observing the
// size category.
//
// Some detail screens declare their own
// `@ScaledMetric` properties inline; that shape is equivalent and stays as-is.
// This modifier exists so the remaining ~300 call sites across ~50 files can
// adopt Dynamic Type without each one growing a block of storage properties.
//
// NOT for fixed-canvas rendering: `RecapCard` draws a 1080×1920 shareable PNG
// where the point size IS the design, and deliberately keeps `.system(size:)`.

extension View {
    /// A system font at `size` that scales with the user's Dynamic Type setting.
    ///
    /// Drop-in for `.font(.system(size:weight:design:))` on a view.
    ///
    /// - Parameters:
    ///   - size: The point size at the default text-size setting. Unchanged at
    ///     `.large` (the iOS default), so adopting this never alters the
    ///     out-of-the-box appearance.
    ///   - weight: Font weight, as with `.system(size:weight:)`.
    ///   - design: Font design, as with `.system(size:design:)`.
    ///   - monospacedDigit: Fixed-width digits, as with the `.monospacedDigit()`
    ///     modifier on `Font`. A parameter rather than a chained call because
    ///     `scaledFont` returns a `View`, not a `Font`, so there is nothing left
    ///     to chain it onto — and every place this replaces was a live metric
    ///     that must not jitter as its digits change.
    ///   - textStyle: The style whose scaling curve to follow. Defaults to the
    ///     built-in style whose own default size is nearest `size`, so a 12 pt
    ///     label scales like a caption and a 34 pt figure scales like a large
    ///     title — matching how Apple's own metrics grow at each step, instead
    ///     of applying the body curve uniformly.
    func scaledFont(
        size: CGFloat,
        weight: Font.Weight = .regular,
        design: Font.Design = .default,
        monospacedDigit: Bool = false,
        relativeTo textStyle: Font.TextStyle? = nil
    ) -> some View {
        modifier(
            ScaledSystemFont(
                size: size,
                weight: weight,
                design: design,
                monospacedDigit: monospacedDigit,
                textStyle: textStyle ?? .nearest(toPointSize: size)
            )
        )
    }
}

// MARK: - Implementation

private struct ScaledSystemFont: ViewModifier {
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

fileprivate extension Font.TextStyle {
    /// Default point size of each text style at the `.large` content size —
    /// the iOS default. Source: Apple HIG, "Typography → Specifications".
    static let defaultPointSizes: [(style: Font.TextStyle, points: CGFloat)] = [
        (.caption2, 11),
        (.caption, 12),
        (.footnote, 13),
        (.subheadline, 15),
        (.callout, 16),
        (.body, 17),
        (.headline, 17),
        (.title3, 20),
        (.title2, 22),
        (.title, 28),
        (.largeTitle, 34)
    ]

    /// The built-in style whose default size is closest to `points`.
    ///
    /// Anchoring to the nearest style — rather than always to `.body` — keeps
    /// the growth curve proportionate: at AX5 a caption grows ~2.1× while a
    /// large title grows ~1.4×, and a 34 pt hero figure scaled on the caption
    /// curve would overflow its container long before the body text did.
    static func nearest(toPointSize points: CGFloat) -> Font.TextStyle {
        defaultPointSizes
            .min { abs($0.points - points) < abs($1.points - points) }?
            .style ?? .body
    }
}
