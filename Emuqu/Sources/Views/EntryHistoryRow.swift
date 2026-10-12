import SwiftUI

// MARK: - Entry History Row (uses archive metadata, no disk I/O)

struct EntryHistoryRow: View {
    let entry: SessionArchiveEntry
    let linkedSegmentCount: Int

    private var sessionTypeColor: Color {
        switch entry.sessionType {
        case .overnight: AppTheme.primary
        case .nap: AppTheme.mist
        case .quick: AppTheme.sage
        case .breathe: AppTheme.sdnnColor
        case .workout: AppTheme.terracotta
        }
    }

    var body: some View {
        HStack(spacing: 12) {
            sessionTypeIcon
            timeAndTags
            Spacer()
            rowMetrics

            Image(systemName: "chevron.forward")
                .font(.caption)
                .foregroundColor(AppTheme.textSecondary)
                .accessibilityHidden(true)
        }
        .padding(.vertical, 4)
        .accessibilityElement(children: .combine)
        .accessibilityHint(String(localized: "Double tap to view details", bundle: LanguageManager.appBundle))
    }

    private var sessionTypeIcon: some View {
        // Session type indicator
        Image(systemName: entry.sessionType.icon)
            .font(.title3)
            .foregroundColor(sessionTypeColor)
            .frame(width: 28)
            .accessibilityHidden(true)
    }

    private var timeAndTags: some View {
        // Date and Time
        VStack(alignment: .leading, spacing: 4) {
            timeRow

            Text(entry.displayDate, style: .date)
                .font(.caption)
                .foregroundColor(AppTheme.textSecondary)

            // Tags
            tagChips
        }
    }

    @ViewBuilder
    private var tagChips: some View {
        if !entry.tags.isEmpty {
            tagChipRow
        }
    }

    private var tagChipRow: some View {
        HStack(spacing: 4) {
            visibleTagChips
            overflowTagCount
        }
    }

    @ViewBuilder
    private var overflowTagCount: some View {
        if entry.tags.count > 3 {
            Text("+\(entry.tags.count - 3)")
                .font(.caption2)
                .foregroundColor(AppTheme.textSecondary)
        }
    }

    private var visibleTagChips: some View {
        ForEach(entry.tags.prefix(3)) { tag in
            Text(tag.displayName)
                .font(.caption2)
                .padding(.horizontal, 6)
                .padding(.vertical, 2)
                .background(tag.color.opacity(0.2))
                .foregroundColor(tag.color)
                .cornerRadius(4)
        }
    }

    private var timeRow: some View {
        HStack(spacing: 6) {
            Text(entry.displayDate, style: .time)
                .font(.headline)

            // Show "Nap" label for nap sessions
            sessionTypeBadge

            // Show segment count badge only when normalized split-night
            // segmentation resolves to multiple meaningful segments.
            segmentCountBadge
        }
    }

    @ViewBuilder
    private var segmentCountBadge: some View {
        if linkedSegmentCount > 1 {
            HStack(spacing: 3) {
                Image(systemName: "link")
                    .font(.caption2.weight(.bold))
                Text(String(localized: "\(linkedSegmentCount) segments", bundle: LanguageManager.appBundle))
            }
            .font(.caption2.bold())
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(AppTheme.primary.opacity(0.2))
            .foregroundColor(AppTheme.primary)
            .cornerRadius(4)
        }
    }

    @ViewBuilder
    private var sessionTypeBadge: some View {
        if entry.sessionType == .nap {
            napBadge
        } else if entry.sessionType == .quick {
            quickBadge
        } else if entry.sessionType == .breathe {
            breatheBadge
        }
    }

    /// Workout rows must not show RMSSD
    /// (mid-effort RR is contaminated and often reads as nonsense, e.g. 3 ms)
    /// or a recovery score, which is an overnight construct workouts do not
    /// get. Workouts render their duration and a "Workout" caption (the
    /// index carries no sport); overnights, naps, quick
    /// checks and breathe sessions keep the RMSSD + recovery layout.
    private var rowMetrics: some View {
        VStack(alignment: .trailing, spacing: 4) {
            if entry.sessionType == .workout {
                workoutRowMetrics(entry: entry)
            } else {
                recoveryRowMetrics
            }
        }
    }

    @ViewBuilder
    private var recoveryRowMetrics: some View {
        primaryMetricReadout
        recoveryScoreReadout
    }

