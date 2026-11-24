import SwiftUI

/// Every card on the morning results screen: the hero score ring, the metric
/// cards, the sleep and training cards, the split-night section, and the
/// technical-details block.
///
/// Wide initialiser: these cards genuinely read the whole morning result. A
/// narrower interface would mean either passing the view itself — which
/// reduces nothing — or a facade that hides the coupling without removing it.
///
/// Deliberately NOT a `View`: it returns view trees into the host view's
/// body, so SwiftUI view identity, animation and `@State` stay the host's.
/// The snapshot suite pins that.
@MainActor
struct MorningDetailCards {
    let vm: MorningResultsViewModel
    let settingsManager: SettingsManager
    let session: HRVSession
    let result: HRVAnalysisResult
    let recentSessions: [HRVSession]
    let linkedSegments: [LinkedSegmentInfo]?
    let onUnlinkSegment: ((UUID) -> Bool)?
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
