import Foundation

// The `UserSettings` value type itself. The enums it is built from (fitness
// level, training goal, routing mode, units, themes, merge mode) live in
// `UserSettings.swift`.

/// User settings for personalized insights and preferences
struct UserSettings: Codable, Equatable {
    static let currentSchemaVersion = 1

    /// Schema version read from the payload during decode; nil for settings
    /// constructed in memory (never decoded). Transient — deliberately NOT
    /// encoded: `encode(to:)` always writes `currentSchemaVersion`. Captured
    /// so a future migration has a dispatch point (mirrors
    /// `HRVSession.sourceSchemaVersion`). No behavior change today.
    var sourceSchemaVersion: Int?

    var customTags: [ReadingTag]
    var birthday: Date?
    var fitnessLevel: FitnessLevel?
    var biologicalSex: BiologicalSex?
    var baselineRMSSD: Double?
    var baselineHR: Double?
    /// User's typical/target sleep duration in hours (default 8.0)
    /// Used to calculate sleep completion ratio for effective recovery
    var typicalSleepHours: Double

    /// Expected bedtime (hour and minute only). Defaults to 10:00 PM.
    /// Combined with typicalSleepHours to derive the full sleep schedule.
    /// Shift workers should set this to when they normally go to sleep.
    var expectedBedtime: Date

    /// Session merge mode: off (no linking), default (4.5h), or custom window
    var sessionMergeMode: SessionMergeMode = .defaultGap
    /// Custom merge gap in hours (used when sessionMergeMode == .custom). Range: 1–12 hours.
    var customMergeGapHours: Double = 4.5
    /// Max gap (in minutes) that still counts as the same sleep session.
    /// Gaps >= this threshold split the night into separate segments.
    /// Also controls the awake-period split threshold in the processing pipeline.
    var sleepSplitGapMinutes: Int = 20
    /// Default window selection method for HRV analysis (defaults to consolidatedRecovery for backward compatibility)
    var defaultWindowSelectionMethod: WindowSelectionMethod = .consolidatedRecovery

    // MARK: - Fitness Integration Settings

    /// Manual VO2max override (ml/kg/min) - use if you have actual lab-tested value
    /// HealthKit estimates are often inaccurate, so manual override takes priority
    var vo2MaxOverride: Double?

    /// Whether to use HealthKit's VO2max estimate as fallback when no override is set
    var useHealthKitVO2Max: Bool = false

    /// User's body weight in kilograms. Used for calorie calculation during
    /// workouts — the standard METs × 3.5 × kg × minutes / 200 formula.
    /// Without a real weight we were defaulting to 75 kg which overestimated
    /// for lighter users and underestimated for heavier ones. Try to read
    /// from HealthKit as a fallback when not set manually.
    var bodyWeightKg: Double?

    /// User's home address. Free-text; forward-geocoded by
    /// the AI's `directions.routeTo` tool when the user says "lead me
    /// home." Apple's CLGeocoder accepts loose phrasings ("123 Main St
    /// Knoxville", "the house"). Nil when the user hasn't set one;
    /// the routing tool then returns a notRecorded with a hint to set
    /// it. Never auto-populated — privacy boundary; user has to type
    /// it themselves.
    var homeAddress: String?

    /// Resolved body weight. User override (if set) → 75 kg population
    /// fallback. NOTE: there is NO HealthKit body-mass query anywhere in the
    /// codebase, despite earlier docs / the AI fact description claiming one.
    /// Tracked as a follow-up; do not rely on a HealthKit path here.
    /// baseline (clearly labelled "est" in UI so no one mistakes it for
    /// a real measurement). Always returns a usable number so calorie
    /// math never divides by nil.
    var effectiveBodyWeightKg: Double {
        if let kg = bodyWeightKg, kg > 0 { return kg }
        return 75.0
    }

    /// User's maximum heart rate (bpm). Used for workout HR-zone classification
    /// and voice-coach trigger thresholds. Without this, the app was falling
    /// back to session-peak HR as the denominator — producing garbage output
    /// like "Zone 5 at 100 bpm" because the session peak was only ~105.
    ///
    /// If nil, `effectiveMaxHR` falls back to 220 − age (approximate; fine as
    /// a default, but users with real lab-tested HRmax should override here).
    /// If birthday isn't set either, we default to a conservative 180 so
    /// zone coloring doesn't go catastrophically wrong for fit users.
    var maxHR: Int?

    /// User's lactate threshold HR (bpm). Used by Banister-style TRIMP and
    /// HRSS-flavoured hrTSS for "time-at-threshold-intensity" normalisation.
    ///
    /// Friel recommends field-testing: 30-min solo time trial at race effort,
    /// average HR over the final 20 min = LTHR. Without a tested value, we
    /// fall back to ~0.88 × effectiveMaxHR — midpoint of the 85-90 % band
    /// cited for fit endurance athletes. The %HRmax approximation is *less
    /// accurate* than a tested number (Friel explicitly warns against it)
    /// but good enough to anchor hrTSS comparability across sessions.
    var lactateThresholdHR: Int?

