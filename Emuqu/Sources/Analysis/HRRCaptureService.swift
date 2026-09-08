import Foundation
import HealthKit

// MARK: - HRR Capture Service
//
// Heart-rate recovery capture follows a three-tier fallback:
//   1. Strap — Polar still streaming in the 60–120s window after stop.
//      Gives beat-accurate HR at the sample point.
//   2. Watch HR samples — if the strap has dropped but an Apple Watch was
//      writing HR to HealthKit during the post-stop window.
//   3. Apple's computed value — HealthKit's
//      `heartRateRecoveryOneMinute` quantity, written automatically after a
//      Watch-tracked workout session.
//
// Capture is opportunistic: the user is never prompted to "keep the strap on"
// and a missed HRR is not a failure. Whatever tiers succeed are added to the
// session's workoutMetadata with provenance tags.
@MainActor
final class HRRCaptureService {
    private let polarManager: PolarManager
    private let healthKit: HealthKitManager
    private let captureWindowSec: Int

    init(polarManager: PolarManager, healthKit: HealthKitManager, captureWindowSec: Int = 120) {
        self.polarManager = polarManager
        self.healthKit = healthKit
        self.captureWindowSec = captureWindowSec
    }

    // MARK: - Entry point

    /// Collect HRR samples across all available tiers. Runs for up to
    /// `captureWindowSec` seconds from `stopDate`. Returns the merged sample
    /// list ordered by offset.
    func captureHRR(
        stopDate: Date,
        peakHR: Int
    ) async -> [HRRSample] {
        // Defensive guard against a post-workout crash.
        // When the user records a workout with no
        // HR source (Watch off, no strap), peakHR is 0; computing
        // `peakHR - currentHR` yields negative drops, which downstream
        // code displays as nonsense and can crash the
        // monotonic-drop pass on edge inputs. Bail early: no peak →
        // no HRR window. The post-summary view shows "No signal"
        // gracefully.
        guard peakHR >= 60 else {
            debugLog("[HRRCaptureService] skipping capture — peakHR=\(peakHR) is implausible (<60); workout likely had no HR source")
            return []
        }
        guard captureWindowSec > 0 else {
            debugLog("[HRRCaptureService] skipping capture — captureWindowSec=\(captureWindowSec)")
            return []
        }
        var samples = await captureStrapAndWatchSamples(stopDate: stopDate, peakHR: peakHR)
        await appendAppleHRRIfMissing(&samples, stopDate: stopDate, peakHR: peakHR)
        return finalise(samples)
    }

    /// Tiers 1 and 2, with Watch samples deduped against strap samples that
    /// already cover the same offset.
    private func captureStrapAndWatchSamples(stopDate: Date, peakHR: Int) async -> [HRRSample] {
        // Tier 1 — strap window. Sample HR at +60s and +120s while the strap
        // keeps streaming. If the strap drops mid-window, stop early and let
        // Tier 2/3 fill in.
        var samples = await captureStrapSamples(stopDate: stopDate, peakHR: peakHR)
        debugLog("[HRRCaptureService] tier 1 done — \(samples.count) strap sample(s)")
        // Tier 2 — Watch HR samples from HealthKit. Safe to query now; the
        // Watch has had the full capture window to write samples.
        let watchSamples = await captureWatchSamples(stopDate: stopDate, peakHR: peakHR)
        let dedupedWatch = watchSamples.filter { sample in
            !samples.contains { $0.offsetSec == sample.offsetSec && $0.provenance == .strap }
        }
        samples.append(contentsOf: dedupedWatch)
        debugLog("[HRRCaptureService] tier 2 done — \(watchSamples.count) watch sample(s) (after dedupe vs tier 1: +\(dedupedWatch.count))")
        return samples
    }

    /// Tier 3 — Apple's precomputed HRR, if a Watch workout detected the
    /// session. Added only when neither strap nor Watch produced a 1-minute
    /// reading.
    private func appendAppleHRRIfMissing(_ samples: inout [HRRSample], stopDate: Date, peakHR: Int) async {
        guard !samples.contains(where: { $0.offsetSec >= 55 && $0.offsetSec <= 65 }) else { return }
        guard let appleHRR = await captureAppleHealthKitHRR(stopDate: stopDate, peakHR: peakHR) else {
            debugLog("[HRRCaptureService] tier 3 — no Apple-computed HRR available (no Watch workout in ±5 min window)")
            return
        }
        samples.append(appleHRR)
        debugLog("[HRRCaptureService] tier 3 — recovered Apple's heartRateRecoveryOneMinute (drop=\(appleHRR.drop))")
    }

