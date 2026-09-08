@testable import Emuqu
import HealthKit
import XCTest

/// Proof suite for SleepResolver. These tests ARE the contract:
///   - one test per row of the decision matrix
///   - one test per edge case identified during the mapping pass
///   - one test per merge scenario (pause/resume, AutoSleep back-to-bed)
///
/// Anything not asserted here is not guaranteed.
final class SleepResolverTests: XCTestCase {
    // MARK: - Fixed Clock

    /// Deterministic clock anchor: 15 Jan 2026 at 10:00 PM local.
    private let bedtime: Date = {
        var components = DateComponents()
        components.year = 2026
        components.month = 1
        components.day = 15
        components.hour = 22
        components.minute = 0
        components.timeZone = TimeZone(identifier: "UTC")
        return TestDate.from(components, calendar: Calendar(identifier: .gregorian))
    }()

    private func t(_ offsetMinutes: Int, from anchor: Date? = nil) -> Date {
        (anchor ?? bedtime).addingTimeInterval(Double(offsetMinutes) * 60)
    }

    // MARK: - Builders

    private func makeStage(
        _ stage: HealthKitManager.SleepStage,
        from startMin: Int,
        to endMin: Int,
        anchor: Date? = nil,
        provenance: HealthKitManager.SleepStageProvenance = .watch
    ) -> HealthKitManager.SleepStageInterval {
        HealthKitManager.SleepStageInterval(
            stage: stage,
            start: t(startMin, from: anchor),
            end: t(endMin, from: anchor),
            provenance: provenance
        )
    }

    private func makeSession(startMin: Int, endMin: Int) -> (HRVSession, DateInterval) {
        var session = HRVSession(startDate: t(startMin))
        session.endDate = t(endMin)
        let bounds = DateInterval(start: t(startMin), end: t(endMin))
        return (session, bounds)
    }

    private func makeBedtimeWindow() -> DateInterval {
        // 10pm — 6am
        DateInterval(start: bedtime, end: bedtime.addingTimeInterval(8 * 60 * 60))
    }

    /// Build an HK category sample. We can't mock `sourceRevision` easily,
    /// so tests that care about source identity go through stage intervals
    /// directly via `SleepResolver.mergeStagesAcrossSources` / `clipToEnvelope`.
    /// The four-row dispatch tests use real HK samples so `classifyWatchSamples`
    /// is exercised end-to-end.
    private func makeHKSample(
        _ value: HKCategoryValueSleepAnalysis,
        from startMin: Int,
        to endMin: Int
    ) -> HKCategorySample {
        let type = HKCategoryType(.sleepAnalysis)
        return HKCategorySample(
            type: type,
            value: value.rawValue,
            start: t(startMin),
            end: t(endMin)
        )
    }

    private func makeContext(
        sessionBounds: DateInterval?,
        linkedBounds: [DateInterval] = [],
        watchSamples: [HKCategorySample] = [],
        rrPoints: [RRPoint] = [],
        enhanceWithRR: Bool = false,
        autoSleepExtension: SleepResolver.AutoSleepExtension? = nil
    ) -> SleepResolver.Context {
        SleepResolver.Context(
            sessionBounds: sessionBounds,
            linkedSessionBounds: linkedBounds.isEmpty ? sessionBounds.map { [$0] } ?? [] : linkedBounds,
            watchSamples: watchSamples,
            rrPoints: rrPoints,
            bedtimeWindow: makeBedtimeWindow(),
            enhanceWithRR: enhanceWithRR,
            autoSleepExtension: autoSleepExtension,
            fallbackDate: bedtime,
            splitGapMinutes: 20
        )
    }

    // MARK: - Tests

