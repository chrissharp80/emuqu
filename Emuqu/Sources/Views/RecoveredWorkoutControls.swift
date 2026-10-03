import SwiftUI

// The three recovered-workout controls, split out of
// `FitnessPostSummaryView.swift`: trimming a recovered workout,
// pulling a session back off the strap, and importing a route the Watch
// recorded. Each is an independent view the summary happens to host.

// (ShareURL wrapper removed — ShareLink works directly with URL.)

/// Inline trim control for a crash-recovered workout whose duration is too
/// long (the strap kept recording after the workout ended). Drag the end back
/// to the real finish; Save re-finalizes the session at that point. Lives on
/// the session detail so it's always reachable — independent of any launch
/// prompt. Re-created (via `.id(session.endDate)`) after each trim so the
/// slider resets to the new, shorter length. `onTrim` is awaited, and Save
/// comes back when it returns, so a trim that changed nothing (too few beats,
/// no series) doesn't leave the button stuck on "Saving…".
struct RecoveredWorkoutTrimControl: View {
    let session: HRVSession
    let onTrim: (Double) async -> Void // chosen end, seconds from start
    @State private var endMinutes: Double
    @State private var working = false

    init(session: HRVSession, onTrim: @escaping (Double) async -> Void) {
        self.session = session
        self.onTrim = onTrim
        let dur = (session.endDate ?? session.startDate).timeIntervalSince(session.startDate)
        _endMinutes = State(initialValue: max(1, (dur / 60).rounded()))
    }

    private var maxMinutes: Double {
        let dur = (session.endDate ?? session.startDate).timeIntervalSince(session.startDate)
        return max(2, (dur / 60).rounded())
    }

    private var changed: Bool { endMinutes < maxMinutes - 0.5 }

    var body: some View {
        recoveryCard(VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Image(systemName: "scissors")
                    .foregroundStyle(AppTheme.sage)
                Text(String(localized: "Wrong length? Trim the end", bundle: LanguageManager.appBundle))
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(AppTheme.textPrimary)
            }
            Text(String(localized: "If the strap kept recording after you finished, drag the end back to where the workout actually ended, then Save.", bundle: LanguageManager.appBundle))
                .font(.footnote)
                .foregroundStyle(AppTheme.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
            trimEndControl
            saveTrimButton
        }, tint: AppTheme.sage, fill: 0.08, stroke: 0.3)
    }

    private var trimEndControl: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(String(format: NSLocalizedString("End at %d min", bundle: LanguageManager.appBundle, comment: ""), Int(endMinutes)))
                .font(.subheadline.weight(.semibold).monospacedDigit())
                .foregroundStyle(AppTheme.textPrimary)
            Slider(value: $endMinutes, in: 1 ... maxMinutes, step: 1)
                .tint(AppTheme.sage)
        }
    }

    private var saveTrimButton: some View {
        Button {
            working = true
            let endSec = endMinutes * 60
            Task {
                await onTrim(endSec)
                working = false
            }
        } label: {
            bodyLabel
        }
        .buttonStyle(.plain)
        .disabled(working || !changed)
    }

    private var bodyLabel: some View {
        HStack(spacing: 6) {
            if working { ProgressView().scaleEffect(0.7) }
            Text(working
                ? String(localized: "Saving…", bundle: LanguageManager.appBundle)
                : String(localized: "Save trimmed length", bundle: LanguageManager.appBundle))
        }
        .font(.subheadline.weight(.semibold))
        .frame(maxWidth: .infinity)
        .padding(.vertical, 10)
        .background(changed ? AppTheme.primary : AppTheme.primary.opacity(0.4))
        .foregroundColor(.white)
        .cornerRadius(10)
    }
}

/// "Recover session" — re-download the strap's complete recording and merge it
/// into this workout, then auto-trim the end at the HR drop. Restores the full
/// duration/HR when the phone-side recording was partial. Strap connection
/// required (it reads the on-device recording).
struct RecoverSessionFromStrapButton: View {
    let session: HRVSession
    @Environment(RRCollector.self) var collector
    @State private var working = false
    @State private var message: String?

    var body: some View {
        recoveryCard(VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Image(systemName: "arrow.down.heart.fill")
                    .foregroundStyle(AppTheme.sage)
                Text(String(localized: "Recover full session from strap", bundle: LanguageManager.appBundle))
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(AppTheme.textPrimary)
            }
            Text(String(localized: "Connect your strap, then merge its complete recording into this workout. Restores the full length and auto-trims the end where your heart rate drops.", bundle: LanguageManager.appBundle))
                .font(.footnote)
                .foregroundStyle(AppTheme.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
            recoveryMessage(message)
            recoverFromStrapButton
        }, tint: AppTheme.sage, fill: 0.08, stroke: 0.3)
    }
}

