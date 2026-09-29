import Foundation
import UserNotifications

/// Build plan §D11 + §M3.5 + §5.12 — daily morning recovery push.
///
/// Plan calls for one notification per day fired 5 minutes after
/// device-detected sleep end (with 7am fallback). Payload format §5.12:
///
///   "Recovery 38 · Easy Z2 today — body still digesting Tuesday's load."
///
/// **What this implementation does:**
///   • Daily-repeating local notification at the user's fixed time
///     (`dailyReportFixedTime`) — the fallback path that always fires
///     even when Apple Watch hasn't synced sleep data yet.
///   • Wake-triggered one-shot push (Smart delivery only) delivered the
///     moment Apple Watch reports a fresh sleep-end via `HKObserverQuery`. Wired through
///     `deliverWakeTriggeredPushIfAppropriate(sleepEnd:)`, called from
///     `HealthKitManager+Sleep` observer's update handler. Fires only
///     once per day, gated by the `wakeTriggeredPushDate` UserDefaults
///     flag, and skipped if the user has notifications disabled or
///     hasn't granted authorization.
///   • Payload sourced from the latest archived overnight session's
///     recoveryScore. Uses the §5.3 verdict ladder for the bands.
///   • Auto format: teaser ("Your recovery is in.") for the first
///     30 archived sessions, full readout from session 31 onward.
///   • Authorization request flow: caller (Settings page or
///     scheduler call site) invokes `requestAuthorizationIfNeeded`
///     before scheduling.
///   • Reschedules on app foreground + on settings change so the
///     payload always reflects the most recent reading.
///
/// **Known deferred — documented in FLOWCHART §16 Known Deferred:**
///   • 14-day re-engagement push (single reminder when the user has
///     not recorded an overnight session for 14 consecutive days).
///     Implementation is small (~100 LOC) but the payload + UX route
///     are undefined; landing the feature is gated on product spec.
///   • A/B-tested format-pick beyond the simple session-count gate.
///
/// **No marketing pushes ever.** Only the morning report fires here.
@MainActor
final class MorningNotificationScheduler {
    static let shared = MorningNotificationScheduler()

    /// Identifier for the daily morning notification. Reused on every
    /// reschedule so we replace rather than stack pending notifications.
    private static let notificationIdentifier = "flow.recovery.morningReport"

    private let center = UNUserNotificationCenter.current()

    private init() {}

    // MARK: - Public API

    /// Request notification authorization if not yet decided. Idempotent —
    /// safe to call on every settings-toggle flip. Returns the resulting
    /// authorization status so callers can surface a "denied → Settings"
    /// banner if the user said no.
    func requestAuthorizationIfNeeded() async -> UNAuthorizationStatus {
        let settings = await center.notificationSettings()
        switch settings.authorizationStatus {
        case .notDetermined:
            do {
                _ = try await center.requestAuthorization(options: [.alert, .sound, .badge])
            } catch {
                debugLog("[MorningScheduler] auth request failed: \(error)")
            }
            return await center.notificationSettings().authorizationStatus
        default:
            return settings.authorizationStatus
        }
    }

    /// The daily push at the user's set time. In Fixed mode it is the only
    /// push; in Smart mode it is the fallback behind the wake-triggered one.
    ///
    /// Any existing pending request is replaced before the new one is added,
    /// so a settings change (time, format) takes effect immediately rather
    /// than queueing a stale one alongside a new one.
    func rescheduleIfNeeded(collector: RRCollector) async {
        let settings = AppDependencies.current.app.settingsManager.settings
        guard settings.dailyReportEnabled else { cancelAll(); return }
        let auth = await center.notificationSettings().authorizationStatus
        guard auth == .authorized || auth == .provisional || auth == .ephemeral else { cancelAll(); return }
        let time = Calendar.current.dateComponents([.hour, .minute], from: settings.dailyReportFixedTime)
        let request = UNNotificationRequest(
            identifier: Self.notificationIdentifier,
            content: morningContent(),
            trigger: UNCalendarNotificationTrigger(dateMatching: time, repeats: true)
        )
        center.removePendingNotificationRequests(withIdentifiers: [Self.notificationIdentifier])
        do {
            try await center.add(request)
            debugLog("[MorningScheduler] scheduled morning push for \(time.hour ?? 0):\(time.minute ?? 0)")
        } catch {
            debugLog("[MorningScheduler] schedule failed: \(error)")
        }
    }