    /// Orders by offset and drops physiologically impossible readings.
    ///
    /// The all-tiers-empty log is deliberately not `.warning`. For a
    /// user without a Watch who dismisses the summary quickly (so Polar
    /// disconnects before the +60 s mark), all three tiers empty is the
    /// expected outcome — they simply won't have an HRR number for this
    /// session. Surfacing it as a Problem makes the troubleshooting list look
    /// broken to the user every time they finish a walk.
    private func finalise(_ samples: [HRRSample]) -> [HRRSample] {
        let final = Self.enforceMonotonicDrop(samples.sorted { $0.offsetSec < $1.offsetSec })
        if final.isEmpty {
            debugLog("[HRRCaptureService] all 3 tiers empty — see tier-by-tier logs above for cause")
        }
        return final
    }

    /// Drop later samples whose `drop` from peak is *smaller* than an
    /// earlier sample's drop. Cumulative recovery is monotonic by
    /// definition — the heart can't "un-recover". A later reading that
    /// shows a smaller drop is a contamination signal: the user moved,
    /// stood up, walked to gear, or the Watch's passive HR sampler
    /// caught a noise spike between the strap dropping and the +120 s
    /// mark.
    ///
    /// This was a real user complaint: 1-min HRR read
    /// 45 bpm, 2-min HRR read 24 bpm — the inversion. The math at
    /// capture time is correct (`peakHR - hrAtSample`), so the only
    /// honest response is to drop the contaminated reading rather than
    /// surface a number that contradicts the physiology.
    ///
    /// Static + nonisolated so tests can reach it without exercising
    /// the async capture path. The function is pure — no instance or
    /// global state — so MainActor isolation is unnecessary.
    /// Does NOT discard ANY sample whose drop is
    /// less than the prior max — a brief stretch / yawn / step that
    /// nudges HR back up by 5-7 bpm would kill the +120s reading even
    /// though the user actually wants to see it. The 1→2 min
    /// inversion case (45 → 24, a 21-bpm reversal) is real
    /// contamination; small regressions within sensor / micro-movement
    /// noise are not. Allow a `regressionTolerance` of 10 bpm —
    /// only sample drops more than 10 bpm BELOW the running max are
    /// suppressed. The 21-bpm inversion still gets dropped; a 6-bpm
    /// dip survives so the user sees their actual 2-min recovery.
    nonisolated static func enforceMonotonicDrop(_ samples: [HRRSample]) -> [HRRSample] {
        var kept: [HRRSample] = []
        var maxDropSoFar: Int?
        for s in samples {
            guard let prior = maxDropSoFar else {
                kept.append(s)
                maxDropSoFar = s.drop
                continue
            }
            guard s.drop >= prior - regressionTolerance else {
                logContaminatedSample(s, priorMax: prior, regressionTolerance: regressionTolerance)
                continue
            }
            kept.append(s)
            if s.drop > prior { maxDropSoFar = s.drop }
        }
        return kept
    }

    /// A sample this far below the running max is contamination, not recovery.
    nonisolated private static let regressionTolerance = 10

    nonisolated private static func logContaminatedSample(_ s: HRRSample, priorMax: Int, regressionTolerance: Int) {
        debugLog(
            "[HRRCaptureService] dropping +\(s.offsetSec)s sample (drop=\(s.drop), provenance=\(s.provenance)) — \(priorMax - s.drop) bpm below prior max=\(priorMax) (tolerance=\(regressionTolerance)). Real contamination — yawn / sensor inversion.",
            level: .warning
        )
    }

    // MARK: - Tier 1 — Strap

    private func captureStrapSamples(stopDate: Date, peakHR: Int) async -> [HRRSample] {
        var samples: [HRRSample] = []
        for target in [60, 120] where target <= captureWindowSec {
            let secondsToWait = target - Int(Date().timeIntervalSince(stopDate))
            guard secondsToWait > 0 else { continue }
            do {
                try await Task.sleep(nanoseconds: UInt64(secondsToWait) * 1_000_000_000)
            } catch {
                debugLog("[HRRCaptureService] tier 1 — sleep cancelled at +\(target)s, breaking")
                break
            }
            guard let hr = strapHR(at: target) else { break }
            samples.append(HRRSample(
                offsetSec: target, hr: hr, drop: peakHR - hr,
                peakHR: peakHR, provenance: .strap
            ))
        }
        return samples
    }