    /// Resolved LTHR — user override, else 0.88 x `effectiveMaxHR`, with a 120
    /// floor.
    ///
    /// The 120 floor is only reachable at all through an absurd user-entered
    /// max HR — with the derived max (150-220) the result lands at 133-158.
    /// Deliberately not raised to 160, because LTHR is the denominator hrTSS
    /// divides by and raising it would shift every historical training-load
    /// figure.
    var effectiveLTHR: Int {
        if let user = lactateThresholdHR, user > 0 { return user }
        let fromMax = Int(Double(effectiveMaxHR) * 0.88)
        return max(120, fromMax)
    }

    /// Functional Threshold Power in watts — the highest average power the
    /// user can sustain for ~1 hour. Anchors power-based intensity factor,
    /// power-TSS, and power zones. For a runner using a Stryd this is
    /// "running FTP" (rFTP); for a cyclist with a CPS bike power meter it's
    /// "cycling FTP". The two are different physiologically (running has a
    /// higher rFTP than cFTP for the same person) so we keep one number per
    /// sport family.
    ///
    /// Field-test approach: 20-min all-out time trial, take 95 % of avg
    /// power. Or use a structured FTP test workout. Without a tested value
    /// we provide nil and the AI / UI explicitly tells the user power-TSS
    /// can't be computed yet — better than guessing a number.
    var runningFTPWatts: Int?
    var cyclingFTPWatts: Int?

    /// Broadcast live HR + power as a standard BLE peripheral so Zwift,
    /// TrainerRoad, Rouvy, etc. see Emuqu as a sensor. Lets a user
    /// who's already paired their Polar strap + Stryd to Emuqu
    /// share that same data with their indoor-trainer game without
    /// re-pairing each device. Off by default — only useful indoors.
    var enableZwiftBroadcast: Bool = false

    /// Periodic unprompted coaching during a workout.
    /// When on, the AI surfaces a one-line coaching summary at the
    /// configured cadence (drift / decoupling / split / readiness).
    /// When off, the AI only speaks when the user asks OR when a
    /// concrete trigger fires (mile marker, threshold breach, ACWR
    /// alert). Default ON because the user has to enable voice chat
    /// to hear it anyway, and the cadence is gated on data being
    /// meaningful — silent workouts still stay silent.
    var enablePeriodicCoachUpdates: Bool = true
    /// Cadence (seconds) for the periodic coach. Default 5 minutes.
    /// Min floor enforced by the trigger; this is the value the
    /// settings UI reads/writes.
    var periodicCoachCadenceSec: Int = 300

    /// Auto-generate a comprehensive AI Coach report
    /// after each workout's HRR window closes (or when the strap
    /// drops, whichever happens first). When on, the recorder
    /// generates a Markdown report from the session, saves it to
    /// disk, and presents the mail composer pre-filled to the user's
    /// default training-email recipient. The user taps Send (iOS
    /// requires user interaction for mail send — apps cannot bypass
    /// that without a backend). When off, no auto-prompt; the user
    /// can still generate the report on demand from the post-summary
    /// view or any historical entry.
    /// Default is OFF: auto-firing on every workout is noisy and the
    /// on-demand path from the post-summary view + any historical entry
    /// covers the use case. Users who want auto-reports can flip the
    /// toggle in Settings → Reports.
    var enableAutoCoachReport: Bool = false

    /// Allow the AI assistant to call the web-search tool (Tavily) to
    /// look up authoritative sources for questions the on-device facts
    /// can't answer. Requires a Tavily API key in Settings → AI
    /// Assistant. Off by default — explicit opt-in because (a) it sends
    /// the user's question to a third party and (b) opens the door to
    /// the AI quoting non-medical-grade sources for health questions.
    /// The system-prompt overlay enforces "no protocol synthesis from
    /// search results, always cite source URLs."
    /// Defaults to true so the AI doesn't refuse "look it up" requests
    /// out of the box. The actual search still
    /// requires either (a) a Tavily key in Settings, or (b) the user
    /// being on a provider with native server-side search (Anthropic
    /// — wired below). Per-provider consent gates separately enforce
    /// what data leaves the device.
    var enableWebSearch: Bool = true

    /// **Default email recipients — two categories.** Used app-wide
    /// (not just by the AI assistant): the Recovery / Morning report
    /// PDF export, the Workout PDF export, and the AI's
    /// `assistant.email.compose` action all pre-fill from these. So
    /// the user sets up their addresses ONCE in their profile and
    /// every email surface knows them.
    ///
    /// Why two categories: a user often wants their morning recovery
    /// reports going one place (themself, a doctor) and their workout
    /// reports going another (themself, a coach, a training partner).
    /// Same person frequently — but not always — and the split costs
    /// nothing in UI complexity if defaults reasonably collapse.