    /// Built from the latest overnight session. If there's nothing to show
    /// yet, `buildPayload` falls back to a generic first-reading nudge instead
    /// of skipping — a notification that arrives early in calibration is still
    /// useful.
    private func morningContent() -> UNMutableNotificationContent {
        let (title, body) = Self.buildPayload()
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.sound = .default
        return content
    }

    /// Cancel any pending morning report. Called when the toggle goes
    /// off or auth is revoked.
    func cancelAll() {
        center.removePendingNotificationRequests(withIdentifiers: [
            Self.notificationIdentifier,
            Self.wakeTriggeredIdentifier
        ])
    }

    // MARK: - Wake-triggered push

    /// Identifier for the one-shot wake-triggered notification. Distinct
    /// from the daily-repeating identifier so removing one doesn't drop
    /// the daily fallback's repeat schedule.
    private static let wakeTriggeredIdentifier = "flow.recovery.morningReport.wake"

    /// UserDefaults key tracking the calendar day (startOfDay) on which
    /// the wake-triggered push last fired. Used to gate same-day re-fire
    /// when Apple Watch syncs additional sleep samples after the user
    /// has already received the morning notification.
    private static let wakeTriggeredFiredDateKey = "MorningNotificationScheduler.wakeFiredDate.v1"

    /// Called from `HealthKitManager+Sleep`'s sleep observer when a fresh
    /// sleep-end sample arrives. Delivers a one-shot morning push within
    /// seconds of detected wake — far closer to the user's actual wake
    /// time than the fixed-time fallback. Idempotent: subsequent observer
    /// fires on the same calendar day are no-ops, so re-syncs of refined
    /// sleep stages don't re-fire the push.
    ///
    /// The fixed-time daily-repeating push remains scheduled as the
    /// fallback path — runs only when no wake-triggered push fired
    /// earlier the same morning. iOS doesn't expose "skip today's
    /// occurrence" for a repeating trigger, so on days where both fire
    /// the user gets two notifications (wake-triggered first, then the
    /// fallback ~30–60 min later). The fallback's content is identical
    /// so the duplication is minor; the alternative — removing today's
    /// daily occurrence — would risk dropping the fallback entirely.
    func deliverWakeTriggeredPushIfAppropriate(sleepEnd: Date) async {
        let settings = AppDependencies.current.app.settingsManager.settings
        // Fixed means the set time and nothing else.
        guard settings.dailyReportEnabled, settings.dailyReportDelivery == .smart else { return }
        let auth = await center.notificationSettings().authorizationStatus
        guard auth == .authorized || auth == .provisional || auth == .ephemeral else { return }
        // Idempotency: one wake-triggered push per calendar day.
        let today = Calendar.current.startOfDay(for: Date())
        if let last = UserDefaults.standard.object(forKey: Self.wakeTriggeredFiredDateKey) as? Date,
           Calendar.current.isDate(last, inSameDayAs: today) {
            return
        }
        // Freshness gate: the sleep-end timestamp must be recent enough to be
        // a genuine wake event. Apple Watch occasionally back-syncs sleep
        // samples from previous nights when the user opens the Health app —
        // those carry an old endDate we don't want firing a notification for.
        let ageSeconds = Date().timeIntervalSince(sleepEnd)
        guard ageSeconds >= 0, ageSeconds <= 90 * 60 else { return } // 90 min window
        let (title, body) = await buildPayloadFromArchive(settings: settings)
        await deliverImmediately(title: title, body: body, today: today, sleepEnd: sleepEnd)
    }

    private func deliverImmediately(title: String, body: String, today: Date, sleepEnd: Date) async {
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.sound = .default
        let request = UNNotificationRequest(
            identifier: Self.wakeTriggeredIdentifier,
            content: content,
            trigger: nil // deliver immediately
        )
        do {
            try await center.add(request)
            UserDefaults.standard.set(today, forKey: Self.wakeTriggeredFiredDateKey)
            debugLog("[MorningScheduler] wake-triggered push delivered for sleepEnd=\(sleepEnd)")
        } catch {
            debugLog("[MorningScheduler] wake-triggered schedule failed: \(error)")
        }
    }