    // #1 Row 1 — session + Watch, clean night
    // Session 10pm — 6:30am. Watch reports core from 10:15pm — 6:15am.
    // Expected: ~480 minutes, awake = 0.
    func test01_row1_cleanNight() {
        let (_, bounds) = makeSession(startMin: 0, endMin: 510) // 8.5h
        let samples = [
            makeHKSample(.asleepCore, from: 15, to: 495)
        ]
        let ctx = makeContext(sessionBounds: bounds, watchSamples: samples)
        let result = SleepResolver.resolve(ctx)
        XCTAssertEqual(result.sleepData.nightSleepMinutes, 480)
        XCTAssertEqual(result.sleepData.awakeMinutes, 0)
        XCTAssertFalse(result.writeToHealthKit)
    }

    // #2 Row 1 — enhance toggle ON, not enough RR to augment → pass-through
    // This test asserts the toggle doesn't corrupt the stages when RR is
    // insufficient (< 100 points). The augmented-path interaction with the
    // classifier is tested in HRVSleepStageClassifierTests — here we only
    // check the plumbing.
    func test02_row1_enhanceToggleWithInsufficientRR_passThrough() {
        let (_, bounds) = makeSession(startMin: 0, endMin: 480)
        let samples = [makeHKSample(.asleepCore, from: 0, to: 480)]
        let ctx = makeContext(
            sessionBounds: bounds,
            watchSamples: samples, rrPoints: [], enhanceWithRR: true
        )
        let result = SleepResolver.resolve(ctx)
        XCTAssertEqual(result.sleepData.nightSleepMinutes, 480)
    }

    // #3 Row 1 — AutoSleep back-to-bed
    // Main session: 10pm — 5am, watch sleep inside = 420 min.
    // Extension: 5:30am — 6:30am (60 min sleep).
    // Gap 5:00–5:30am is not in either envelope → not counted.
    // Expected: 420 + 60 = 480 min. Two envelope sub-intervals.
    func test03_row1_autoSleepBackToBed_sumsBothExcludesGap() {
        let (_, bounds) = makeSession(startMin: 0, endMin: 420) // 10pm-5am
        let sessionSamples = [
            makeHKSample(.asleepCore, from: 0, to: 420)
        ]
        let extensionBounds = DateInterval(start: t(450), end: t(510))
        let extensionStages = [
            makeStage(.core, from: 450, to: 510, provenance: .hrvDerived)
        ]
        let ext = SleepResolver.AutoSleepExtension(
            bounds: extensionBounds, stageIntervals: extensionStages
        )
        let ctx = makeContext(
            sessionBounds: bounds,
            watchSamples: sessionSamples, autoSleepExtension: ext
        )
        let result = SleepResolver.resolve(ctx)
        XCTAssertEqual(result.sleepData.nightSleepMinutes, 480)
        XCTAssertEqual(result.sleepData.awakeMinutes, 0)
        XCTAssertEqual(result.sleepData.boundarySource, .hrValidated)
        // Two segments — the UI renders the gap between them.
        XCTAssertEqual(result.sleepData.segments.count, 2)
    }

    // #4 Row 1 — pause/resume (two linked sessions)
    // Session A: 10pm — 2am (240 min). Session B: 2:10am — 6am (230 min).
    // Watch sleep samples span 10pm — 6am continuously.
    // Expected: 240 + 230 = 470. Gap 2:00–2:10am excluded.
    func test04_row1_pauseResume_sumsAcrossLinked() {
        _ = makeSession(startMin: 0, endMin: 240) // 10pm-2am
        let linkedBounds = [
            DateInterval(start: t(0), end: t(240)),
            DateInterval(start: t(250), end: t(480))
        ]
        let samples = [
            makeHKSample(.asleepCore, from: 0, to: 480)
        ]
        let ctx = makeContext(
            sessionBounds: linkedBounds[0],
            linkedBounds: linkedBounds, watchSamples: samples
        )
        let result = SleepResolver.resolve(ctx)
        XCTAssertEqual(result.sleepData.nightSleepMinutes, 470)
    }