    /// Default To address for RECOVERY emails (morning report, HRV
    /// summaries, sleep scoring exports). Nil = composer opens with
    /// no To pre-filled.
    var defaultRecoveryEmailRecipient: String?
    /// Comma-separated CC list for recovery emails.
    var defaultRecoveryEmailCC: String?

    /// Default To address for TRAINING emails (workout PDF reports,
    /// session summaries, training-load digests). Nil = composer
    /// opens with no To pre-filled.
    var defaultTrainingEmailRecipient: String?
    /// Comma-separated CC list for training emails.
    var defaultTrainingEmailCC: String?

    /// **Legacy** single-default fields, kept for back-compat.
    /// Migrated forward into recovery + training defaults on first
    /// read after the user sets the new fields. NOT safe to delete:
    /// they are still first-precedence in `resolvedDefaultEmailRecipient` /
    /// `resolvedDefaultEmailCC` below, and removing them from this
    /// `Codable` type would drop the saved address for any user who set
    /// the old field but never the new recovery/training split.
    var defaultEmailRecipient: String?
    var defaultEmailCC: String?

    /// Generic-default resolver for the "uncategorised"
    /// email path (per-message chat notes from the AI, anything else
    /// that doesn't have a recovery/training tag). Returns the first
    /// non-empty match in: legacy generic → recovery → training. Nil
    /// when nothing is configured. Callers `.flatMap { ... }` into a
    /// recipients array.
    var resolvedDefaultEmailRecipient: String? {
        let candidates = [defaultEmailRecipient, defaultRecoveryEmailRecipient, defaultTrainingEmailRecipient]
        return candidates.compactMap { $0 }.first(where: { !$0.isEmpty })
    }

    /// CC list for the uncategorised email path. Same precedence as
    /// `resolvedDefaultEmailRecipient`. Returns a parsed array (empty
    /// when nothing configured), suitable for direct use as
    /// `MailComposerView.ccRecipients`.
    var resolvedDefaultEmailCC: [String] {
        let raw = [defaultEmailCC, defaultRecoveryEmailCC, defaultTrainingEmailCC]
            .compactMap { $0 }
            .first(where: { !$0.isEmpty }) ?? ""
        return raw
            .split(separator: ",")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
    }

    /// Resolved running FTP. User-entered value wins; otherwise
    /// falls back to the archive-derived auto-estimate so users
    /// with a Stryd but no FTP test still get power-based TSS.
    /// Returns nil only when neither path has a value — that's
    /// when callers render "set FTP to unlock power-TSS" guidance.
    ///
    /// Auto-estimate fallback convention:
    /// best 20-min NP × 0.95 from the running-family archive
    /// (TrainingPeaks). See `FTPAutoEstimator`.
    @MainActor
    var effectiveRunningFTP: Int? {
        if let ftp = runningFTPWatts, ftp > 0 { return ftp }
        return FTPAutoEstimator.cachedRunningFTP
    }

    var effectiveCyclingFTP: Int? {
        guard let ftp = cyclingFTPWatts, ftp > 0 else { return nil }
        return ftp
    }

    /// User-entered resting HR override (bpm). When set, takes precedence over
    /// the auto-tracked `baselineHR` that's derived from HRV recordings. Users
    /// with lab-measured or watch-nightly-low values often know their real
    /// resting HR better than anything we can infer from short HRV windows.
    var userRestingHR: Int?

    /// Resting HR for HRR / Karvonen-style calculations. Preference order:
    /// user override → HRV-derived baseline → 60 bpm typical-adult default.
    /// Never returns 0 so TRIMP math never divides into nonsense.
    var effectiveRestingHR: Int {
        if let user = userRestingHR, user > 30 { return user }
        if let baseline = baselineHR, baseline > 30 {
            return Int(baseline.rounded())
        }
        return 60
    }

    /// Resolved max HR — user override if set, else 220 − age from birthday,
    /// else 180 as a safe floor. Always returns a usable number so downstream
    /// zone math never divides by nil or zero.
    var effectiveMaxHR: Int {
        MaxHeartRate.effective(
            userEntered: maxHR,
            birthday: birthday,
            reference: Date(),
            calendar: Calendar.current
        )
    }

    /// Whether to include HealthKit sleep data in recovery score and charts
    var enableSleepIntegration: Bool = true

    /// When enabled, runs Apple Watch sleep stages through HRV-based refinement using
    /// chest strap RR data. Catches deep sleep Watch misclassifies as core, REM twitches
    /// misidentified as awake, etc. Off by default so existing users keep their familiar
    /// Watch-only scores. The standalone HRV classifier (no-Watch fallback) always runs
    /// regardless of this setting.
    var enableHRVSleepAugmentation: Bool = false

