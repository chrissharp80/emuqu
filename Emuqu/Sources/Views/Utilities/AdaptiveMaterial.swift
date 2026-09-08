import SwiftUI

/// Materials that collapse to a solid fill when the user turns on Reduce
/// Transparency.
///
/// `.ultraThinMaterial` is a blur over whatever is behind it, so the effective
/// contrast of any text sitting on top depends on content the designer never
/// sees. That is exactly what Reduce Transparency exists to switch off, and iOS
/// does **not** do it for you — a `.ultraThinMaterial` background stays
/// translucent with the setting on unless the app substitutes something else.
///
/// Every material in this app now goes through here, so the substitution is one
/// decision in one place rather than seven independent ones that drift.
///
/// ## Usage
///
/// The environment value has to be read by a `View` — a static helper cannot
/// reach it — so each call site declares it once and passes it in:
///
/// ```swift
/// @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
///
/// // then, wherever the material was:
/// .background(AdaptiveMaterial.ultraThin(reduceTransparency))
/// .fill(AdaptiveMaterial.ultraThin(reduceTransparency))
/// ```
///
/// Both `background(_:)` and `Shape.fill(_:)` take a `ShapeStyle`, so the same
/// helper covers both spellings.
enum AdaptiveMaterial {

    /// `.ultraThinMaterial`, or an opaque elevated-card fill when the user has
    /// asked for reduced transparency.
    ///
    /// `cardElevated` rather than `cardBackground` because a material is almost
    /// always used to lift something above the content behind it, and the
    /// elevated tone preserves that reading once the blur is gone.
    @MainActor static func ultraThin(_ reduceTransparency: Bool) -> AnyShapeStyle {
        reduceTransparency
            ? AnyShapeStyle(AppTheme.cardElevated)
            : AnyShapeStyle(.ultraThinMaterial)
    }

    /// `.thinMaterial`, or an opaque elevated-card fill.
    @MainActor static func thin(_ reduceTransparency: Bool) -> AnyShapeStyle {
        reduceTransparency
            ? AnyShapeStyle(AppTheme.cardElevated)
            : AnyShapeStyle(.thinMaterial)
    }

    /// `.regularMaterial`, or an opaque card fill.
    ///
    /// Uses `cardBackground` rather than `cardElevated`: `.regularMaterial` is
    /// the heavier, more opaque material and is used here for full-width bars
    /// that sit *with* the content rather than floating above it.
    @MainActor static func regular(_ reduceTransparency: Bool) -> AnyShapeStyle {
        reduceTransparency
            ? AnyShapeStyle(AppTheme.cardBackground)
            : AnyShapeStyle(.regularMaterial)
    }
}
