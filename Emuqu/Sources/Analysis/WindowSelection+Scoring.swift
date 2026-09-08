import Foundation

// Selector configuration and the scoring rules: temporal representativeness,
// stability weighting, spike filtering. The organization metrics live in
// `WindowSelection.swift`.

extension WindowSelector {
    // MARK: - Configuration

    struct Config {
        /// Number of beats per analysis window (400 beats ≈ 6-7 min at 60bpm)
        var beatsPerWindow: Int = 400
        /// Sliding window step in beats
        var slideStepBeats: Int = 40
        /// **Preferred** maximum artifact rate for a valid block.
        ///
        /// The literature converges on 10% as the upper bound for
        /// reliable HRV analysis with modern artifact correction:
        ///   - Plews et al. 2013 (NJSAM) — ultra-short-term HRV
        ///     reliability collapses past ~5% uncorrected, ~10% with
        ///     correction.
        ///   - Lipponen & Tarvainen 2019 (Front Physiol) — Kubios's
        ///     adaptive correction stays accurate to ~8-10% beat-loss.
        ///   - Citi et al. 2012 (Front Physiol) — point-process methods
        ///     hold up to ~10%.
        ///   - Berntson et al. 1997 (Psychophysiology) — degradation
        ///     begins at ~5% even with correction.
        ///
        /// We prefer windows below this strict bound.
        /// Most overnight sessions have plenty of <10% windows, so the
        /// stricter cutoff just routes around the noisier slices.
        var maxArtifactRateStrict: Double = 0.10
        /// **Fallback** maximum artifact rate. When the strict pass
        /// yields zero organized-recovery windows (genuinely noisy
        /// strap night — strap shifted, lots of motion, electrode
        /// dried out), we relax to 15% so the user gets *some* result
        /// rather than nil. The HRVDetailV2View artifact banner
        /// surfaces the actual rate so the user knows the reading is
        /// degraded, but only when the strict pass failed AND we used
        /// a fallback window above 10%.
        var maxArtifactRate: Double = 0.15
        /// Minimum clean beats required for analysis (300 = 75% of 400)
        var minCleanBeats: Int = 300
        /// Ectopic beat detection threshold: 20% deviation from local median
        /// Based on research: 20-25% is standard (Kubios, PMC3268104)
        var ectopicThresholdPercent: Double = 0.20
        /// Number of surrounding beats for local median calculation
        var localMedianWindow: Int = 10

        // MARK: - Temporal Representativeness Constraints

        /// Minimum relative position within sleep episode (0.0 = sleep start, 1.0 = wake)
        /// Windows before this threshold are excluded to avoid early-night NREM spikes
        var minRelativePosition: Double = 0.30
        /// Maximum relative position within sleep episode
        /// Windows after this threshold are excluded to avoid late-night REM/arousal periods
        var maxRelativePosition: Double = 0.70
        /// Whether to enforce temporal position constraints
        /// When true, windows outside the allowed band are excluded even if physiologically valid
        var enforceTemporalConstraints: Bool = true

        // MARK: - Stability Weighting

        /// Weight given to HR stability when scoring windows (0 = ignore stability, higher = more weight)
        /// At 10.0: a window with 10% CV has ~50% penalty vs a perfectly stable window
        /// This ensures we select sustained recovery, not transient peaks
        var stabilityWeight: Double = 10.0

        // MARK: - Spike Filtering

        /// Ratio at which a window's RMSSD must exceed BOTH neighbors to
        /// be classified as an isolated spike and rejected by
        /// `filterIsolatedSpikes`. 1.50 = ≥150% of neighbour RMSSD.
        /// A named constant rather than an inline literal so the
        /// scoring decision is visible to tests and tunable per call.
        var isolatedSpikeRatio: Double = 1.50

        static let `default` = Config()
    }

    // MARK: - Main Window Selection

    func findBestWindow(
        in series: RRSeries,
        flags: [ArtifactFlags],
        sleepStartMs: Int64? = nil,
        wakeTimeMs: Int64? = nil,
        baselineStats: BaselineTracker.RecoveryBaselineStats? = nil
    ) -> RecoveryWindow? {
        guard let (boundaries, band) = searchBand(
            points: series.points, sleepStartMs: sleepStartMs, wakeTimeMs: wakeTimeMs
        ) else { return nil }
        let allWindows = scanBandWithArtifactFallback(
            series: series, flags: flags, band: band, boundaries: boundaries
        )
        guard !allWindows.isEmpty else { return nil }
        return selectOrganizedWindow(from: allWindows, baselineStats: baselineStats)
    }

    /// Below this the night is too short for a 30-70% band to mean anything.
    private static let minRequiredBeats = 120

    /// Resolves the night's boundaries and the slice of it worth searching,
    /// logging each step. Nil means there is nothing to search.
    private func searchBand(
        points: [RRPoint],
        sleepStartMs: Int64?,
        wakeTimeMs: Int64?
    ) -> (SleepBoundaries, SearchBand)? {
        // Clear any zones from a previous call — avoids stale data bleeding
        // into this result if we bail out early or find no organized windows.
        lastOrganizedZones = []
        guard points.count >= Self.minRequiredBeats else {
            debugLog("[WindowSelector] Insufficient beats: \(points.count) < \(Self.minRequiredBeats)")
            return nil
        }
        guard let boundaries = resolveSleepBoundaries(
            points: points, sleepStartMs: sleepStartMs, wakeTimeMs: wakeTimeMs
        ) else {
            debugLog("[WindowSelector] No points in series")
            return nil
        }
        logBoundaryResolution(sleepStartMs: sleepStartMs, wakeTimeMs: wakeTimeMs, boundaries: boundaries)
        guard let band = findSearchBand(points: points, boundaries: boundaries) else {
            debugLog("[WindowSelector] Could not find valid indices in temporal band")
            return nil
        }
        logSearchBandDetails(band: band, boundaries: boundaries, points: points)
        return (boundaries, band)
    }