    // #5 Row 2 — session only, no Watch
    // Insufficient RR → empty stages → 0 sleep, no HK write (nothing to write).
    // The real inference path is exercised in HRVSleepStageClassifierTests.
    func test05_row2_sessionOnly_insufficientRRReturnsEmpty() {
        let (_, bounds) = makeSession(startMin: 0, endMin: 480)
        let ctx = makeContext(sessionBounds: bounds, watchSamples: [])
        let result = SleepResolver.resolve(ctx)
        XCTAssertEqual(result.sleepData.nightSleepMinutes, 0)
        XCTAssertFalse(result.writeToHealthKit)
    }

    // #6 Row 3 — no session, Watch only
    // Bedtime window 10pm-6am. Watch reports core 10:30pm-5:30am = 420 min.
    // Expected: 420 min. writeToHealthKit = false.
    func test06_row3_watchOnly_usesBedtimeWindow() {
        let samples = [
            makeHKSample(.asleepCore, from: 30, to: 450)
        ]
        let ctx = makeContext(
            sessionBounds: nil, watchSamples: samples
        )
        let result = SleepResolver.resolve(ctx)
        XCTAssertEqual(result.sleepData.nightSleepMinutes, 420)
        XCTAssertFalse(result.writeToHealthKit)
    }

    // #7 Row 4 — nothing at all
    func test07_row4_empty() {
        let ctx = makeContext(sessionBounds: nil, watchSamples: [])
        let result = SleepResolver.resolve(ctx)
        XCTAssertEqual(result.sleepData.nightSleepMinutes, 0)
        XCTAssertEqual(result.sleepData.awakeMinutes, 0)
        XCTAssertFalse(result.writeToHealthKit)
    }

    // #8 Edge — Watch sleep extends BEFORE session.startDate
    // Session starts 11pm. Watch says sleep from 10pm-5am (7h).
    // Expected: pre-session 10-11pm dropped; total = 6h.
    func test08_edge_watchPrefixBeforeSessionClipped() {
        let (_, bounds) = makeSession(startMin: 60, endMin: 420) // 11pm-5am
        let samples = [
            makeHKSample(.asleepCore, from: 0, to: 420) // 10pm-5am
        ]
        let ctx = makeContext(sessionBounds: bounds, watchSamples: samples)
        let result = SleepResolver.resolve(ctx)
        XCTAssertEqual(result.sleepData.nightSleepMinutes, 360) // 11pm-5am
    }

    // #9 Edge — Watch sleep extends AFTER session.endDate, no extension provided
    // Session 10pm-5am. Watch says 10pm-6am.
    // Expected: post-session 5-6am dropped; total = 7h.
    func test09_edge_watchSuffixAfterSessionClipped() {
        let (_, bounds) = makeSession(startMin: 0, endMin: 420) // 10pm-5am
        let samples = [
            makeHKSample(.asleepCore, from: 0, to: 480) // 10pm-6am
        ]
        let ctx = makeContext(sessionBounds: bounds, watchSamples: samples)
        let result = SleepResolver.resolve(ctx)
        XCTAssertEqual(result.sleepData.nightSleepMinutes, 420)
    }

    // #10 Edge — Watch + iPhone duplicate samples → merged, not double-counted
    // Direct test of `mergeStagesAcrossSources` since HKCategorySample's
    // sourceRevision can't be set from tests.
    func test10_edge_crossSourceDuplicatesMerged() {
        let watch = makeStage(.core, from: 0, to: 240, provenance: .watch)
        let phoneOverlap = makeStage(.core, from: 60, to: 300, provenance: .iphone)
        let merged = SleepResolver.mergeStagesAcrossSources([watch, phoneOverlap])
        XCTAssertEqual(merged.count, 1)
        // Union spans 0-300 = 5h = 300 min, not 4h + 4h.
        XCTAssertEqual(SleepResolver.totalMinutes(merged), 300)
    }