    /// The strap's current HR, or nil when it has stopped supplying one — in
    /// which case the caller falls through to Tier 2/3.
    ///
    /// Diagnostic logging. User report: "Both tier-1 and
    /// tier-2 failed in the 60–120s window." Failing silently —
    /// `0 samples` in the workout-stop log with no indication of which tier
    /// failed or why — is useless. Each exit names itself, so a failure log
    /// tells us strap-dropped vs strap-streaming-but-buffer-empty vs auth.
    ///
    /// These are NOT `.warning` (which surfaces as "Recent Problems" in
    /// Troubleshooting); users find that confusing — they're not
    /// actionable. The strap not being connected / not streaming post-workout
    /// is often expected (user dismissed the summary and Polar disconnected;
    /// user wasn't wearing the strap). HRR capture failing because there's no
    /// data source isn't an app malfunction, so they log at `.info`.
    private func strapHR(at target: Int) -> Int? {
        guard polarManager.connectionState == .connected else {
            debugLog("[HRRCaptureService] tier 1 — strap not connected at +\(target)s (state=\(polarManager.connectionState)), breaking")
            return nil
        }
        guard polarManager.isStreaming else {
            debugLog("[HRRCaptureService] tier 1 — strap connected but not streaming at +\(target)s, breaking")
            return nil
        }

        guard let hr = currentHRFromBuffer() else {
            debugLog("[HRRCaptureService] tier 1 — strap streaming but RR buffer empty/invalid at +\(target)s (buffer count=\(polarManager.streamedRRPoints.count)), breaking", level: .warning)
            return nil
        }
        return hr
    }

    /// Median HR over the tail of the Polar streaming buffer. Matches
    /// what WorkoutRecorder uses for its live HR display — single-beat
    /// HR from raw rr_ms swings 40-140 from the same heart rate, but
    /// the median of the last ~8 beats reads like a real HR.
    private func currentHRFromBuffer() -> Int? {
        let recent = polarManager.streamedRRPoints.suffix(8).filter { $0.rr_ms > 0 }
        guard !recent.isEmpty else { return nil }
        let sorted = recent.map { Double($0.rr_ms) }.sorted()
        let median = sorted.count.isMultiple(of: 2)
            ? (sorted[sorted.count / 2 - 1] + sorted[sorted.count / 2]) / 2
            : sorted[sorted.count / 2]
        // Defensive: median should be > 0 since rr_ms > 0 was filtered,
        // but a corrupt sample with negative rr_ms is theoretically
        // representable. Guard against it before the division so we
        // can't trap on `Int(.infinity)`.
        guard median.isFinite, median > 50 else { return nil }
        let bpm = 60_000.0 / median
        guard bpm.isFinite, bpm > 20, bpm < 250 else { return nil }
        return Int(bpm)
    }

    // MARK: - Tier 2 — Apple Watch HR samples

    private func captureWatchSamples(stopDate: Date, peakHR: Int) async -> [HRRSample] {
        guard HKHealthStore.isHealthDataAvailable() else {
            debugLog("[HRRCaptureService] tier 2 — HKHealthStore not available on this device", level: .warning)
            return []
        }
        let samples = await watchHeartRateSamples(stopDate: stopDate)
        guard !samples.isEmpty else { return [] }
        return watchHRRSamples(from: samples, stopDate: stopDate, peakHR: peakHR)
    }

    /// Every HK heart-rate sample in the post-workout window.
    ///
    /// The read-auth status is logged explicitly. HK's
    /// `authorizationStatus(for:)` on a READ type only tells us if the user
    /// explicitly DENIED; it returns `notDetermined` even when access has been
    /// granted (Apple's privacy quirk). So an empty result set can mean (a)
    /// auth never requested, (b) auth denied, or (c) auth granted but no Watch
    /// HR samples — logging the status narrows the diagnosis.
    ///
    /// The empty-result log is deliberately not `.warning`: as a "Recent
    /// Problems" entry it is confusing, because no HK HR samples in
    /// the post-workout window is the common case for users without a Watch,
    /// not an error.
    private func watchHeartRateSamples(stopDate: Date) async -> [HKQuantitySample] {
        let start = stopDate
        let end = stopDate.addingTimeInterval(TimeInterval(captureWindowSec) + 15)
        let hrType = HKQuantityType(.heartRate)
        let authStatus = healthKit.healthStore.authorizationStatus(for: hrType)
        debugLog("[HRRCaptureService] tier 2 — HR read auth status=\(authStatus.rawValue) (0=notDetermined, 1=denied, 2=granted)")
        let samples = await runHeartRateQuery(type: hrType, start: start, end: end)
        if samples.isEmpty {
            debugLog("[HRRCaptureService] tier 2 — no HK heart-rate samples in [\(start), \(end)]. Likely: Watch not worn, HR read auth not granted, or Watch hasn't synced yet.")
        }
        return samples
    }