    /// STEP 1: build all windows within the 30-70% band.
    ///
    /// **Two-pass artifact filter.** The literature
    /// converges on 10% as the upper bound for reliable HRV under adaptive
    /// correction (Plews 2013, Lipponen & Tarvainen 2019, Citi 2012). Most
    /// overnight sessions have plenty of <10% windows even when noisier slices
    /// exist — we'd rather route around the noise than choose a 14% window and
    /// warn the user to "redo the reading."
    ///
    /// Pass 1 (strict, <=10%) is preferred. Pass 2 (permissive, <=15%) is a
    /// fallback only when the strict pass yields nothing — for genuinely noisy
    /// nights (strap shifted, loose electrode) where the relaxed-then-flagged
    /// result still beats no result at all.
    private func scanBandWithArtifactFallback(
        series: RRSeries,
        flags: [ArtifactFlags],
        band: SearchBand,
        boundaries: SleepBoundaries
    ) -> [ScoredRecoveryBlock] {
        let strictWindows = scanWindowsInBand(
            series: series, flags: flags, band: band, boundaries: boundaries,
            artifactRateLimit: config.maxArtifactRateStrict
        )
        let usedStrict = !strictWindows.isEmpty
        let allWindows: [ScoredRecoveryBlock] = usedStrict
            ? strictWindows
            : scanWindowsInBand(
                series: series, flags: flags, band: band, boundaries: boundaries,
                artifactRateLimit: config.maxArtifactRate
            )
        if !usedStrict, !allWindows.isEmpty {
            debugLog("[WindowSelector] Strict 10% pass yielded zero windows — fell back to 15% permissive pass (this night is genuinely noisy)")
        }
        guard !allWindows.isEmpty else {
            debugLog("[WindowSelector] No valid windows found in 30-70% band even at 15% permissive cutoff")
            return []
        }
        return allWindows
    }

    /// STEP 2: an organized-looking window no neighbour supports is noise.
    private func withoutIsolatedSpikes(_ allWindows: [ScoredRecoveryBlock]) -> [ScoredRecoveryBlock] {
        // STEP 2: Filter isolated spikes (single pass)
        debugLog("[WindowSelector] STEP 2: Filtering isolated spikes (temporal discontinuity)...")
        let (filteredWindows, rejectedCount) = filterIsolatedSpikes(allWindows)
        debugLog("[WindowSelector] \(filteredWindows.count) valid windows (\(rejectedCount) isolated spikes filtered)")
        if rejectedCount > 0 {
            debugLog("[WindowSelector] Rejected \(rejectedCount) isolated spikes (temporal discontinuity)")
        }
        return filteredWindows
    }

    /// STEPS 3-4: keep the organized windows and build a recovery window from
    /// what survives.
    private func selectOrganizedWindow(
        from allWindows: [ScoredRecoveryBlock],
        baselineStats: BaselineTracker.RecoveryBaselineStats?
    ) -> RecoveryWindow? {
        let filteredWindows = withoutIsolatedSpikes(allWindows)
        // STEP 3: Classify and select best organized window
        let candidateWindows = filteredWindows.isEmpty ? allWindows : filteredWindows
        let organizedWindows = candidateWindows.filter(\.isOrganizedRecovery)
        let highVariabilityCount = candidateWindows.count - organizedWindows.count
        debugLog("[WindowSelector] Found \(organizedWindows.count) organized windows, \(highVariabilityCount) high-variability windows")

        captureOrganizedZones(organizedWindows)

        guard !organizedWindows.isEmpty else {
            debugLog("[WindowSelector] STEP 4: NO ORGANIZED WINDOWS - No consolidated recovery detected")
            debugLog("[WindowSelector] High-variability windows exist but none classified as organized")
            debugLog("[WindowSelector] Returning nil - peak capacity will be captured separately")
            return nil
        }
        return buildRecoveryWindow(
            from: organizedWindows,
            sustainedWindows: filteredWindows,
            baselineStats: baselineStats
        )
    }

    /// Merge adjacent/overlapping organized windows into contiguous ranges for
    /// the chart overlay.
    private func captureOrganizedZones(_ organizedWindows: [ScoredRecoveryBlock]) {
        lastOrganizedZones = Self.mergeAdjacentZones(
            organizedWindows.map { HRVAnalysisResult.TimeRange(startMs: $0.startMs, endMs: $0.endMs) }
        )
    }

    // MARK: - findBestWindow Helpers

    func logBoundaryResolution(sleepStartMs: Int64?, wakeTimeMs: Int64?, boundaries: SleepBoundaries) {
        if let sleepStart = sleepStartMs, sleepStart >= 0 {
            debugLog("[WindowSelector] Sleep started \(sleepStart / 60000) min after recording began (pre-sleep excluded)")
        } else {
            debugLog("[WindowSelector] No HealthKit sleep start, using recording start")
        }
        if let wake = wakeTimeMs, wake > boundaries.actualSleepStartMs {
            if wake > boundaries.recordingDurationMs {
                debugLog("[WindowSelector] Wake time (\(wake / 60000) min) extends past recording, capping at recording end")
            } else {
                debugLog("[WindowSelector] Using HealthKit wake time: \(wake / 60000) min from recording start")
            }
        } else {
            debugLog("[WindowSelector] No valid HealthKit wake time, using recording end")
        }
        debugLog("[WindowSelector] ========== WINDOW SELECTION DEBUG ==========")
        debugLog("[WindowSelector] Recording: 0 to \(formatTime(boundaries.recordingDurationMs)) (\(boundaries.recordingDurationMs / 60000) min)")
        debugLog("[WindowSelector] Actual sleep: \(boundaries.actualSleepStartMs / 60000) min to \(boundaries.actualSleepEndMs / 60000) min (duration: \(boundaries.actualSleepDurationMs / 60000) min)")
    }

    func logSearchBandDetails(band: SearchBand, boundaries: SleepBoundaries, points: [RRPoint]) {
        let limitEarlyMs = boundaries.actualSleepStartMs + Int64(Double(boundaries.actualSleepDurationMs) * config.minRelativePosition)
        let limitLateMs = boundaries.actualSleepStartMs + Int64(Double(boundaries.actualSleepDurationMs) * config.maxRelativePosition)
        debugLog("[WindowSelector] 30-70% band of sleep: \(limitEarlyMs / 60000) min to \(limitLateMs / 60000) min (session-relative)")
        debugLog("[WindowSelector] Effective search range: \(band.effectiveLimitEarlyMs / 60000) min to \(band.effectiveLimitLateMs / 60000) min (clamped to recording)")

        let (adaptiveWindowSize, _) = computeAdaptiveWindowSize(beatsAvailable: band.beatsInBand)
        let bandDurationMs = band.effectiveLimitLateMs - band.effectiveLimitEarlyMs
        let bandDurationMinutes = Double(bandDurationMs) / 60000.0
        let averageBPM = bandDurationMinutes > 0 ? Double(band.beatsInBand) / bandDurationMinutes : 60.0
        debugLog("[WindowSelector] STEP 1: Building all windows in 30-70% band...")
        debugLog("[WindowSelector] Band indices: \(band.startIdx) to \(band.endExclusive - 1) (of \(points.count) total points)")
        debugLog("[WindowSelector] Band timestamps: \(points[band.startIdx].t_ms / 60000) min to \(points[band.endExclusive - 1].t_ms / 60000) min")
        debugLog("[WindowSelector] Band: \(String(format: "%.1f", bandDurationMinutes)) min, \(band.beatsInBand) beats")
        debugLog("[WindowSelector] Window size: \(adaptiveWindowSize) beats (~\(String(format: "%.1f", Double(adaptiveWindowSize) / averageBPM)) min)")
    }