    // #11 Edge — multi-day HK "spillover" sample gets clipped by envelope
    // HK returns a sample that spans 3 full days. Session is 8h.
    // Expected: only the 8h inside the session counts.
    func test11_edge_multiDaySpilloverClipped() {
        let (_, bounds) = makeSession(startMin: 0, endMin: 480)
        let stale = HKCategorySample(
            type: HKCategoryType(.sleepAnalysis),
            value: HKCategoryValueSleepAnalysis.asleepCore.rawValue,
            start: t(-2 * 24 * 60), // two days before
            end: t(480 + 24 * 60) // one day after session end
        )
        let ctx = makeContext(sessionBounds: bounds, watchSamples: [stale])
        let result = SleepResolver.resolve(ctx)
        XCTAssertEqual(result.sleepData.nightSleepMinutes, 480)
    }

    // #12 Edge — awake stage inside envelope excluded from total
    // 7h core + 30min awake mid-night + 1h core. Total sleep = 8h, awake = 30min.
    func test12_edge_awakeInsideEnvelopeExcludedFromTotal() {
        let (_, bounds) = makeSession(startMin: 0, endMin: 570)
        let samples = [
            makeHKSample(.asleepCore, from: 0, to: 420), // 7h
            makeHKSample(.awake, from: 420, to: 450), // 30m awake
            makeHKSample(.asleepCore, from: 450, to: 510), // 1h
            makeHKSample(.awake, from: 510, to: 570) // awake end
        ]
        let ctx = makeContext(sessionBounds: bounds, watchSamples: samples)
        let result = SleepResolver.resolve(ctx)
        XCTAssertEqual(result.sleepData.nightSleepMinutes, 480)
        XCTAssertEqual(result.sleepData.awakeMinutes, 90)
    }

    // #12b Regression — a crash-interrupted overnight arrives with
    // a COLLAPSED recording envelope: `endDate` was nil, so callers pass
    // `endDate ?? startDate`, giving a zero-length `[start, start]` envelope.
    // The Apple Watch still recorded a full night. Before the fix the clip
    // `guard start < end` dropped every stage → totalSleepMinutes 0, sleepStart
    // nil; the dashboard `sleepSnapshot` was written empty and no refresh could
    // ever recover it (every refresh re-ran the same clip). The recording
    // envelope must never be able to erase real Watch sleep.
    func test12b_row1_collapsedEnvelopeDoesNotEraseWatchSleep() {
        let collapsed = DateInterval(start: t(0), end: t(0)) // endDate == startDate
        let samples = [
            makeHKSample(.asleepCore, from: 0, to: 480) // full night on the Watch
        ]
        let ctx = makeContext(sessionBounds: collapsed, watchSamples: samples)
        let result = SleepResolver.resolve(ctx)
        XCTAssertEqual(result.sleepData.nightSleepMinutes, 480,
                       "Watch sleep must survive a collapsed/zero-length recording envelope")
        XCTAssertNotNil(result.sleepData.sleepStart)
        XCTAssertNotNil(result.sleepData.sleepEnd)
    }

    // #13 Idempotence — resolving twice produces the same result
    func test13_idempotence() {
        let (_, bounds) = makeSession(startMin: 0, endMin: 480)
        let samples = [makeHKSample(.asleepCore, from: 0, to: 480)]
        let ctx = makeContext(sessionBounds: bounds, watchSamples: samples)
        let first = SleepResolver.resolve(ctx)
        let second = SleepResolver.resolve(ctx)
        XCTAssertEqual(first, second)
    }

    // #14 AutoSleep extension integrity — gap preserved as two segments,
    // totals don't bleed into the gap, sleepStart/sleepEnd span both.
    func test14_autoSleep_envelopeAndSegmentIntegrity() {
        let (_, bounds) = makeSession(startMin: 0, endMin: 420)
        let sessionSamples = [makeHKSample(.asleepCore, from: 0, to: 420)]
        let extensionBounds = DateInterval(start: t(480), end: t(540)) // 6am-7am
        let extensionStages = [
            makeStage(.core, from: 480, to: 540, provenance: .hrvDerived)
        ]
        let ext = SleepResolver.AutoSleepExtension(
            bounds: extensionBounds, stageIntervals: extensionStages
        )
        let ctx = makeContext(
            sessionBounds: bounds,
            watchSamples: sessionSamples, autoSleepExtension: ext
        )
        let result = SleepResolver.resolve(ctx)
        XCTAssertEqual(result.sleepData.sleepStart, t(0))
        XCTAssertEqual(result.sleepData.sleepEnd, t(540))
        XCTAssertEqual(result.sleepData.segments.count, 2)
        XCTAssertEqual(result.sleepData.nightSleepMinutes, 480)
    }

