import SwiftUI
import UserNotifications

/// Notifications settings.
///
/// Sections: the denied-permission banner, Daily Report (enable, delivery
/// Smart / Fixed, format Auto / Full / Teaser) and its live preview, workout
/// coach, periodic check-ins, turn alerts, and what is never sent.
///
/// There is no alerts section. Its three switches (HRV anomaly, strap
/// battery-low, sync failure) were never wired to anything that posts a
/// notification, and a setting that does nothing is a broken promise to the
/// user and to App Review (Guideline 2.1).
///
/// **No marketing pushes.** **No "New feature available!" pushes.**
/// **No re-engagement pushes.**
struct NotificationsSettingsPage: View {
    @Environment(\.dependencies) var dependencies
    private var settingsManager: SettingsManager { dependencies.app.settingsManager }
    @State private var systemAuthDenied: Bool = false

    var body: some View {
        withSchedulerSync(withChrome(bodyContent))
    }

    private var bodyContent: some View {
        Form {
            authorizationDeniedSection
            dailyReportSection
            dailyReportPreviewSection
            workoutCoachSection
            periodicCheckInsSection
            turnAlertsSection
            neverSentSection
        }
    }

    private func withChrome(_ content: some View) -> some View {
        content
            .navigationTitle(Text(String(localized: "Notifications", bundle: LanguageManager.appBundle)))
            .scrollContentBackground(.hidden)
            .background(AppTheme.background.ignoresSafeArea())
            .task { await checkAuthorisationStatus() }
    }

    /// Format is not watched: the set-time push carries no score, so only
    /// the wake push (built when it is sent) reads the format.
    private func withSchedulerSync(_ content: some View) -> some View {
        content
            .onChange(of: settingsManager.settings.dailyReportEnabled) { _, newValue in rescheduleForEnabledChange(newValue: newValue) }
            .onChange(of: settingsManager.settings.dailyReportFixedTime) { _, _ in reschedule() }
            .onChange(of: settingsManager.settings.dailyReportDelivery) { _, _ in reschedule() }
    }

    /// `rescheduleIfNeeded` handles the authorization check and cancels the
    /// push when the report is off.
    private func rescheduleForEnabledChange(newValue: Bool) {
        Task { @MainActor in
            if newValue {
                let status = await dependencies.services.morningNotificationScheduler.requestAuthorizationIfNeeded()
                systemAuthDenied = (status == .denied)
            }
            await dependencies.services.morningNotificationScheduler.rescheduleIfNeeded()
        }
    }

    private func reschedule() {
        Task { @MainActor in
            await dependencies.services.morningNotificationScheduler.rescheduleIfNeeded()
        }
    }

    @ViewBuilder
    private var authorizationDeniedSection: some View {
        if systemAuthDenied {
            Section {
                Text(String(localized: "Notifications are disabled in iOS Settings. Open Settings → Notifications → Emuqu to allow.", bundle: LanguageManager.appBundle))
                    .scaledFont(size: 13)
                    .foregroundStyle(AppTheme.wongCautionText)
            }
        }
    }

    private var dailyReportSection: some View {
        Section {
            dailyReportFields
        } header: {
            Text(String(localized: "Daily report", bundle: LanguageManager.appBundle))
        } footer: {
            dailyReportFooter
        }
    }

    @ViewBuilder
    private var dailyReportFields: some View {
        Toggle(isOn: Bindable(settingsManager).settings.dailyReportEnabled) {
            VStack(alignment: .leading, spacing: 2) {
                Text(String(localized: "Daily morning report", bundle: LanguageManager.appBundle))
                Text(settingsManager.settings.dailyReportEnabled
                    ? String(localized: "On", bundle: LanguageManager.appBundle)
                    : String(localized: "Off — no morning push will be sent", bundle: LanguageManager.appBundle))
                    .font(.caption)
                    .foregroundStyle(AppTheme.textTertiary)
            }
        }
        dailyReportOptions
    }