    /// When sleep integration is on but no sleep data is found, penalize the recovery score
    /// (treats "no sleep detected" as a negative signal rather than ignoring it)
    var penalizeMissingSleep: Bool = false

    /// Whether to integrate recent workout data into readiness calculations
    var enableTrainingLoadIntegration: Bool = true

    /// Training break start date (injury, surgery, vacation) - hides training load display
    /// Does NOT affect calculations - just hides the UI during recovery
    var trainingBreakStartDate: Date?

    /// Training break end date (optional) - if nil, break continues until manually ended
    var trainingBreakEndDate: Date?

    /// Optional reason for training break (e.g. "Surgery", "Vacation", "Sick")
    var trainingBreakReason: String?

    // MARK: - Comeback mode
    //
    // When the user is returning from illness or injury, the standard
    // recovery score weights (HRV 60% / Sleep 25% / Vitals 15%) penalize
    // the user for vitals that haven't normalized yet — RR, RHR, and
    // wrist temperature can stay elevated for days or weeks after a
    // viral infection. Comeback mode shifts the weighting to HRV 80% /
    // Sleep 20% / Vitals 0% for a 21-day window so HRV (the most
    // adaptive autonomic signal) drives the score and the user gets a
    // realistic readout of where they are in the comeback.
    //
    // Activated manually by the user via Settings → Recovery →
    // "I'm coming back from illness or injury". Auto-deactivates 21
    // days after start. Deactivation is silent — the score smoothly
    // transitions back to standard weighting as the day passes.

    /// Date the user toggled Comeback mode on. Nil = never enabled or
    /// already auto-expired and cleared by the next dashboard load.
    var comebackModeStartDate: Date?

    /// Whether Comeback mode is currently active. Window is 21 days
    /// from `comebackModeStartDate`. Returns false (without auto-clearing
    /// the date) once the window has passed — the value type can't
    /// mutate itself, so cleanup happens at the next setter that touches
    /// the settings document.
    var isComebackModeActive: Bool {
        guard let start = comebackModeStartDate else { return false }
        let calendar = Calendar.current
        let today = calendar.startOfDay(for: Date())
        let startDay = calendar.startOfDay(for: start)
        guard let daysSince = calendar.dateComponents([.day], from: startDay, to: today).day else { return false }
        return daysSince >= 0 && daysSince < 21
    }

    // MARK: - Modes (build plan §4.2 D6 / §6.12)
    //
    // Two additional modes that pair with Comeback mode for the v2.0
    // Trajectory surface. Both are user-toggled (never auto-set) and
    // only suppress messaging — they do not change the score weights.

    /// Auto-detect peaking taper. When ATL drops below CTL by 10%+ for
    /// 4+ days, the Trajectory surface labels the state as "Peaking"
    /// instead of "Detraining." Default `true` (auto). User can disable
    /// to always see the raw curves.
    var peakingDetectionEnabled: Bool = true

    // MARK: - Notifications (build plan §4.6 M3.5 / §6.13)

    /// Daily morning recovery push. Off by default for new installs;
    /// users opt in from Settings → Notifications.
    var dailyReportEnabled: Bool = false

    enum DailyReportDelivery: String, Codable, CaseIterable {
        /// Sleep-end-detected + 5-minute settle window.
        case smart
        /// Fixed wall-clock time (`dailyReportFixedTime`).
        case fixed
    }

    var dailyReportDelivery: DailyReportDelivery = .smart

    /// Wall-clock time for `.fixed` delivery (only the time-of-day
    /// component is used; the date portion is irrelevant). Default 7:00am.
    var dailyReportFixedTime: Date = {
        var comps = DateComponents()
        comps.hour = 7
        comps.minute = 0
        return Calendar.current.date(from: comps) ?? Date()
    }()

    enum DailyReportFormat: String, Codable, CaseIterable {
        /// "Recovery 38 · Easy Z2 today — body still digesting Tuesday's load."
        case full
        /// "Your recovery is in."
        case teaser
        /// Auto-pick based on session count: teaser for D1–D29, full for D30+.
        case auto
    }

    var dailyReportFormat: DailyReportFormat = .auto

    /// HRV anomaly alerts. Off by default — many users find these noisy.
    var hrvAnomalyAlertsEnabled: Bool = false

    /// Build plan §4.6 M3.1 — user avatar (tap-to-change). Stored as
    /// JPEG-encoded data, compressed and downscaled to ~256×256 at
    /// pick-time so the settings file stays small. Nil = use the
    /// system default (initials or person glyph).
    var avatarImageData: Data?

    /// Polar strap battery-low alerts. On by default — actionable.
    var batteryLowAlertsEnabled: Bool = true