fileprivate extension RecoverSessionFromStrapButton {
    var recoverFromStrapButton: some View {
        Button {
            recoverFromStrap()
        } label: {
            actionLabel(
                working: working,
                busyTitle: String(localized: "Recovering from strap…", bundle: LanguageManager.appBundle),
                idleTitle: String(localized: "Recover session", bundle: LanguageManager.appBundle),
                tint: AppTheme.sage
            )
        }
        .buttonStyle(.plain)
        .disabled(working)
    }

    func recoverFromStrap() {
        working = true
        message = nil
        Task {
            let result = await collector.augmentWorkoutFromStrap(sessionId: session.id)
            working = false
            message = Self.strapMergeMessage(result)
        }
    }

    static func strapMergeMessage(_ result: SessionRecoveryCoordinator.StrapAugmentResult) -> String {
        switch result {
        case let .merged(durationSec, beats):
            let mins = Int((durationSec / 60).rounded())
            return String(format: NSLocalizedString("Merged — %d min, %d beats.", bundle: LanguageManager.appBundle, comment: ""), mins, beats)
        case .notConnected:
            return String(localized: "Connect your strap first, then try again.", bundle: LanguageManager.appBundle)
        case .noStrapData:
            return String(localized: "No recording found on the strap for this session.", bundle: LanguageManager.appBundle)
        case .failed:
            return String(localized: "Couldn't merge — try again.", bundle: LanguageManager.appBundle)
        }
    }
}

/// The shared card chrome both recovery controls sit in.
private func recoveryCard(_ content: some View, tint: Color, fill: Double, stroke: Double) -> some View {
    content
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(tint.opacity(fill))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(tint.opacity(stroke), lineWidth: 1)
        )
}

/// A one-line status message, shown once a recovery attempt has finished.
@ViewBuilder
@MainActor
private func recoveryMessage(_ message: String?) -> some View {
    if let message {
        Text(message)
            .font(.footnote.weight(.medium))
            .foregroundStyle(AppTheme.textSecondary)
            .fixedSize(horizontal: false, vertical: true)
    }
}

/// The shared shape of both recovery buttons: a spinner while working, a title
/// that changes with state, and a full-width tinted pill.
private func actionLabel(working: Bool, busyTitle: String, idleTitle: String, tint: Color) -> some View {
    HStack(spacing: 6) {
        if working { ProgressView().scaleEffect(0.7) }
        Text(working ? busyTitle : idleTitle)
    }
    .font(.subheadline.weight(.semibold))
    .frame(maxWidth: .infinity)
    .padding(.vertical, 10)
    .background(tint)
    .foregroundColor(.white)
    .cornerRadius(10)
}

/// Recover the full GPS route of a crash-recovered workout from the Apple
/// Watch. The phone's GPS dies at the crash; the Watch's recording of the same
/// walk is the only place the missing route still lives. One tap pulls it from
/// Apple Health and re-finalizes the session's distance/route.
struct RecoveredRouteFromWatchButton: View {
    let session: HRVSession
    @Environment(RRCollector.self) var collector
    @State private var working = false
    @State private var message: String?

    var body: some View {
        recoveryCard(VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Image(systemName: "applewatch")
                    .foregroundStyle(AppTheme.primary)
                Text(String(localized: "Distance short? Recover it from Apple Health", bundle: LanguageManager.appBundle))
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(AppTheme.textPrimary)
            }
            Text(String(localized: "Your Apple Watch and iPhone log how far you walked even without a workout. This pulls the real distance Health recorded for this window — and the full GPS route too, if your Watch tracked it.", bundle: LanguageManager.appBundle))
                .font(.footnote)
                .foregroundStyle(AppTheme.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
            recoveryMessage(message)
            recoverRouteButton
        }, tint: AppTheme.primary, fill: 0.06, stroke: 0.25)
    }
}

fileprivate extension RecoveredRouteFromWatchButton {
    var recoverRouteButton: some View {
        Button {
            recoverRoute()
        } label: {
            actionLabel(
                working: working,
                busyTitle: String(localized: "Looking on Apple Watch…", bundle: LanguageManager.appBundle),
                idleTitle: String(localized: "Recover route from Apple Watch", bundle: LanguageManager.appBundle),
                tint: AppTheme.primary
            )
        }
        .buttonStyle(.plain)
        .disabled(working)
    }

    func recoverRoute() {
        working = true
        message = nil
        Task {
            let result = await collector.recoverRouteFromAppleWatch(sessionId: session.id)
            working = false
            message = Self.routeRecoveryMessage(result)
        }
    }

    static func routeRecoveryMessage(_ result: SessionRecoveryCoordinator.WatchRouteRecoveryResult) -> String {
        switch result {
        case let .recovered(meters):
            return String(format: NSLocalizedString("Route recovered — distance is now %@.", bundle: LanguageManager.appBundle, comment: ""), distanceText(meters))
        case let .distanceOnly(meters):
            return String(format: NSLocalizedString("Distance recovered from Apple Health — now %@. (No GPS route was recorded, so the map still shows only the part the phone captured.)", bundle: LanguageManager.appBundle, comment: ""), distanceText(meters))
        case .noRoute:
            return String(localized: "Apple Health has no extra distance for this workout's time window.", bundle: LanguageManager.appBundle)
        case .failed:
            return String(localized: "Couldn't recover — try again.", bundle: LanguageManager.appBundle)
        }
    }

    private static func distanceText(_ meters: Double) -> String {
        let unit: UnitLength = UnitsPreferenceStore.current.resolved == .imperial ? .miles : .kilometers
        return Measurement(value: meters, unit: UnitLength.meters).converted(to: unit).formatted(
            .measurement(width: .abbreviated, usage: .asProvided, numberFormatStyle: .number.precision(.fractionLength(2)))
                .locale(LanguageManager.appLocale)
        )
    }
}