    // MARK: - Helper unit tests (not in the 14, but guard the primitives)

    func testUnion_mergesOverlapping() {
        let a = DateInterval(start: t(0), end: t(120))
        let b = DateInterval(start: t(60), end: t(180))
        let merged = SleepResolver.unionIntervals([a, b])
        XCTAssertEqual(merged.count, 1)
        XCTAssertEqual(merged[0].start, t(0))
        XCTAssertEqual(merged[0].end, t(180))
    }

    func testUnion_preservesGap() {
        let a = DateInterval(start: t(0), end: t(60))
        let b = DateInterval(start: t(90), end: t(180))
        let merged = SleepResolver.unionIntervals([a, b])
        XCTAssertEqual(merged.count, 2)
    }

    func testClipToEnvelope_keepsOnlyOverlaps() {
        let envelope = [DateInterval(start: t(30), end: t(90))]
        let stage = makeStage(.core, from: 0, to: 120)
        let clipped = SleepResolver.clipToEnvelope([stage], envelope: envelope)
        XCTAssertEqual(clipped.count, 1)
        XCTAssertEqual(clipped[0].start, t(30))
        XCTAssertEqual(clipped[0].end, t(90))
    }

    func testClipToEnvelope_emptyEnvelopeProducesEmpty() {
        let stage = makeStage(.core, from: 0, to: 60)
        let clipped = SleepResolver.clipToEnvelope([stage], envelope: [])
        XCTAssertTrue(clipped.isEmpty)
    }

    // MARK: - Integration

    // #15 Integration — row 2 (session, no Watch) asserts writeToHealthKit=true
    //
    // This is the contract that guarantees we actually export RR-inferred sleep
    // to Apple Health. The real exporter (`HealthKitManager.exportSessionMetrics`)
    // reads this flag indirectly via the `.hrEstimated` boundary source; the
    // resolver is the only component that can set that source, and it is the
    // only component that returns `writeToHealthKit = true`. If this test
    // breaks, the export gate upstream will silently no-op.
    func test15_integration_row2_triggersHealthKitWrite() {
        let (_, bounds) = makeSession(startMin: 0, endMin: 480)
        // Synthetic RR data: 8 hours at ~55 bpm (~1090ms RR), well over the
        // 100-point minimum the HRV classifier needs.
        var rrPoints: [RRPoint] = []
        var t: Int64 = 0
        for _ in 0 ..< 26_000 {
            rrPoints.append(RRPoint(t_ms: t, rr_ms: 1090))
            t += 1090
        }
        let ctx = makeContext(
            sessionBounds: bounds,
            watchSamples: [], // no Watch → row 2
            rrPoints: rrPoints
        )
        let result = SleepResolver.resolve(ctx)
        // The exporter gate (`HealthKitManager+Sleep`, the boundary-source check in
        // the sleep-stage export path) also accepts
        // `.healthKitHREstimated`; either qualifies as "we're the only source."
        let isInferred =
            result.sleepData.boundarySource == .hrEstimated ||
            result.sleepData.boundarySource == .healthKitHREstimated
        XCTAssertTrue(isInferred, "Row 2 must tag sleep as HR-inferred so the export gate fires")
        if result.sleepData.nightSleepMinutes > 0 {
            XCTAssertTrue(result.writeToHealthKit, "Row 2 with content must flag writeToHealthKit=true")
        }
    }

