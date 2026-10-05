import SwiftUI

/// Every card on the morning results screen: the hero score ring, the metric
/// cards, the sleep and training cards, the split-night section, and the
/// technical-details block.
///
/// Split out of `MorningResultsView` — 667 lines out of a
/// 2,558-line view.
///
/// This one has a wide initialiser, unlike [ThresholdCards] or
/// [TagsAndNotesCard] which needed one or two inputs each. That is honest
/// rather than accidental: these cards genuinely read the whole morning
/// result. Bundling them behind a narrower interface would have meant either
/// passing the view itself — which reduces nothing — or inventing a facade that
/// hides the coupling without removing it.
///
/// Deliberately NOT a `View`. It returns the same view trees the extension
/// returned, from the same positions, so SwiftUI view identity, animation and
/// `@State` behaviour are unchanged. The snapshot suite pins that.
@MainActor
struct MorningDetailCards {
    let vm: MorningResultsViewModel
    let session: HRVSession
    let result: HRVAnalysisResult
    let recentSessions: [HRVSession]
    let collector: RRCollector
    let morningCoordination: MorningCoordination
    let linkedSegments: [LinkedSegmentInfo]?
    let onUnlinkSegment: ((UUID) -> Void)?
    let onToggleTag: (ReadingTag) -> Void

    // Dynamic Type sizes resolve in the view (`@ScaledMetric` cannot live in an
    // extension) and arrive here already scaled.
    let scoreRingSize: CGFloat
    let heroScoreFontSize: CGFloat
    let metricValueFontSize: CGFloat

    /// `vm` arrives as a plain value, so `$vm.notes` is not available here —
    /// the notes binding is threaded in explicitly by the view that owns it.
    @Binding var notes: String

    @Binding var showingScoreExplainer: Bool
    @Binding var showingUnlinkConfirmation: Bool
    @Binding var pendingUnlinkSegmentId: UUID?
    @Binding var removedSegmentIds: Set<UUID>
}