    private func runHeartRateQuery(type hrType: HKQuantityType, start: Date, end: Date) async -> [HKQuantitySample] {
        let predicate = HKQuery.predicateForSamples(withStart: start, end: end)
        let samples: [HKQuantitySample] = await healthKit.runBoundedQuery(timeout: HealthKitManager.hrvQueryTimeoutSec) { resolve in
            HKSampleQuery(
                sampleType: hrType,
                predicate: predicate,
                limit: HKObjectQueryNoLimit,
                sortDescriptors: [NSSortDescriptor(key: HKSampleSortIdentifierStartDate, ascending: true)]
            ) { _, results, error in
                resolve(Self.quantitySamples(results, error))
            }
        } ?? []
        return samples
    }

    /// A query error degrades to no samples — tier 2 is a fallback, so it
    /// reports nothing rather than failing the capture.
    nonisolated private static func quantitySamples(_ results: [HKSample]?, _ error: Error?) -> [HKQuantitySample] {
        if let error {
            debugLog("[HRRCaptureService] tier 2 — HK query error: \(error.localizedDescription)", level: .warning)
        }
        return (results as? [HKQuantitySample]) ?? []
    }

    /// The nearest HK sample to each target offset, rejecting anything more
    /// than 15 s away — the Watch's passive sampling can be sparse during rest.
    private func watchHRRSamples(
        from samples: [HKQuantitySample],
        stopDate: Date,
        peakHR: Int
    ) -> [HRRSample] {
        let bpmUnit = HKUnit(from: "count/min")
        var results: [HRRSample] = []
        var rejectedTooFar = 0
        for target in [60, 120] where target <= captureWindowSec {
            let targetTime = stopDate.addingTimeInterval(TimeInterval(target))
            guard let nearest = samples.min(by: {
                abs($0.startDate.timeIntervalSince(targetTime)) < abs($1.startDate.timeIntervalSince(targetTime))
            }) else { continue }
            guard abs(nearest.startDate.timeIntervalSince(targetTime)) <= 15 else {
                rejectedTooFar += 1
                continue
            }
            let hr = Int(nearest.quantity.doubleValue(for: bpmUnit).rounded())
            results.append(HRRSample(offsetSec: target, hr: hr, drop: peakHR - hr, peakHR: peakHR, provenance: .watchSamples))
        }
        if results.isEmpty, rejectedTooFar > 0 {
            debugLog("[HRRCaptureService] tier 2 — \(samples.count) HK samples present but all >15s from target offsets (\(rejectedTooFar) rejected)")
        }
        return results
    }

    // MARK: - Tier 3 — Apple's computed heartRateRecoveryOneMinute

    private func captureAppleHealthKitHRR(stopDate: Date, peakHR: Int) async -> HRRSample? {
        guard HKHealthStore.isHealthDataAvailable() else { return nil }
        guard let sample = await appleCardioRecoverySample(stopDate: stopDate) else { return nil }
        // Apple encodes the sample as a drop in BPM over 1 minute.
        let drop = Int(sample.quantity.doubleValue(for: HKUnit(from: "count/min")).rounded())
        return HRRSample(
            offsetSec: 60,
            hr: max(0, peakHR - drop),
            drop: drop,
            peakHR: peakHR,
            provenance: .healthKitComputed
        )
    }

    /// Apple's cardio recovery sample is attached to a workout, so it is looked
    /// for in a ±5 minute window around the stop.
    private func appleCardioRecoverySample(stopDate: Date) async -> HKQuantitySample? {
        let type = HKQuantityType(.heartRateRecoveryOneMinute)
        let predicate = HKQuery.predicateForSamples(
            withStart: stopDate.addingTimeInterval(-5 * 60),
            end: stopDate.addingTimeInterval(5 * 60)
        )
        let samples: [HKQuantitySample] = await healthKit.runBoundedQuery(timeout: HealthKitManager.hrvQueryTimeoutSec) { resolve in
            HKSampleQuery(
                sampleType: type,
                predicate: predicate,
                limit: 1,
                sortDescriptors: [NSSortDescriptor(key: HKSampleSortIdentifierStartDate, ascending: false)]
            ) { _, results, _ in
                resolve((results as? [HKQuantitySample]) ?? [])
            }
        } ?? []
        return samples.first
    }
}