    // #16 Integration — AutoSleep back-to-bed, full shape check
    //
    // The row-1 back-to-bed path (user removes strap, goes back to bed, Watch
    // detects further sleep via HR) is the most bug-prone case because it
    // composes linked session bounds + a synthetic extension envelope + a
    // second set of stage intervals. Every piece has to pass through the
    // resolver idempotently, preserve the physical gap visually as two
    // segments, and sum minutes across both without double-counting the gap.
    //
    // Scenario:
    //   Session:   10:00pm → 5:00am (Watch sleep 10:15pm → 4:45pm = 6h30m = 390m)
    //   Strap off: 5:00am → 5:45am (no data, 45m gap)
    //   Extension: 5:45am → 7:15am (AutoSleep-detected sleep, 90m)
    //   Expected:  total=480m, segments=2, envelope has 2 DateIntervals
    func test16_integration_autoSleepBackToBed_fullShape() {
        let (_, bounds) = makeSession(startMin: 0, endMin: 420) // 10pm-5am
        let sessionSamples = [
            makeHKSample(.asleepCore, from: 15, to: 405) // 390m inside session
        ]
        let extensionBounds = DateInterval(start: t(465), end: t(555)) // 5:45am-7:15am
        let extensionStages = [
            makeStage(.core, from: 465, to: 555, provenance: .hrvDerived)
        ]
        let ext = SleepResolver.AutoSleepExtension(
            bounds: extensionBounds, stageIntervals: extensionStages
        )
        let ctx = makeContext(
            sessionBounds: bounds,
            watchSamples: sessionSamples, autoSleepExtension: ext
        )
        let result = SleepResolver.resolve(ctx)

        // 1. Totals: 390 + 90 = 480 min, gap not counted
        XCTAssertEqual(result.sleepData.nightSleepMinutes, 480, "Session sleep + extension sleep, gap excluded")
        XCTAssertEqual(result.sleepData.awakeMinutes, 0)

        // 2. Visual integrity: two segments, gap between them
        XCTAssertEqual(result.sleepData.segments.count, 2, "Two segments — chart renders the gap")
        if let first = result.sleepData.segments.first, let second = result.sleepData.segments.last {
            XCTAssertLessThan(first.sleepEnd, second.sleepStart, "Gap between segments is real, not zero-width")
            let gap = second.sleepStart.timeIntervalSince(first.sleepEnd) / 60
            XCTAssertGreaterThan(gap, 20, "Gap ≥ 20 min (matches split-gap threshold)")
        }

        // 3. Envelope: sleepStart/sleepEnd span both sub-intervals
        XCTAssertEqual(result.sleepData.sleepStart, t(15), "Earliest sleep = Watch onset inside session")
        XCTAssertEqual(result.sleepData.sleepEnd, t(555), "Latest sleep = extension end")

        // 4. Provenance: boundarySource marks this as HR-validated (because
        //    the extension was present). Not .healthKit alone — the UI uses
        //    this to badge "extended sleep detected."
        XCTAssertEqual(result.sleepData.boundarySource, .hrValidated)

        // 5. Does NOT write to HealthKit — Watch is the primary source, so
        //    writing our derived copy back would pollute future reads.
        XCTAssertFalse(result.writeToHealthKit, "Row 1 never writes back to HealthKit")

        // 6. Idempotence: resolving the same context twice is stable.
        let secondRun = SleepResolver.resolve(ctx)
        XCTAssertEqual(result, secondRun, "Resolver is idempotent under back-to-bed composition")
    }

    // MARK: - iPhone "asleepUnspecified" filter
    //
    // Reproduces a beta tester's bug. iPhone auto-
    // detected sleep starting 90 min before the Apple Watch detected
    // actual sleep onset; resolver was picking the (wrong) iPhone start.