    func scanWindowsInBand(
        series: RRSeries, flags: [ArtifactFlags],
        band: SearchBand, boundaries: SleepBoundaries,
        artifactRateLimit: Double? = nil
    ) -> [ScoredRecoveryBlock] {
        let (adaptiveWindowSize, stepSize) = computeAdaptiveWindowSize(beatsAvailable: band.beatsInBand)
        return scanWindows(
            series: series, flags: flags,
            grid: ScanGrid(
                bandStart: band.startIdx, bandEnd: band.endExclusive,
                windowSize: adaptiveWindowSize, stepSize: stepSize
            ),
            sessionStartMs: boundaries.actualSleepStartMs,
            sessionEndMs: boundaries.actualSleepEndMs,
            artifactRateLimit: artifactRateLimit
        )
    }

    /// Select best organized window and build the final RecoveryWindow result.
    ///
    /// When `baselineStats` is provided, each organized window is scored with
    /// `RecoveryScoreCalculator.calculateTier1` and the highest-scoring window
    /// is selected. A "highest RMSSD wins" heuristic picks windows that the
    /// scorer then plateaus (e.g., RMSSD 53 scoring 80 vs. RMSSD 45 scoring
    /// 85 on the same session — the plateau mapping at z > +0.5 makes
    /// above-baseline RMSSD non-monotonic).
    ///
    /// When baseline is nil (e.g., first session, baseline not yet built), we
    /// fall back to RMSSD ranking.
    func buildRecoveryWindow(
        from organizedWindows: [ScoredRecoveryBlock],
        sustainedWindows: [ScoredRecoveryBlock],
        baselineStats: BaselineTracker.RecoveryBaselineStats? = nil
    ) -> RecoveryWindow? {
        let sortedOrganized = baselineStats.map { rankByTier1Score(organizedWindows, baseline: $0) }
            ?? rankByRMSSD(organizedWindows)
        guard let finalBlock = sortedOrganized.first else { return nil }
        debugLog("[WindowSelector] STEP 4: Selected from \(organizedWindows.count) ORGANIZED windows")
        return recoveryWindow(from: finalBlock, sustainedWindows: sustainedWindows)
    }

    /// Ranks by Tier 1 recovery score, then RMSSD, then position — so two
    /// windows that score identically resolve deterministically.
    private func rankByTier1Score(
        _ organizedWindows: [ScoredRecoveryBlock],
        baseline: BaselineTracker.RecoveryBaselineStats
    ) -> [ScoredRecoveryBlock] {
        let scored: [(block: ScoredRecoveryBlock, score: Double)] = organizedWindows.map { block in
            let score = RecoveryScoreCalculator.calculateTier1(
                rmssd: block.rmssd, meanHR: block.meanHR, dfaAlpha1: block.dfaAlpha1,
                baselineStats: baseline, readiness: nil
            )
            return (block, score)
        }
        logWindowRanking(scored, count: organizedWindows.count)
        return scored.sorted { a, b in
            if a.score != b.score { return a.score > b.score }
            if a.block.rmssd != b.block.rmssd { return a.block.rmssd > b.block.rmssd }
            return a.block.relativePosition > b.block.relativePosition
        }.map(\.block)
    }

    /// One multi-line entry so the whole ranking lands in the log atomically —
    /// a previous per-iteration debugLog with String(format:) and %@ for
    /// optional Swift strings was dropping lines silently on some builds.
    ///
    /// When users report "auto picked the wrong window", this trace shows
    /// exactly which window scored what.
    private func logWindowRanking(_ scored: [(block: ScoredRecoveryBlock, score: Double)], count: Int) {
        let sortedScored = scored.sorted { $0.score > $1.score }
        var lines: [String] = []
        lines.append("[WindowRank] Ranking \(count) organized windows by Tier 1 score:")
        for (idx, entry) in sortedScored.enumerated() {
            let b = entry.block
            let alpha = b.dfaAlpha1.map { String(format: "%.2f", $0) } ?? "nil"
            let lfhf = b.lfHfRatio.map { String(format: "%.2f", $0) } ?? "nil"
            let tier1 = String(format: "%.1f", entry.score)
            let rmssd = String(format: "%.1f", b.rmssd)
            let sdnn = String(format: "%.1f", b.sdnn)
            let hr = String(format: "%.0f", b.meanHR)
            let cv = String(format: "%.1f", b.hrCV * 100)
            let pos = String(format: "%.0f", b.relativePosition * 100)
            let minute = Int(b.startMs / 60000)
            lines.append("[WindowRank] #\(idx + 1) tier1=\(tier1) rmssd=\(rmssd) sdnn=\(sdnn) meanHR=\(hr) dfa=\(alpha) lfhf=\(lfhf) cv=\(cv)% pos=\(pos)% @\(minute)min")
        }
        lines.append("[WindowRank] NOTE: Tier 1 above excludes ANS balance (pns-sns); composite may shift ±3 to ±6.")
        debugLog(lines.joined(separator: "\n"))
    }

    private func rankByRMSSD(_ organizedWindows: [ScoredRecoveryBlock]) -> [ScoredRecoveryBlock] {
        let sortedOrganized = organizedWindows.sorted { w1, w2 in
            if w1.rmssd != w2.rmssd { return w1.rmssd > w2.rmssd }
            return w1.relativePosition > w2.relativePosition
        }
        debugLog("[WindowSelector] No baseline — falling back to RMSSD ranking")
        return sortedOrganized
    }