    /// Master toggle for in-workout coach alerts (HR spikes, drift,
    /// terrain calls, mile splits — anything that interrupts the user
    /// audibly during a workout). When false, the trigger engine still
    /// evaluates and logs events to the post-session timeline, but
    /// nothing is spoken or haptically dispatched. Independent of
    /// `WorkoutVoiceCoach.isMuted` (the in-session "shut up for now"
    /// button on the recording view): EITHER off kills alerts. On by
    /// default — most users want them.
    var coachAlertsEnabled: Bool = true

    /// Clipboard preservation. When true (default),
    /// Emuqu's clipboard writes (per-message chat copies,
    /// urgent-alert in-progress dictation saves) are written
    /// without an expiration date — content sticks around until
    /// the user pastes it or copies something else. When false,
    /// writes set a 60 s `.expirationDate` so the clipboard
    /// auto-clears as a security measure. User feedback: an
    /// interrupting alert makes it easy to lose the thread, so the
    /// clipboard is preserved by default, with an opt-in to the
    /// security behaviour.
    var preserveClipboardForPaste: Bool = true

    /// Speech-to-text provider preference. Apple's
    /// `SFSpeechRecognizer` is the default — fast, on-device, zero
    /// extra cost. WhisperKit is an opt-in alternative (open-source,
    /// CoreML-on-device port of OpenAI Whisper) that handles wind /
    /// footfall noise better but adds a 100–400 MB model download
    /// the first time it's enabled. Switching providers takes effect
    /// at the start of the NEXT voice session — an in-flight
    /// session keeps using whatever it started with.
    var preferredSTTProvider: STTProviderKind = .apple

    /// Opt-in mile-marker notifications. Distinct from
    /// `coachAlertsEnabled`: alerts are emergency-shaped ("you're
    /// about to die"); these are pre-formatted periodic check-ins
    /// (split time + pace + zone + distance, every mile/km). Off by
    /// default — these chatter constantly, so the user has to
    /// explicitly turn them on. When on, payloads are dispatched
    /// through the same in-conversation-aware trigger queue as
    /// alerts (so they never wipe an in-progress user utterance).
    var enableMileMarkerNotifications: Bool = false

    /// Distance/time interval for mile-marker notifications. Honors
    /// the user's units preference: `.everyMile` is automatically
    /// `.everyKilometer` for metric users (the formatter resolves
    /// this; the storage stays neutral). Default: `.everyMile` for
    /// imperial users, `.everyKilometer` for metric.
    var mileMarkerInterval: MileMarkerInterval = .everyDistanceUnit

    /// Opt-in proactive turn-by-turn alerts. When the
    /// AI's `directions.routeTo` is engaged, fire a voice alert as
    /// the user approaches each turn (at 500 ft, 200 ft, and AT
    /// the turn for imperial; metric thresholds are 150 m / 60 m /
    /// 0). Off by default — only meaningful with an active route,
    /// and the user has to explicitly opt in. Independent of
    /// `coachAlertsEnabled` (which gates the emergency-shaped
    /// alerts) but also independent of
    /// `enableMileMarkerNotifications` (which fires on distance
    /// regardless of route). All three can be on / off in any
    /// combination.
    var enableTurnByTurnAlerts: Bool = false

    /// Opt-in turn-as-marker updates. After the user
    /// COMPLETES a turn on the active route, fire a split-style
    /// update for the leg they just finished (HR avg, pace, time,
    /// distance since the previous turn). Distinct from turn-
    /// alerts — those fire BEFORE a turn ("turn right in 200 ft");
    /// these fire AFTER ("you turned onto Maple. Last leg: 2:14,
    /// pace 8:45, HR 142"). Off by default. Only meaningful when
    /// a route is engaged AND a workout is recording (the split
    /// math needs HR + pace from the workout context).
    var enableTurnMarkerUpdates: Bool = false

    /// iCloud sync failure alerts. On by default — silent failures cost
    /// data trust.
    var syncFailureAlertsEnabled: Bool = true

    /// User-toggled "I'm pushing on purpose" mode. While active,
    /// suppresses "rapid increase" / "high load" messaging on the
    /// Trajectory surface. Recovery Score is NOT changed — only copy.
    var intentionalOverreachActive: Bool = false

    /// Optional end-date for an intentional-overreach block (camp, race
    /// build, peak overload week). When set, the mode auto-deactivates
    /// at midnight on this date.
    var intentionalOverreachEndDate: Date?

    /// Temperature unit preference (Celsius or Fahrenheit)
    var temperatureUnit: TemperatureUnit = .fahrenheit

    /// Build plan §4.6 M3.3 + §D8 — single training goal.
    /// Drives Coach voice modulation and Trajectory ramp-rate language;
    /// does not change the recovery score itself.
    var trainingGoal: TrainingGoal = .maintain