    @ViewBuilder
    private var dailyReportOptions: some View {
        if settingsManager.settings.dailyReportEnabled {
            Picker(String(localized: "Delivery", bundle: LanguageManager.appBundle), selection: Bindable(settingsManager).settings.dailyReportDelivery) {
                Text(String(localized: "Smart (when you wake)", bundle: LanguageManager.appBundle))
                    .tag(UserSettings.DailyReportDelivery.smart)
                Text(String(localized: "Fixed time", bundle: LanguageManager.appBundle))
                    .tag(UserSettings.DailyReportDelivery.fixed)
            }
            // Both modes send at this time: Fixed only then, Smart as the
            // fallback on mornings Apple Health records no wake.
            DatePicker(
                String(localized: "At", bundle: LanguageManager.appBundle),
                selection: Bindable(settingsManager).settings.dailyReportFixedTime,
                displayedComponents: .hourAndMinute
            )
            formatPicker
        }
    }

    /// Format shapes only the Smart wake push; the set-time push is
    /// scheduled ahead with fixed text and never carries a score.
    @ViewBuilder
    private var formatPicker: some View {
        if settingsManager.settings.dailyReportDelivery == .smart {
            Picker(String(localized: "Format", bundle: LanguageManager.appBundle), selection: Bindable(settingsManager).settings.dailyReportFormat) {
                Text(String(localized: "Auto", bundle: LanguageManager.appBundle)).tag(UserSettings.DailyReportFormat.auto)
                Text(String(localized: "Full readout", bundle: LanguageManager.appBundle)).tag(UserSettings.DailyReportFormat.full)
                Text(String(localized: "Teaser", bundle: LanguageManager.appBundle)).tag(UserSettings.DailyReportFormat.teaser)
            }
        }
    }

    @ViewBuilder
    private var dailyReportFooter: some View {
        if settingsManager.settings.dailyReportEnabled {
            enabledDailyReportFooter
        } else {
            Text(String(localized: "Once enabled, Emuqu sends a morning push about your recovery. Never marketing.", bundle: LanguageManager.appBundle))
        }
    }