    private func recoveryWindow(from finalBlock: ScoredRecoveryBlock, sustainedWindows: [ScoredRecoveryBlock]) -> RecoveryWindow {
        let isSustained = sustainedWindows.contains { $0.startIndex == finalBlock.startIndex }
        let isConsolidated = isSustained && finalBlock.hrCV < RecoveryWindow.unstableCVThreshold
        logSelectedWindow(
            finalBlock: finalBlock,
            positionPercent: Int(finalBlock.relativePosition * 100),
            isConsolidated: isConsolidated
        )
        return RecoveryWindow(
            startIndex: finalBlock.startIndex, endIndex: finalBlock.endIndex,
            startMs: finalBlock.startMs, endMs: finalBlock.endMs,
            beatCount: finalBlock.endIndex - finalBlock.startIndex,
            nnCount: finalBlock.cleanBeatCount,
            qualityScore: finalBlock.rmssd / 100.0, artifactRate: finalBlock.artifactRate,
            meanHR: finalBlock.meanHR, hrStability: finalBlock.hrCV,
            selectionReason: selectionReason(for: finalBlock),
            relativePosition: finalBlock.relativePosition,
            recoveryScore: finalBlock.recoveryScore(stabilityWeight: config.stabilityWeight), isConsolidated: isConsolidated,
            dfaAlpha1: finalBlock.dfaAlpha1, lfHfRatio: finalBlock.lfHfRatio,
            isOrganizedRecovery: true, windowClassification: finalBlock.classification
        )
    }

    /// The human-readable "why this window" line stored on the result.
    private func selectionReason(for finalBlock: ScoredRecoveryBlock) -> String {
        let alpha1Str = finalBlock.dfaAlpha1.map { String(format: "%.2f", $0) } ?? "N/A"
        let cvPercent = finalBlock.hrCV * 100
        let positionPercent = Int(finalBlock.relativePosition * 100)
        let reason = "Organized Recovery (RMSSD \(String(format: "%.1f", finalBlock.rmssd)) ms, α1=\(alpha1Str), CV \(String(format: "%.1f", cvPercent))%) at \(positionPercent)%"
        return reason
    }

    func logSelectedWindow(finalBlock: ScoredRecoveryBlock, positionPercent: Int, isConsolidated: Bool) {
        let minPos = Int(config.minRelativePosition * 100)
        let maxPos = Int(config.maxRelativePosition * 100)
        if positionPercent < minPos || positionPercent > maxPos {
            debugLog("[WindowSelector] WARNING: Selected window at \(positionPercent)% is outside \(minPos)-\(maxPos)% band!")
            debugLog("[WindowSelector] Window timestamps: \(finalBlock.startMs / 60000) min to \(finalBlock.endMs / 60000) min")
        }
        debugLog("[WindowSelector] ========== CONSOLIDATED RECOVERY DETECTED ==========")
        debugLog("[WindowSelector] Classification: Organized Recovery")
        debugLog("[WindowSelector] Position: \(positionPercent)%")
        debugLog("[WindowSelector] RMSSD: [redacted]")
        debugLog("[WindowSelector] DFA α1: [redacted]")
        debugLog("[WindowSelector] HR CV: [redacted]")
        debugLog("[WindowSelector] Recovery score: [redacted]")
        debugLog("[WindowSelector] Mean HR: [redacted]")
        debugLog("[WindowSelector] Consolidated: \(isConsolidated)")
        debugLog("[WindowSelector] ====================================================")
    }

    /// Find best recovery window AND compute peak capacity (highest sustained HRV)
    /// These are INDEPENDENT assessments:
    /// - Recovery window: only exists if organized parasympathetic plateau occurred (readiness)
    /// - Peak capacity: highest sustained HRV regardless of organization (physiological ceiling)
    ///
    /// Merge overlapping or adjacent time ranges into contiguous zones.
    /// Adjacent = endMs of one ≥ startMs of the next (windows that touch or overlap).
    static func mergeAdjacentZones(_ zones: [HRVAnalysisResult.TimeRange]) -> [HRVAnalysisResult.TimeRange] {
        guard !zones.isEmpty else { return [] }
        let sorted = zones.sorted { $0.startMs < $1.startMs }
        var merged: [HRVAnalysisResult.TimeRange] = [sorted[0]]
        // `if let last = …` rather than `merged.last!` —
        // merged is guaranteed non-empty (init with sorted[0]) so the optional
        // binding always succeeds; avoiding the `!` keeps the file refactor-
        // spec compliant ("zero magic / no force-unwraps").
        for zone in sorted.dropFirst() {
            if let last = merged.last, zone.startMs <= last.endMs {
                // Overlapping or touching — extend current zone
                _ = merged.removeLast()
                merged.append(HRVAnalysisResult.TimeRange(
                    startMs: last.startMs,
                    endMs: max(last.endMs, zone.endMs)
                ))
            } else {
                merged.append(zone)
            }
        }
        return merged
    }

    /// If no organized recovery occurred, recoveryWindow will be nil but peakCapacity may exist.
    /// This is the correct physiological answer - don't pretend recovery occurred.
    ///
    /// `baselineStats` — when provided, organized-window ranking uses Tier 1
    /// recovery scoring instead of raw RMSSD. See `buildRecoveryWindow` for why.
    func findBestWindowWithCapacity(
        in series: RRSeries,
        flags: [ArtifactFlags],
        sleepStartMs: Int64? = nil,
        wakeTimeMs: Int64? = nil,
        baselineStats: BaselineTracker.RecoveryBaselineStats? = nil
    ) -> WindowSelectionResult? {
        guard series.points.count >= config.beatsPerWindow else { return nil }
        let recoveryWindow = recoveryOrPeakFallback(
            in: series, flags: flags, sleepStartMs: sleepStartMs,
            wakeTimeMs: wakeTimeMs, baselineStats: baselineStats
        )
        guard let peakCapacity = findPeakCapacity(in: series, flags: flags) else {
            // No peak window either — with no recovery window there is nothing
            // to report at all.
            return recoveryWindow == nil ? nil : WindowSelectionResult(recoveryWindow: recoveryWindow, peakCapacity: nil)
        }
        return WindowSelectionResult(recoveryWindow: recoveryWindow, peakCapacity: peakCapacity)
    }