    /// Three-mode routing (Quick / Auto / Deep + Manual). Per the
    /// adaptive-routing spec:
    ///   • **Quick** — pin Tier 1 (Apple Intelligence). Fastest, free,
    ///     private. May refuse complex queries with an upgrade prompt.
    ///   • **Auto** — session-sticky routing with deterministic
    ///     escalation. Tier picked at session start by NL embedding
    ///     classifier; sticks unless confidence is high and a topic
    ///     shift demands change.
    ///   • **Deep** — pin Tier 3 (strongest configured cloud model).
    ///     Slower, costliest, best-quality coaching.
    ///   • **Manual** — every turn goes to whichever
    ///     provider+model the user picked in the model picker. The
    ///     escape hatch for users who want full control.
    var routingMode: RoutingMode = .manual

    /// Watch behavior mode.
    /// • `true` (default): the Watch is a passive remote/display. The
    ///   iPhone owns the Polar strap and the workout session; the Watch
    ///   shows live stats received via WatchConnectivity, no
    ///   HKWorkoutSession (so no Apple Health "Record a workout" prompt
    ///   triggered by the Watch), no direct BLE pairing UI.
    /// • `false`: the Watch may pair with the strap directly
    ///   and run its own HKWorkoutSession as a HR fallback. Kept for
    ///   users who genuinely want strap-on-Watch (rare) and as an
    ///   escape hatch.
    var watchDisplayOnlyMode: Bool = true

    // MARK: - Onboarding

    /// Whether the user has completed (or dismissed) the first-run onboarding wizard
    var hasCompletedOnboarding: Bool = false

    // MARK: - Algorithm migration
    //
    // The recovery score architecture changed from
    // HRV+Sleep+Training (50/20/30 with ACWR) to HRV+Sleep+Vitals
    // (60/25/15) — see RecoveryMethodologyView for the rationale. This
    // flag tracks whether the user has seen the one-time disclosure
    // modal explaining the change. Default `false` for existing users
    // (so they see the modal on next launch); flips to `true` when they
    // dismiss it. New users (post-update install) skip the modal because
    // their first score is computed under the new algorithm directly.

    /// True after the user has acknowledged the score-architecture
    /// change disclosure. Always true on a fresh install (post-onboarding
    /// completion writes both flags together).
    var hasAcknowledgedScoreArchitectureChange: Bool = false

    /// True after the one-shot history reanalyze has run (or the user
    /// declined it). Guards against re-running the migration on every
    /// app launch — once it's done, it's done. New users skip this
    /// because their first session is already under the new algorithm.
    var hasRunScoreHistoryRecompute: Bool = false

    /// Symmetric `abs(tempDev)` penalty bug fix.
    /// Sessions whose frozen score was computed under the buggy logic
    /// (penalized cooler-than-baseline temp readings) get a one-time
    /// silent rescore on the next launch when this flag is false.
    /// Default `true` for new installs (their first score is computed
    /// under the corrected logic directly). Returning users encode
    /// `false` via the migration on first launch with this build, get
    /// rescored once, then this flips to `true` permanently.
    var hasFixedTempAsymmetry: Bool = true

    // MARK: - Trial

    /// When the free trial started. Nil means no trial has been initiated.
    /// Set once after onboarding completes (first-time users only).
    var trialStartDate: Date?

    // MARK: - iCloud Sync

    /// Whether iCloud sync is enabled (backs up sessions to CloudKit private database)
    var iCloudSyncEnabled: Bool = true

    // MARK: - Appearance

    /// App appearance theme (light, dim, or dark background)
    var appearanceTheme: AppearanceTheme = .light

    /// Color theme for the primary accent color
    var colorTheme: ColorTheme = .blue

    // MARK: - AI / Tabs / UX preferences

    /// Force the AI to respond in English regardless of the device locale.
    /// When false (default), the AI mirrors the user's input language /
    /// device locale (a Japanese-locale phone gets Japanese responses).
    /// When true, all AI responses + voice synthesis stay in English.
    /// Useful when the user is bilingual and prefers AI in English even
    /// while their phone OS is in another language.
    var forceAIEnglish: Bool = false

    /// Hide the Fitness tab (workout recording, training-load surface).
    /// When true: the tab disappears from MainTabView entirely. Settings
    /// promotes to one of the visible 5; Trends moves into the More
    /// overflow. Recovery-only users (HRV + sleep, no workouts) get a
    /// cleaner UI without dead tabs they'll never tap.
    var hideFitnessTab: Bool = false

    // MARK: - Performance & Battery
    //
    // Master kill-switches for everything other than the core HRV +
    // Sleep recording loop. Default ON to preserve current behaviour
    // for existing users; iPhone-11 / older-device users can flip them
    // OFF to dodge the cold-start cost. Each toggle gates BOTH the UI
    // surface AND the singleton init (heavy classes peek the matching
    // UserDefaults key at startup before doing AVAudioSession / WCSession
    // / SKProductsRequest / network setup).

