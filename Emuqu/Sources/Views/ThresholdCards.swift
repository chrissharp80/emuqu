import SwiftUI

/// The α1-derived threshold cards of the post-workout summary: the LT1
/// estimate, the α1 crossings list, the derived-metrics block and the HR-zone
/// distribution.
///
/// Split out of `FitnessPostSummaryView`: hundreds of lines that need
/// exactly one thing from the view — the session it renders — which is what
/// makes this the seam to cut.
///
/// Deliberately NOT a `View`. It is a plain value type whose properties return
/// the same view trees the extension returned before, so the SwiftUI view
/// identity the parent builds is unchanged and no animation or `@State`
/// behaviour shifts. Wrapping these in a new `View` would have changed
/// identity; forwarding through a value type does not.
@MainActor
struct ThresholdCards {
    let session: HRVSession
}