    /// Organized recovery if the night had any; otherwise the peak-RMSSD window,
    /// so we always analyse a narrow ~400-beat slice rather than the whole
    /// recording. The fallback is not marked organized.
    private func recoveryOrPeakFallback(
        in series: RRSeries,
        flags: [ArtifactFlags],
        sleepStartMs: Int64?,
        wakeTimeMs: Int64?,
        baselineStats: BaselineTracker.RecoveryBaselineStats?
    ) -> RecoveryWindow? {
        // Organized recovery first (DFA α1 0.75-1.0 criteria).
        if let organized = findBestWindow(
            in: series, flags: flags, sleepStartMs: sleepStartMs,
            wakeTimeMs: wakeTimeMs, baselineStats: baselineStats
        ) {
            debugLog("[WindowSelector] Consolidated recovery window found")
            return organized
        }
        return peakRMSSDFallback(in: series, flags: flags, sleepStartMs: sleepStartMs, wakeTimeMs: wakeTimeMs)
    }

    private func peakRMSSDFallback(
        in series: RRSeries,
        flags: [ArtifactFlags],
        sleepStartMs: Int64?,
        wakeTimeMs: Int64?
    ) -> RecoveryWindow? {
        debugLog("[WindowSelector] No consolidated recovery - cascading to peak RMSSD fallback")
        let window = findPeakMetricWindow(
            in: series, flags: flags, sleepStartMs: sleepStartMs,
            wakeTimeMs: wakeTimeMs, metric: .rmssd
        )
        if window != nil {
            debugLog("[WindowSelector] Peak RMSSD fallback window found")
        } else {
            debugLog("[WindowSelector] No peak RMSSD window found either — will analyze full session")
        }
        return window
    }

    /// Peak capacity: the highest SUSTAINED RMSSD anywhere in the recording.
    /// Computed independently of the recovery window, with no DFA/LF-HF filter
    /// — artifact-clean and sustained is the whole bar.
    private func findPeakCapacity(in series: RRSeries, flags: [ArtifactFlags]) -> PeakCapacity? {
        let points = series.points
        guard let firstPoint = points.first, let lastPoint = points.last else { return nil }
        let (adaptiveWindowSize, stepSize) = computeAdaptiveWindowSize(beatsAvailable: points.count, compact: true)
        logPeakCapacityScan(points: points, from: firstPoint, to: lastPoint, windowSize: adaptiveWindowSize)
        let allWindows = scanWindows(
            series: series, flags: flags,
            grid: ScanGrid(
                bandStart: 0, bandEnd: points.count,
                windowSize: adaptiveWindowSize, stepSize: stepSize
            ),
            sessionStartMs: firstPoint.t_ms,
            sessionEndMs: lastPoint.t_ms
        )
        let (sustainedWindows, _) = filterIsolatedSpikes(allWindows)
        guard let peakWindow = sustainedWindows.max(by: { $0.rmssd < $1.rmssd }) else { return nil }
        debugLog("[WindowSelector] Peak Capacity: window at \(Int(peakWindow.relativePosition * 100))%")
        return peakCapacity(from: peakWindow)
    }

    private func peakCapacity(from peakWindow: ScoredRecoveryBlock) -> PeakCapacity {
        PeakCapacity(
            peakRMSSD: peakWindow.rmssd,
            peakSDNN: peakWindow.sdnn,
            peakTotalPower: nil,
            windowDurationMinutes: Double(peakWindow.endMs - peakWindow.startMs) / 60_000.0,
            windowRelativePosition: peakWindow.relativePosition,
            windowMeanHR: peakWindow.meanHR
        )
    }

    private func logPeakCapacityScan(points: [RRPoint], from firstPoint: RRPoint, to lastPoint: RRPoint, windowSize: Int) {
        let recordingDurationMinutes = Double(lastPoint.t_ms - firstPoint.t_ms) / 60_000.0
        let averageBPM = recordingDurationMinutes > 0 ? Double(points.count) / recordingDurationMinutes : 60.0
        debugLog("[WindowSelector] Peak capacity scan: \(String(format: "%.1f", recordingDurationMinutes)) min recording, \(points.count) beats, avg \(String(format: "%.0f", averageBPM)) bpm")
        debugLog("[WindowSelector] Window size: \(windowSize) beats (~\(String(format: "%.1f", Double(windowSize) / max(averageBPM, 1))) min)")
    }

    // MARK: - Method-Based Window Selection

    /// Select window using a specific method
    /// - Parameters:
    ///   - method: The selection method to use
    ///   - series: RR interval series
    ///   - flags: Artifact flags for each point
    ///   - sleepStartMs: Optional sleep start time from HealthKit
    ///   - wakeTimeMs: Optional wake time from HealthKit
    /// - Returns: Recovery window selected by the specified method, or nil if unavailable
    func selectWindowByMethod(
        _ method: WindowSelectionMethod,
        in series: RRSeries,
        flags: [ArtifactFlags],
        sleepStartMs: Int64? = nil,
        wakeTimeMs: Int64? = nil
    ) -> RecoveryWindow? {
        switch method {
        case .consolidatedRecovery:
            // Use existing algorithm: highest RMSSD among organized windows
            findBestWindow(in: series, flags: flags, sleepStartMs: sleepStartMs, wakeTimeMs: wakeTimeMs)
        case .peakRMSSD:
            // Find window with highest RMSSD (no organization filtering)
            findPeakMetricWindow(in: series, flags: flags, sleepStartMs: sleepStartMs, wakeTimeMs: wakeTimeMs, metric: .rmssd)
        case .peakSDNN:
            // Find window with highest SDNN
            findPeakMetricWindow(in: series, flags: flags, sleepStartMs: sleepStartMs, wakeTimeMs: wakeTimeMs, metric: .sdnn)
        case .peakTotalPower:
            // Find window with highest total spectral power
            findPeakMetricWindow(in: series, flags: flags, sleepStartMs: sleepStartMs, wakeTimeMs: wakeTimeMs, metric: .totalPower)
        case .custom:
            // Custom requires manual positioning - not automatic
            nil
        }
    }

    /// Metric to optimize for in peak window selection
    enum OptimizationMetric {
        case rmssd
        case sdnn
        case totalPower
    }