    /// Master switch for the AI Assistant tab + Coach reports + voice
    /// chat + provider registry. When OFF: the tab is hidden, no
    /// providers init, no API key prompts, no system-prompt builder
    /// runs. The medical-query guard still loads (tiny, no network).
    var enableAIAssistant: Bool = true

    /// Voice mode: speech recognition + AVSpeechSynthesizer + the
    /// voice-trigger engine. Independent of `enableAIAssistant` —
    /// the user can still text-chat with the AI but skip the heavy
    /// speech subsystem if they never use voice. When OFF:
    /// VoiceConversationController.shared returns early in init,
    /// AVAudioSession listeners aren't registered, mic isn't armed.
    var enableVoiceMode: Bool = true

    /// Apple Watch connectivity. When OFF: WatchConnectivityBridge
    /// skips WCSession activation. Useful for users without a paired
    /// Watch — the activation roundtrip still costs ~50-200ms at cold
    /// start even when no Watch is paired.
    var enableWatchConnectivity: Bool = true

    /// Keep screen on during active recording (overnight HRV, workouts,
    /// Polar device download). DEFAULT ON: matches the historical
    /// hardcoded-ON behaviour at every recording surface. The toggle
    /// in Settings → Performance & Battery lets battery-conscious
    /// users (or older devices) flip it off so iOS auto-lock kicks in.
    /// Kept ON by default to avoid surprising existing users with a
    /// behavioural regression on launch.
    var keepScreenOnDuringRecording: Bool = true

    /// UserDefaults mirror keys. The heavy singletons (which can init
    /// before SettingsManager.shared has finished loading the settings
    /// JSON from the App Group container) peek these keys directly.
    /// Write-through happens on every save in `SettingsManager.save()`.
    enum PerformanceFlagKey: String {
        case enableAIAssistant = "perf.enableAIAssistant"
        case enableVoiceMode = "perf.enableVoiceMode"
        case enableWatchConnectivity = "perf.enableWatchConnectivity"
    }

    /// Read a performance flag from UserDefaults at app-launch time
    /// (before SettingsManager.shared has finished reading the JSON
    /// settings file). Defaults to true if no value is set — preserves
    /// existing-user behaviour on first run after the toggles ship.
    static func performanceFlag(_ key: PerformanceFlagKey) -> Bool {
        let defaults = UserDefaults.standard
        if defaults.object(forKey: key.rawValue) == nil { return true }
        return defaults.bool(forKey: key.rawValue)
    }

    /// Should the app pin the screen awake during recording right now?
    /// True only when (a) the user opted in via the toggle AND (b) iOS
    /// Low Power Mode is OFF. LPM is the user explicitly telling the
    /// system "save battery" — overriding it with a private app
    /// preference would be rude ("doesn't obey her system battery
    /// prefs"). Every `isIdleTimerDisabled = true` site reads this
    /// instead of the raw toggle.
    var shouldKeepScreenOnDuringRecording: Bool {
        keepScreenOnDuringRecording && !ProcessInfo.processInfo.isLowPowerModeEnabled
    }

    // MARK: - Apple Health Export

    /// Whether to automatically export HRV metrics to Apple Health after each session
    var enableHealthKitExport: Bool = false

    /// Export SDNN to Apple Health (as heartRateVariabilitySDNN)
    var exportSDNN: Bool = true

    /// Export mean heart rate to Apple Health
    var exportHeartRate: Bool = true

    /// Export resting heart rate to Apple Health
    var exportRestingHeartRate: Bool = true

    /// Export sleep data to Apple Health (writes HRV-derived sleep stages as sleep samples)
    var exportSleepData: Bool = false

    // MARK: - Capture Mode

    /// Default capture mode for extended/overnight recordings.
    /// "both" = stream + device internal backup (default for maximum reliability).
    /// "streaming" = BLE streaming only, skip device fetch.
    /// "internalCapture" = device-only recording.
    var defaultCaptureMode: String = "both"

    /// Whether user is currently on a training break (within date range)
    var isOnTrainingBreak: Bool {
        guard let start = trainingBreakStartDate else { return false }
        let now = Date()
        let calendar = Calendar.current
        let today = calendar.startOfDay(for: now)
        let startDay = calendar.startOfDay(for: start)

        // Must be on or after start date
        guard today >= startDay else { return false }

        // If end date set, must be on or before end date
        if let end = trainingBreakEndDate {
            let endDay = calendar.startOfDay(for: end)
            return today <= endDay
        }

        return true // No end date = ongoing
    }

    // MARK: - Coding Keys and Migration

