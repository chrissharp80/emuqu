import SwiftUI

/// The α1-derived threshold cards of the post-workout summary: the LT1
/// estimate, the α1 crossings list, the derived-metrics block and the HR-zone
/// distribution.
///
/// Deliberately NOT a `View`. It is a plain value type whose properties return
/// view trees into the parent's body, so the SwiftUI view identity the parent
/// builds holds and no animation or `@State` behaviour shifts. Wrapping these
/// in a new `View` would change identity; forwarding through a value type
/// does not.
@MainActor
struct ThresholdCards {
    let session: HRVSession
}