    /// Find window with peak value of a specific metric
    func findPeakMetricWindow(
        in series: RRSeries,
        flags: [ArtifactFlags],
        sleepStartMs: Int64?,
        wakeTimeMs: Int64?,
        metric: OptimizationMetric
    ) -> RecoveryWindow? {
        guard let (boundaries, band) = peakSearchBand(
            points: series.points, sleepStartMs: sleepStartMs, wakeTimeMs: wakeTimeMs
        ) else { return nil }
        logPeakBandDetails(metric: metric, band: band)
        let allWindows = scanPeakBand(series: series, flags: flags, band: band, boundaries: boundaries)
        guard !allWindows.isEmpty else { return nil }
        let (sustained, _) = filterIsolatedSpikes(allWindows)
        let candidateWindows = sustained.isEmpty ? allWindows : sustained
        guard let finalBlock = selectPeakBlock(from: candidateWindows, metric: metric) else {
            debugLog("[WindowSelector] No valid windows found")
            return nil
        }
        return buildPeakRecoveryWindow(finalBlock: finalBlock, metric: metric)
    }

    private func peakSearchBand(
        points: [RRPoint],
        sleepStartMs: Int64?,
        wakeTimeMs: Int64?
    ) -> (SleepBoundaries, SearchBand)? {
        guard points.count >= 120 else {
            debugLog("[WindowSelector] Insufficient beats: \(points.count) < 120")
            return nil
        }
        guard let boundaries = resolveSleepBoundaries(points: points, sleepStartMs: sleepStartMs, wakeTimeMs: wakeTimeMs) else {
            debugLog("[WindowSelector] No points in series")
            return nil
        }
        guard let band = findSearchBand(points: points, boundaries: boundaries) else {
            debugLog("[WindowSelector] Could not find valid indices in temporal band")
            return nil
        }
        return (boundaries, band)
    }

    /// Same two-pass strict->permissive cutoff as `findBestWindow`.
    private func scanPeakBand(
        series: RRSeries,
        flags: [ArtifactFlags],
        band: SearchBand,
        boundaries: SleepBoundaries
    ) -> [ScoredRecoveryBlock] {
        // Same two-pass strict→permissive cutoff as findBestWindow.
        let strict = scanWindowsInBand(
            series: series, flags: flags, band: band, boundaries: boundaries,
            artifactRateLimit: config.maxArtifactRateStrict
        )
        let allWindows: [ScoredRecoveryBlock] = strict.isEmpty
            ? scanWindowsInBand(
                series: series, flags: flags, band: band, boundaries: boundaries,
                artifactRateLimit: config.maxArtifactRate
            )
            : strict
        guard !allWindows.isEmpty else {
            debugLog("[WindowSelector] No valid windows found in 30-70% band")
            return []
        }
        return allWindows
    }

    // MARK: - findPeakMetricWindow Helpers

    func logPeakBandDetails(metric: OptimizationMetric, band: SearchBand) {
        let bandDurationMs = band.effectiveLimitLateMs - band.effectiveLimitEarlyMs
        let bandDurationMinutes = Double(bandDurationMs) / 60000.0
        let averageBPM = bandDurationMinutes > 0 ? Double(band.beatsInBand) / bandDurationMinutes : 60.0
        let (adaptiveWindowSize, _) = computeAdaptiveWindowSize(beatsAvailable: band.beatsInBand)
        debugLog("[WindowSelector] ========== PEAK \(metric) SELECTION ==========")
        debugLog("[WindowSelector] Band: \(String(format: "%.1f", bandDurationMinutes)) min, \(band.beatsInBand) beats")
        debugLog("[WindowSelector] Window size: \(adaptiveWindowSize) beats (~\(String(format: "%.1f", Double(adaptiveWindowSize) / averageBPM)) min)")
    }

    func selectPeakBlock(from candidates: [ScoredRecoveryBlock], metric: OptimizationMetric) -> ScoredRecoveryBlock? {
        switch metric {
        case .rmssd:
            return candidates.max(by: { $0.rmssd < $1.rmssd })
        case .sdnn, .totalPower:
            if metric == .totalPower {
                debugLog("[WindowSelector] Total power requires frequency analysis - using SDNN as proxy")
            }
            return candidates.max(by: { $0.sdnn < $1.sdnn })
        }
    }

    func buildPeakRecoveryWindow(finalBlock: ScoredRecoveryBlock, metric: OptimizationMetric) -> RecoveryWindow {
        let isOrganized = finalBlock.isOrganizedRecovery
        let isConsolidated = isOrganized && finalBlock.hrCV < RecoveryWindow.unstableCVThreshold
        return RecoveryWindow(
            startIndex: finalBlock.startIndex, endIndex: finalBlock.endIndex,
            startMs: finalBlock.startMs, endMs: finalBlock.endMs,
            beatCount: finalBlock.endIndex - finalBlock.startIndex,
            nnCount: finalBlock.cleanBeatCount,
            qualityScore: finalBlock.rmssd / 100.0, artifactRate: finalBlock.artifactRate,
            meanHR: finalBlock.meanHR, hrStability: finalBlock.hrCV,
            selectionReason: peakSelectionReason(finalBlock: finalBlock, metric: metric),
            relativePosition: finalBlock.relativePosition,
            recoveryScore: finalBlock.recoveryScore(stabilityWeight: config.stabilityWeight),
            isConsolidated: isConsolidated, dfaAlpha1: finalBlock.dfaAlpha1,
            lfHfRatio: finalBlock.lfHfRatio, isOrganizedRecovery: isOrganized,
            windowClassification: finalBlock.classification
        )
    }

    private func peakSelectionReason(finalBlock: ScoredRecoveryBlock, metric: OptimizationMetric) -> String {
        let positionPercent = Int(finalBlock.relativePosition * 100)
        let cvPercent = finalBlock.hrCV * 100
        let alpha1Str = finalBlock.dfaAlpha1.map { String(format: "%.2f", $0) } ?? "N/A"

        let (metricName, metricValue) = peakMetricDescription(finalBlock: finalBlock, metric: metric)
        let reason = "Peak \(metricName) (\(metricValue) ms, α1=\(alpha1Str), CV \(String(format: "%.1f", cvPercent))%) at \(positionPercent)%"

        debugLog("[WindowSelector] Selected window: Peak \(metricName) at \(positionPercent)%")
        debugLog("[WindowSelector] ====================================================")
        return reason
    }