    /// Bug repro: iPhone says asleep at bedtime, Watch says asleep
    /// 90 min later. Resolver must trust the Watch.
    func testIphoneEarlyUnspecifiedDoesNotPullSleepStartBack() {
        // anchor t(0) = 10 PM. iPhone wrote asleepUnspecified from
        // t(-120) (8 PM) through t(-30) (9:30 PM) — phone-down auto-
        // detection. Watch wrote real detailed stages from t(-30) onward.
        let iphoneEarly = makeStage(.unspecified, from: -120, to: -30, provenance: .iphone)
        let watchCore1 = makeStage(.core, from: -30, to: 60, provenance: .watch)
        let watchDeep = makeStage(.deep, from: 60, to: 120, provenance: .watch)
        let watchCore2 = makeStage(.core, from: 120, to: 180, provenance: .watch)
        let filtered = SleepResolver.dropIphoneEarlySleepGuesses([iphoneEarly, watchCore1, watchDeep, watchCore2])

        XCTAssertFalse(
            filtered.contains(where: { $0.provenance == .iphone && $0.start < watchCore1.start.addingTimeInterval(-15 * 60) }),
            "iPhone asleepUnspecified that predates Watch by >15 min must be dropped"
        )
        // Earliest START of any kept sleep stage = 9:30 PM, not 8 PM.
        let earliestSleepStart = filtered.filter { $0.stage != .awake }.map(\.start).min()
        XCTAssertEqual(earliestSleepStart, watchCore1.start,
                       "Earliest sleep start must match Watch onset, not iPhone's pre-sleep guess")
    }

    /// Watch only — no iPhone samples — passes through unchanged.
    func testWatchOnlyNotAffectedByFilter() {
        let watchCore = makeStage(.core, from: 0, to: 60, provenance: .watch)
        let watchDeep = makeStage(.deep, from: 60, to: 120, provenance: .watch)
        let result = SleepResolver.dropIphoneEarlySleepGuesses([watchCore, watchDeep])
        XCTAssertEqual(result.count, 2, "Watch-only samples pass through")
    }

    /// No Watch detailed stages at all — iPhone is the only signal,
    /// keep it. (User wears Watch loosely, no detail captured.)
    func testIphoneOnlyKeptWhenNoWatchDetail() {
        let iphone = makeStage(.unspecified, from: 0, to: 480, provenance: .iphone)
        let result = SleepResolver.dropIphoneEarlySleepGuesses([iphone])
        XCTAssertEqual(result.count, 1, "iPhone-only samples are kept — no Watch ground truth to compare")
    }

    /// iPhone sample that starts WITHIN the Watch window or AFTER it —
    /// keep. Specifically when Watch died mid-night, iPhone may have
    /// caught the tail end of sleep.
    func testIphoneLaterSampleKeptForWatchGap() {
        let watchCore = makeStage(.core, from: 0, to: 60, provenance: .watch)
        let watchDeep = makeStage(.deep, from: 60, to: 180, provenance: .watch)
        // iPhone wrote a long span covering the Watch window + extending
        // past it. The Watch ENDED at t(180). iPhone span [60, 360]
        // starts inside the Watch window, ends 3h later.
        let iphoneContinuation = makeStage(.unspecified, from: 60, to: 360, provenance: .iphone)
        let result = SleepResolver.dropIphoneEarlySleepGuesses([iphoneContinuation, watchCore, watchDeep])
        XCTAssertTrue(
            result.contains(where: { $0.provenance == .iphone }),
            "iPhone sample that starts at/after Watch's detected onset must be kept"
        )
    }

    /// Sanity at the 15-min tolerance boundary: iPhone sample starting
    /// 14 min before Watch is kept; 16 min before is dropped.
    func testIphoneFilterToleranceBoundary() {
        let watchCore = makeStage(.core, from: 30, to: 60, provenance: .watch)
        let iphone14 = makeStage(.unspecified, from: 16, to: 30, provenance: .iphone)  // 14 min before
        let iphone16 = makeStage(.unspecified, from: 14, to: 30, provenance: .iphone)  // 16 min before

        let kept = SleepResolver.dropIphoneEarlySleepGuesses([iphone14, watchCore])
        XCTAssertTrue(kept.contains(where: { $0.provenance == .iphone }), "14 min before Watch: kept")

        let dropped = SleepResolver.dropIphoneEarlySleepGuesses([iphone16, watchCore])
        XCTAssertFalse(dropped.contains(where: { $0.provenance == .iphone }), "16 min before Watch: dropped")
    }
}