    @ViewBuilder
    private var primaryMetricReadout: some View {
        if entry.sessionType == .breathe, let sdnn = entry.meanSDNN {
            HStack(spacing: 4) {
                Text(String(format: "%.0f", locale: LanguageManager.appLocale, sdnn))
                    .font(.system(.title2, design: .rounded).bold())
                    .foregroundColor(AppTheme.sdnnColor)
                Text(String(localized: "SDNN", bundle: LanguageManager.appBundle))
                    .font(.caption)
                    .foregroundColor(AppTheme.textSecondary)
            }
        } else if let rmssd = entry.meanRMSSD {
            HStack(spacing: 4) {
                Text(String(format: "%.0f", locale: LanguageManager.appLocale, rmssd))
                    .font(.system(.title2, design: .rounded).bold())
                Text(String(localized: "ms", bundle: LanguageManager.appBundle))
                    .font(.caption)
                    .foregroundColor(AppTheme.textSecondary)
            }
        }
    }

    @ViewBuilder
    private var recoveryScoreReadout: some View {
        if let rawScore = entry.recoveryScore {
            let composite = historyDisplayScore(rawScore).composite
            recoveryScoreRow(composite: composite)
            recoveryScoreBar(composite: composite)
        }
    }

    /// The 0-100 score on the same verdict ladder, glyph and colour the
    /// Dashboard and the report use, so one score never reads two ways.
    private func recoveryScoreBar(composite: Int) -> some View {
        ZStack(alignment: .leading) {
            RoundedRectangle(cornerRadius: 1.5)
                .fill(AppTheme.textTertiary.opacity(0.15))
                .frame(width: 64, height: 3)
            RoundedRectangle(cornerRadius: 1.5)
                .fill(ScoreVerdict(score: Double(composite)).color)
                .frame(width: max(2, 64 * CGFloat(min(100, max(0, composite))) / 100), height: 3)
        }
        .accessibilityHidden(true)
    }

    private func recoveryScoreRow(composite: Int) -> some View {
        let verdict = ScoreVerdict(score: Double(composite))
        return HStack(spacing: 4) {
            Image(systemName: verdict.glyphName)
                .foregroundColor(verdict.color)
                .font(.caption)
            Text("\(composite)")
                .font(.caption.weight(.medium))
                .foregroundColor(verdict.color)
            Text(String(localized: "Recovery", bundle: LanguageManager.appBundle))
                .font(.caption2)
                .foregroundColor(AppTheme.textSecondary)
        }
    }

    /// Workout row trailing metrics — duration + distance pulled from
    /// the lightweight index where available. NO RMSSD (workouts have
    /// noisy mid-effort RR), NO recovery score (workouts don't have
    /// one — that's an overnight construct). Bug list #2 fix.
    @ViewBuilder
    private func workoutRowMetrics(entry: SessionArchiveEntry) -> some View {
        let duration: TimeInterval = {
            guard let end = entry.endDate else { return 0 }
            return end.timeIntervalSince(entry.date)
        }()
        if duration > 0 {
            let mins = Int(duration / 60)
            HStack(spacing: 4) {
                Image(systemName: "figure.run")
                    .font(.caption2)
                    .foregroundColor(AppTheme.terracotta)
                    .accessibilityHidden(true)
                Text(verbatim: mins >= 60 ? LocalizedDuration.hoursMinutes(minutes: mins) : LocalizedDuration.minutes(mins))
                    .font(.system(.subheadline, design: .rounded).weight(.semibold))
                    .foregroundColor(AppTheme.textPrimary)
            }
        }
        Text(String(localized: "Workout", bundle: LanguageManager.appBundle))
            .font(.caption2)
            .foregroundColor(AppTheme.textSecondary)
    }
}

private var napBadge: some View {
    Text(String(localized: "Nap", bundle: LanguageManager.appBundle))
        .font(.caption2.bold())
        .padding(.horizontal, 6)
        .padding(.vertical, 2)
        .background(AppTheme.mist.opacity(0.2))
        .foregroundColor(AppTheme.mist)
        .cornerRadius(4)
}

@MainActor
private var quickBadge: some View {
    Text(String(localized: "Quick", bundle: LanguageManager.appBundle))
        .font(.caption2.bold())
        .padding(.horizontal, 6)
        .padding(.vertical, 2)
        .background(AppTheme.sage.opacity(0.2))
        .foregroundColor(AppTheme.sage)
        .cornerRadius(4)
}

@MainActor private var breatheBadge: some View {
    Text(String(localized: "Breathe", bundle: LanguageManager.appBundle))
        .font(.caption2.bold())
        .padding(.horizontal, 6)
        .padding(.vertical, 2)
        .background(AppTheme.sdnnColor.opacity(0.2))
        .foregroundColor(AppTheme.sdnnColor)
        .cornerRadius(4)
}

#Preview {
    NavigationStack {
        HistoryView(
            onDelete: { _ in },
            onUpdateTags: { _, _, _ in },
            onReanalyze: nil
        )
    }
}