    func peakMetricDescription(finalBlock: ScoredRecoveryBlock, metric: OptimizationMetric) -> (name: String, value: String) {
        switch metric {
        case .rmssd: ("RMSSD", String(format: "%.1f", finalBlock.rmssd))
        case .sdnn: ("SDNN", String(format: "%.1f", finalBlock.sdnn))
        case .totalPower: ("SDNN (Total Power proxy)", String(format: "%.1f", finalBlock.sdnn))
        }
    }

    // MARK: - Manual Window Selection

    /// Analyze at a specific timestamp (for user-selected windows)
    /// Returns the best window centered on the target time, ignoring temporal constraints
    func analyzeAtPosition(
        in series: RRSeries,
        flags: [ArtifactFlags],
        targetMs: Int64
    ) -> RecoveryWindow? {
        let points = series.points
        guard points.count >= config.beatsPerWindow,
              let firstPoint = points.first,
              let lastPoint = points.last
        else {
            debugLog("[WindowSelector] Insufficient beats for manual selection")
            return nil
        }
        guard let (windowStartIdx, windowEndIdx) = manualWindowIndices(points: points, targetMs: targetMs) else { return nil }
        guard let block = evaluateManualWindow(
            series: series, flags: flags,
            startIdx: windowStartIdx, endIdx: windowEndIdx,
            sessionStartMs: firstPoint.t_ms, sessionEndMs: lastPoint.t_ms,
            targetMs: targetMs
        ) else { return nil }
        return manualRecoveryWindow(from: block)
    }

    /// The `beatsPerWindow` slice centred on the tapped time, pulled back from
    /// the end of the recording when centring would overrun it.
    private func manualWindowIndices(points: [RRPoint], targetMs: Int64) -> (Int, Int)? {
        // Find the index closest to target time
        guard let targetIdx = points.firstIndex(where: { $0.t_ms >= targetMs }) else {
            debugLog("[WindowSelector] Target time outside recording range")
            return nil
        }

        // Center window on target
        let halfWindow = config.beatsPerWindow / 2
        var windowStartIdx = max(0, targetIdx - halfWindow)
        var windowEndIdx = windowStartIdx + config.beatsPerWindow

        // Adjust if we hit the end
        if windowEndIdx > points.count {
            windowEndIdx = points.count
            windowStartIdx = max(0, windowEndIdx - config.beatsPerWindow)
        }

        debugLog("[WindowSelector] Manual selection at \(formatTime(targetMs)) -> indices \(windowStartIdx)-\(windowEndIdx)")
        return (windowStartIdx, windowEndIdx)
    }

    /// HONOR the user's explicit pick. This is the "Pick
    /// Window" override, so it must NOT be silently rejected by the same
    /// artifact-rate gate the AUTOMATIC selector uses. On a restless /
    /// artifact-heavy night that gate rejects almost every spot the user
    /// taps → `analyzeAtPosition` returns nil → the UI does nothing →
    /// the "I can't choose my own window" report. Pass a wide-open
    /// artifact limit so the chosen window is accepted; the ≥50-valid-RR
    /// and clean-beat guards inside `evaluateWindow` still return nil only
    /// when the spot genuinely has too little signal to compute HRV from
    /// (rare and honest). The automatic best-recovery path is unchanged.
    private func evaluateManualWindow(
        series: RRSeries,
        flags: [ArtifactFlags],
        startIdx windowStartIdx: Int,
        endIdx windowEndIdx: Int,
        sessionStartMs: Int64,
        sessionEndMs: Int64,
        targetMs: Int64
    ) -> ScoredRecoveryBlock? {
        guard let block = evaluateWindow(
            series: series,
            flags: flags,
            startIdx: windowStartIdx,
            endIdx: windowEndIdx,
            sessionStartMs: sessionStartMs,
            sessionEndMs: sessionEndMs,
            artifactRateLimit: 1.0
        ) else {
            debugLog("[WindowSelector] Manual window has too little usable signal even with the gate relaxed at \(formatTime(targetMs))")
            return nil
        }
        return block
    }

    private func manualRecoveryWindow(from block: ScoredRecoveryBlock) -> RecoveryWindow {
        let isOrganized = block.isOrganizedRecovery
        // Manual selections use organization status for consolidation
        let isConsolidated = isOrganized && block.hrCV < RecoveryWindow.unstableCVThreshold
        return RecoveryWindow(
            startIndex: block.startIndex, endIndex: block.endIndex,
            startMs: block.startMs, endMs: block.endMs,
            beatCount: block.endIndex - block.startIndex,
            nnCount: block.cleanBeatCount,
            qualityScore: block.rmssd / 100.0, artifactRate: block.artifactRate,
            meanHR: block.meanHR, hrStability: block.hrCV,
            selectionReason: manualSelectionReason(for: block),
            relativePosition: block.relativePosition,
            recoveryScore: block.recoveryScore(stabilityWeight: config.stabilityWeight),
            isConsolidated: isConsolidated,
            dfaAlpha1: block.dfaAlpha1, lfHfRatio: block.lfHfRatio,
            isOrganizedRecovery: isOrganized, windowClassification: block.classification
        )
    }

    private func manualSelectionReason(for block: ScoredRecoveryBlock) -> String {
        let positionPercent = Int(block.relativePosition * 100)
        let cvPercent = block.hrCV * 100
        let alpha1Str = block.dfaAlpha1.map { String(format: "%.2f", $0) } ?? "N/A"
        return "Manual selection at \(positionPercent)% (RMSSD \(String(format: "%.1f", block.rmssd)) ms, α1=\(alpha1Str), CV \(String(format: "%.1f", cvPercent))%)"
    }

    // MARK: - Scanning Infrastructure

    /// Resolved sleep boundaries for window selection.
    struct SleepBoundaries {
        let recordingStartMs: Int64
        let recordingEndMs: Int64
        let recordingDurationMs: Int64
        let actualSleepStartMs: Int64
        let actualSleepEndMs: Int64
        var actualSleepDurationMs: Int64 {
            actualSleepEndMs - actualSleepStartMs
        }
    }

    /// Search band within the 30-70% sleep range.
    struct SearchBand {
        let startIdx: Int
        /// End index (exclusive)
        let endExclusive: Int
        let effectiveLimitEarlyMs: Int64
        let effectiveLimitLateMs: Int64
        var beatsInBand: Int {
            endExclusive - startIdx
        }
    }