    /// Derived sleep schedule from bedtime + typical sleep hours.
    /// Use this everywhere instead of hardcoded clock assumptions.
    var sleepSchedule: SleepSchedule {
        let calendar = Calendar.current
        let components = calendar.dateComponents([.hour, .minute], from: expectedBedtime)
        return SleepSchedule(
            bedtimeHour: components.hour ?? 22,
            bedtimeMinute: components.minute ?? 0,
            sleepHours: typicalSleepHours
        )
    }

    /// The effective merge gap in seconds. Returns 0 for off, 4.5h for default, or custom value.
    var effectiveMergeGapSeconds: TimeInterval {
        switch sessionMergeMode {
        case .off: 0
        case .defaultGap: 4.5 * 60 * 60
        case .custom: customMergeGapHours * 60 * 60
        }
    }

    enum CodingKeys: String, CodingKey {
        case schemaVersion
        case customTags, birthday, fitnessLevel, biologicalSex
        case baselineRMSSD, baselineHR, typicalSleepHours, defaultWindowSelectionMethod
        case vo2MaxOverride, useHealthKitVO2Max, maxHR, lactateThresholdHR, bodyWeightKg, userRestingHR, homeAddress
        case runningFTPWatts, cyclingFTPWatts
        case enableZwiftBroadcast, enableWebSearch
        case defaultEmailRecipient, defaultEmailCC
        case defaultRecoveryEmailRecipient, defaultRecoveryEmailCC
        case defaultTrainingEmailRecipient, defaultTrainingEmailCC
        case enableSleepIntegration, enableHRVSleepAugmentation, penalizeMissingSleep
        case enableTrainingLoadIntegration
        case trainingBreakStartDate, trainingBreakEndDate, trainingBreakReason
        case comebackModeStartDate
        case peakingDetectionEnabled
        case intentionalOverreachActive
        case intentionalOverreachEndDate
        case dailyReportEnabled
        case dailyReportDelivery
        case dailyReportFixedTime
        case dailyReportFormat
        case hrvAnomalyAlertsEnabled
        case batteryLowAlertsEnabled
        case syncFailureAlertsEnabled
        case coachAlertsEnabled
        case enableMileMarkerNotifications
        case mileMarkerInterval
        case enableTurnByTurnAlerts
        case enableTurnMarkerUpdates
        case preferredSTTProvider
        case preserveClipboardForPaste
        case avatarImageData
        case temperatureUnit
        case trainingGoal
        case watchDisplayOnlyMode
        case smartProviderRoutingEnabled
        case routingMode
        case hasCompletedOnboarding, trialStartDate, iCloudSyncEnabled
        case hasAcknowledgedScoreArchitectureChange
        case hasRunScoreHistoryRecompute
        case hasFixedTempAsymmetry
        case expectedBedtime
        case sessionMergeMode, customMergeGapHours, sleepSplitGapMinutes
        case appearanceTheme, colorTheme
        case enableHealthKitExport, exportSDNN, exportHeartRate, exportRestingHeartRate, exportSleepData
        case defaultCaptureMode
        case forceAIEnglish, hideFitnessTab
        // Performance / battery toggles.
        case enableAIAssistant, enableVoiceMode, enableWatchConnectivity, keepScreenOnDuringRecording
    }

    /// Typical sleep in minutes (for calculations)
    var typicalSleepMinutes: Double {
        typicalSleepHours * 60.0
    }

    /// Computed age from birthday
    var age: Int? {
        guard let birthday else { return nil }
        let calendar = Calendar.current
        let ageComponents = calendar.dateComponents([.year], from: birthday, to: Date())
        return ageComponents.year
    }

    enum BiologicalSex: String, Codable, CaseIterable, Identifiable {
        case male = "Male"
        case female = "Female"
        case other = "Other/Prefer not to say"

        var id: String {
            rawValue
        }
    }

    init() {
        customTags = []
        typicalSleepHours = 8.0 // Default 8 hours, user should customize
        expectedBedtime = Calendar.current.date(from: DateComponents(hour: 22, minute: 0)) ?? Date()
        defaultWindowSelectionMethod = .consolidatedRecovery
        hasCompletedOnboarding = false
        iCloudSyncEnabled = true
    }

    /// All available tags (system + custom)
    var allTags: [ReadingTag] {
        ReadingTag.systemTags + customTags
    }

    /// Population baseline RMSSD by age (approximate values)
    var populationBaselineRMSSD: Double {
        guard let age else { return 35.0 }

        let baselineByAge = switch age {
        case ..<20: 55.0
        case 20 ..< 30: 45.0
        case 30 ..< 40: 38.0
        case 40 ..< 50: 32.0
        case 50 ..< 60: 27.0
        case 60 ..< 70: 22.0
        default: 18.0
        }

        let multiplier = fitnessLevel?.rmssdBaselineMultiplier ?? 1.0
        return baselineByAge * multiplier
    }
}