    private var enabledDailyReportFooter: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(String(
                localized: "Smart sends as soon as Apple Health records the end of your sleep, and also at the set time as a fallback, so some mornings bring two. Fixed sends once, at the set time.",
                bundle: LanguageManager.appBundle
            ))
            if settingsManager.settings.dailyReportDelivery == .smart {
                Text(String(
                    localized: "Auto sends a short teaser until you have 30 nights of readings, then the score and guidance. Choose Full readout to get them in the notification from the start.",
                    bundle: LanguageManager.appBundle
                ))
            }
            Text(String(localized: "The push at the set time is prepared in advance, so it never shows a score.", bundle: LanguageManager.appBundle))
        }
    }

    @ViewBuilder
    private var dailyReportPreviewSection: some View {
        if settingsManager.settings.dailyReportEnabled {
            Section {
                notificationPreviewRow
                    .padding(8)
            } header: {
                Text(String(localized: "Preview", bundle: LanguageManager.appBundle))
            }
        }
    }

    private var notificationPreviewRow: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "bell.fill")
                .foregroundStyle(AppTheme.primary)
            VStack(alignment: .leading, spacing: 4) {
                Text(verbatim: "Emuqu")
                    .scaledFont(size: 13, weight: .semibold)
                Text(previewBody)
                    .scaledFont(size: 13)
                    .foregroundStyle(AppTheme.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private var workoutCoachSection: some View {
        Section {
            workoutCoachFields
        } header: {
            Text(String(localized: "Workout coach", bundle: LanguageManager.appBundle))
        } footer: {
            workoutCoachFooter
        }
    }

    @ViewBuilder
    private var workoutCoachFields: some View {
        Toggle(String(localized: "Coach alerts during workouts", bundle: LanguageManager.appBundle), isOn: Bindable(settingsManager).settings.coachAlertsEnabled)
    }

    @ViewBuilder
    private var workoutCoachFooter: some View {
        Text(String(localized: "When on, the coach speaks your own threshold alerts during a workout. Mile markers and turn alerts have their own switches. The speaker icon on the recording screen mutes the coach for the current session only.", bundle: LanguageManager.appBundle))
    }

    private var periodicCheckInsSection: some View {
        Section {
            periodicCheckInsFields
        } header: {
            Text(String(localized: "Periodic check-ins", bundle: LanguageManager.appBundle))
        } footer: {
            periodicCheckInsFooter
        }
    }

    @ViewBuilder
    private var periodicCheckInsFields: some View {
        Toggle(String(localized: "Mile-marker notifications", bundle: LanguageManager.appBundle), isOn: Bindable(settingsManager).settings.enableMileMarkerNotifications)
        mileMarkerIntervalPicker
    }

    @ViewBuilder
    private var mileMarkerIntervalPicker: some View {
        if settingsManager.settings.enableMileMarkerNotifications {
            intervalPicker
        }
    }

    private var intervalPicker: some View {
        Picker(String(localized: "Interval", bundle: LanguageManager.appBundle), selection: Bindable(settingsManager).settings.mileMarkerInterval) {
            ForEach(MileMarkerInterval.allCases, id: \.self) { interval in
                Text(interval.displayName).tag(interval)
            }
        }
    }

    @ViewBuilder
    private var periodicCheckInsFooter: some View {
        Text(String(localized: "Off by default. When on, the coach announces split time, pace, HR zone, and total distance at each marker. Cadence and elevation gain are skipped when normal (in-band cadence and flat splits stay quiet). Notifications are queued during AI conversations and never wipe an in-progress message.", bundle: LanguageManager.appBundle))
    }

    private var turnAlertsSection: some View {
        Section {
            turnAlertsFields
        } header: {
            Text(String(localized: "Navigation (when a route is engaged)", bundle: LanguageManager.appBundle))
        } footer: {
            turnAlertsFooter
        }
    }

    @ViewBuilder
    private var turnAlertsFields: some View {
        Toggle(String(localized: "Turn-by-turn voice alerts", bundle: LanguageManager.appBundle), isOn: Bindable(settingsManager).settings.enableTurnByTurnAlerts)
        Toggle(String(localized: "Turn-as-marker split updates", bundle: LanguageManager.appBundle), isOn: Bindable(settingsManager).settings.enableTurnMarkerUpdates)
    }

    @ViewBuilder
    private var turnAlertsFooter: some View {
        Text(String(localized: "Both off by default — only meaningful after you've asked the Coach to load a route (\"take me home\", \"to the parking lot\", \"to Lakeside Park\"). Turn alerts fire at ~500 ft, ~200 ft, and AT each turn (metric: 150 m / 60 m / 0). Turn-as-marker updates fire AFTER each completed turn with the leg's time, pace, and HR — the same data as mile markers but bucketed by route segment. Alerts queue around in-flight AI conversations.", bundle: LanguageManager.appBundle))
    }

    private var neverSentSection: some View {
        Section {
            neverSentFields
        } header: {
            Text(String(localized: "What you'll never get", bundle: LanguageManager.appBundle))
        }
    }

    @ViewBuilder
    private var neverSentFields: some View {
        Text(String(localized: "Emuqu never sends marketing or re-engagement pushes.", bundle: LanguageManager.appBundle))
            .scaledFont(size: 12)
            .foregroundStyle(AppTheme.textTertiary)
    }

    /// What the user will actually receive: in Fixed mode the number-free
    /// set-time push, in Smart mode the wake push in the chosen format.
    private var previewBody: String {
        guard settingsManager.settings.dailyReportDelivery == .smart else {
            return MorningNotificationScheduler.buildPayload().1
        }
        switch effectiveFormat() {
        case .full:
            return String(localized: "Recovery 84 · A good score — normal training fits today.", bundle: LanguageManager.appBundle)
        case .teaser:
            return String(localized: "Your recovery is in.", bundle: LanguageManager.appBundle)
        case .auto:
            return String(localized: "Your recovery is in.", bundle: LanguageManager.appBundle)  // unreachable; effectiveFormat resolves it.
        }
    }

    private func effectiveFormat() -> UserSettings.DailyReportFormat {
        switch settingsManager.settings.dailyReportFormat {
        case .full: return .full
        case .teaser: return .teaser
        case .auto:
            // The same rule the scheduler sends with.
            return MorningNotificationScheduler.resolvedFormat(.auto, archive: AppDependencies.current.storage.sessionArchive)
        }
    }

    @MainActor
    private func checkAuthorisationStatus() async {
        let center = UNUserNotificationCenter.current()
        let settings = await center.notificationSettings()
        systemAuthDenied = settings.authorizationStatus == .denied
    }
}