    /// Resolve actual sleep start/end from optional HealthKit boundaries.
    ///
    /// `sleepStartMs` / `wakeTimeMs` arrive as **wall-clock** offsets from
    /// session start (callers compute `date.timeIntervalSince(startDate) *
    /// 1000`). The scan downstream is indexed in **cumulative-RR** time
    /// (`t_ms`), which STALLS across overnight BLE dropouts — every dropped
    /// beat advances wall time but not `t_ms`. So a wall-clock offset cannot be
    /// compared against `t_ms` directly.
    ///
    /// Treating the wall-clock
    /// wake as if it were `t_ms` and clamping it to the (shorter) `t_ms` span
    /// (`min(wake, recordingDurationMs)`) goes wrong: on any night with dropped beats the
    /// strap's true start→end span is longer than the `t_ms` span, so the wake
    /// boundary is truncated to the compressed end and the 30–70% search band
    /// drifts off the real deep-sleep window. The late-arriving Apple-sleep
    /// reanalysis (which re-runs this with the real boundaries) then lands on a
    /// different, usually higher-HRV window — the "score jumps up after I've
    /// already seen it" the user reports.
    ///
    /// So: translate the wall-clock boundaries onto the recording's own `t_ms`
    /// timeline via each beat's `wallClockMs`, so the band lands on the correct
    /// beats regardless of gaps. H10 internal recording carries no `wallClockMs`
    /// and has no gaps (the strap's own clock is continuous), so the translation
    /// is an identity there and behavior is unchanged on that path — and on any
    /// streaming night with no dropped beats.
    func resolveSleepBoundaries(
        points: [RRPoint],
        sleepStartMs: Int64?,
        wakeTimeMs: Int64?
    ) -> SleepBoundaries? {
        guard let firstPoint = points.first, let lastPoint = points.last else { return nil }
        let recordingStartMs = firstPoint.t_ms
        let recordingEndMs = lastPoint.t_ms
        let recordingDurationMs = recordingEndMs - recordingStartMs

        let actualSleepStartMs: Int64 = sleepStartMs
            .map { max(0, tMsOffset(forWallElapsed: $0, in: points)) } ?? 0

        let actualSleepEndMs = sleepEndOffset(
            wakeTimeMs: wakeTimeMs, points: points,
            after: actualSleepStartMs, recordingDurationMs: recordingDurationMs
        )
        return SleepBoundaries(
            recordingStartMs: recordingStartMs,
            recordingEndMs: recordingEndMs,
            recordingDurationMs: recordingDurationMs,
            actualSleepStartMs: actualSleepStartMs,
            actualSleepEndMs: actualSleepEndMs
        )
    }

    /// A wake boundary that lands at or before the sleep start is unusable —
    /// fall back to the end of the recording rather than an inverted band.
    private func sleepEndOffset(
        wakeTimeMs: Int64?,
        points: [RRPoint],
        after actualSleepStartMs: Int64,
        recordingDurationMs: Int64
    ) -> Int64 {
        guard let wake = wakeTimeMs else { return recordingDurationMs }
        let wakeOffset = tMsOffset(forWallElapsed: wake, in: points)
        return wakeOffset > actualSleepStartMs ? min(wakeOffset, recordingDurationMs) : recordingDurationMs
    }

    /// Map a wall-clock offset (ms from session start) onto the recording's
    /// cumulative-RR (`t_ms`) timeline, as a 0-based offset from the first
    /// beat. Uses each beat's `wallClockMs`: finds the first beat at/after that
    /// wall moment and returns its `t_ms` offset. When the series carries no
    /// wall clock (H10 internal recording — gapless, so `t_ms` already equals
    /// elapsed time), the offset is returned unchanged, so this is a no-op on
    /// that path and on any gap-free streaming night.
    func tMsOffset(forWallElapsed wallElapsedMs: Int64, in points: [RRPoint]) -> Int64 {
        guard let first = points.first else { return wallElapsedMs }
        guard let firstWall = first.wallClockMs else { return wallElapsedMs }
        let targetWall = firstWall + wallElapsedMs
        if let match = points.first(where: { ($0.wallClockMs ?? Int64.min) >= targetWall }) {
            return match.t_ms - first.t_ms
        }
        return (points.last?.t_ms ?? first.t_ms) - first.t_ms
    }

    /// Find the index range for the 30-70% sleep band, clamped to recording boundaries.
    func findSearchBand(
        points: [RRPoint],
        boundaries: SleepBoundaries
    ) -> SearchBand? {
        let limitEarlyMs = boundaries.actualSleepStartMs + Int64(Double(boundaries.actualSleepDurationMs) * config.minRelativePosition)
        let limitLateMs = boundaries.actualSleepStartMs + Int64(Double(boundaries.actualSleepDurationMs) * config.maxRelativePosition)
        let effectiveLimitEarlyMs = max(boundaries.recordingStartMs, limitEarlyMs)
        let effectiveLimitLateMs = min(boundaries.recordingEndMs, limitLateMs)

        guard let startIdx = points.firstIndex(where: { $0.t_ms >= effectiveLimitEarlyMs }),
              let endInclusive = points.lastIndex(where: { $0.t_ms <= effectiveLimitLateMs }),
              endInclusive >= startIdx else { return nil }

        return SearchBand(
            startIdx: startIdx,
            endExclusive: endInclusive + 1,
            effectiveLimitEarlyMs: effectiveLimitEarlyMs,
            effectiveLimitLateMs: effectiveLimitLateMs
        )
    }

    /// Compute adaptive window size based on available beats.
    /// - Parameters:
    ///   - beatsAvailable: Number of beats in the search region.
    ///   - compact: When `true`, uses a tighter strategy for full-recording scans
    ///              (÷3 threshold, 40% fallback) vs band scans (÷2 threshold, 60% fallback).
    func computeAdaptiveWindowSize(beatsAvailable: Int, compact: Bool = false) -> (windowSize: Int, stepSize: Int) {
        let target = config.beatsPerWindow
        let minimum = 120
        let windowSize: Int = if beatsAvailable >= target {
            target
        } else if compact {
            beatsAvailable >= minimum * 3 ? beatsAvailable / 3 : max(60, (beatsAvailable * 2) / 5)
        } else {
            beatsAvailable >= minimum * 2 ? beatsAvailable / 2 : max(60, (beatsAvailable * 3) / 5)
        }
        return (windowSize, max(10, windowSize / 10))
    }
}