    /// Variant of `buildPayload` that doesn't require an RRCollector —
    /// reads directly from `AppDependencies.current.storage.sessionArchive`. Used by the sleep
    /// observer's wake-triggered push path, where no collector
    /// reference is in scope.
    private func buildPayloadFromArchive(settings: UserSettings) async -> (String, String) {
        let title = "Emuqu"
        let archive = AppDependencies.current.storage.sessionArchive
        guard Self.resolvedFormat(settings.dailyReportFormat, archive: archive) == .full else {
            return (title, String(localized: "Your recovery is in.", bundle: LanguageManager.appBundle))
        }
        guard let scoreInt = Self.todaysScore(in: archive) else {
            return (title, String(localized: "Open Emuqu for this morning's recovery score.", bundle: LanguageManager.appBundle))
        }
        let prescription = shortPrescription(for: ScoreVerdict(score: Double(scoreInt)))
        return (title, String(localized: "Recovery \(scoreInt) · \(prescription)", bundle: LanguageManager.appBundle))
    }

    /// `.auto` shows the full number once the archive has enough history for
    /// the score to mean something. The count comes off a lock-safe snapshot —
    /// raw `index` reads outside `archiveLock` race locked mutations.
    private static func resolvedFormat(
        _ format: UserSettings.DailyReportFormat, archive: SessionArchive
    ) -> UserSettings.DailyReportFormat {
        switch format {
        case .full: .full
        case .teaser: .teaser
        case .auto: archive.entries.count >= 30 ? .full : .teaser
        }
    }

    /// Only surface a number if it belongs to THIS morning's reading. The
    /// most-recent scored overnight is *yesterday's* until today's session is
    /// recorded and processed — a notification that shows yesterday's score
    /// reads as a bug. Gated on the session's wake time
    /// (endDate) falling in today; nil means the caller falls back to a
    /// number-free nudge until this morning's reading exists.
    private static func todaysScore(in archive: SessionArchive) -> Int? {
        let calendar = Calendar.current
        let entries = archive.entries
            .filter { $0.sessionType == .overnight && calendar.isDateInToday($0.endDate ?? $0.date) }
            .sorted { ($0.endDate ?? $0.date) > ($1.endDate ?? $1.date) }
            .prefix(7)
        for entry in entries {
            if let session = archive.retrieveLightweightOrLog(entry.sessionId),
               let score10 = session.recoveryScore {
                return ScoreVerdict.safeDisplayScore(score10 * 10)
            }
        }
        return nil
    }

    // MARK: - Payload builder

    /// Returns (title, body) for the **fixed-time daily fallback** push.
    ///
    /// This push uses a repeating `UNCalendarNotificationTrigger`; iOS freezes
    /// its content at schedule time and replays it unchanged every morning. It
    /// therefore must NOT embed today's recovery score — a baked-in number is
    /// correct for at most one day, then silently shows a stale ("yesterday's")
    /// value on every later fire. So this fallback is
    /// deliberately number-free. The actual score is carried by the live
    /// wake-triggered push (`buildPayloadFromArchive`), which is rebuilt fresh
    /// each morning and gated to today's session.
    /// `nonisolated static` so the number-free property can be
    /// asserted by a test. It returns a constant and reads no instance state;
    /// a "no baked-in score" rule that is documented but pinned nowhere
    /// is how a stale-score bug gets in.
    nonisolated static func buildPayload() -> (String, String) {
        ("Emuqu", String(localized: "Open Emuqu for this morning's recovery score.", bundle: LanguageManager.appBundle))
    }

    /// Plan §5.12 — short one-line prescription per verdict band. Voice
    /// rules §5.1: observe-don't-diagnose, suggest-not-prescribe for
    /// health, prescribe for training. All are <60 chars to fit on the
    /// lock-screen notification preview without truncation.
    private func shortPrescription(for verdict: ScoreVerdict) -> String {
        let bundle = LanguageManager.appBundle
        switch verdict {
        case .excellent:
            return String(localized: "Go hard today — everything is dialed in.", bundle: bundle)
        case .good:
            return String(localized: "Normal training is fine — body is well-rested.", bundle: bundle)
        case .fair:
            return String(localized: "Listen today — body is in a normal recovery window.", bundle: bundle)
        case .payAttention:
            return String(localized: "Easy day or rest — body is below your usual range.", bundle: bundle)
        case .low:
            return String(localized: "Skip intensity today — body needs recovery.", bundle: bundle)
        case .veryLow:
            return String(localized: "Rest day — body is signaling recovery.", bundle: bundle)
        }
    }
}
