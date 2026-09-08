import SwiftUI
import UserNotifications

/// Build plan §4.6 M3.5 — Notifications settings.
///
/// Two sections:
///   • Daily Report — enable, delivery (Smart / Fixed), format
///     (Auto / Full / Teaser), live preview
///   • Alerts — HRV anomaly / battery-low / sync failure
///
/// **No marketing pushes.** **No "New feature available!" pushes.**
/// **One re-engagement push only** at 14-day inactivity (handled by the
/// notification scheduler, not toggleable here).
struct NotificationsSettingsPage: View {
    @Environment(\.dependencies) var dependencies
    private var settingsManager: SettingsManager { dependencies.app.settingsManager }
    @Environment(RRCollector.self) private var collector
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
            systemAlertsSection
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

    private func withSchedulerSync(_ content: some View) -> some View {
        content
            .onChange(of: settingsManager.settings.dailyReportEnabled) { _, newValue in rescheduleForEnabledChange(newValue: newValue) }
            .onChange(of: settingsManager.settings.dailyReportFixedTime) { _, _ in rescheduleForFixedTime() }
            .onChange(of: settingsManager.settings.dailyReportDelivery) { _, _ in rescheduleForDelivery() }
            .onChange(of: settingsManager.settings.dailyReportFormat) { _, _ in rescheduleForFormat() }
    }

    private func rescheduleForEnabledChange(newValue: Bool) {
        Task { @MainActor in
            if newValue {
                // Plan §D11 — wire the toggle, delivery, fixed-time, and
                // format pickers to the actual scheduler. Every change calls
                // `rescheduleIfNeeded` (which itself handles the auth check
                // and the cancel-when-disabled path).
                let status = await dependencies.services.morningNotificationScheduler.requestAuthorizationIfNeeded()
                systemAuthDenied = (status == .denied)
            }
            await dependencies.services.morningNotificationScheduler.rescheduleIfNeeded(collector: collector)
        }
    }

    private func rescheduleForFixedTime() {
        Task { @MainActor in
            await dependencies.services.morningNotificationScheduler.rescheduleIfNeeded(collector: collector)
        }
    }

    private func rescheduleForDelivery() {
        Task { @MainActor in
            await dependencies.services.morningNotificationScheduler.rescheduleIfNeeded(collector: collector)
        }
    }

    private func rescheduleForFormat() {
        Task { @MainActor in
            await dependencies.services.morningNotificationScheduler.rescheduleIfNeeded(collector: collector)
        }
    }

    @ViewBuilder
    private var authorizationDeniedSection: some View {
        if systemAuthDenied {
            Section {
                Text(String(localized: "Notifications are disabled in iOS Settings. Open Settings → Notifications → Emuqu to allow.", bundle: LanguageManager.appBundle))
                    .scaledFont(size: 13)
                    .foregroundStyle(AppTheme.wongCaution)
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
                Text(String(localized: "Smart (sleep-end + 5 min)", bundle: LanguageManager.appBundle))
                    .tag(UserSettings.DailyReportDelivery.smart)
                Text(String(localized: "Fixed time", bundle: LanguageManager.appBundle))
                    .tag(UserSettings.DailyReportDelivery.fixed)
            }
            if settingsManager.settings.dailyReportDelivery == .fixed {
                DatePicker(
                    String(localized: "At", bundle: LanguageManager.appBundle),
                    selection: Bindable(settingsManager).settings.dailyReportFixedTime,
                    displayedComponents: .hourAndMinute
                )
            }
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
            Text(String(localized: "Smart sends 5 minutes after iOS detects sleep end. Fixed always sends at the same time. Auto format sends a short teaser — open the app for the full readout. Choose Full readout to get the score and guidance right in the notification.", bundle: LanguageManager.appBundle))
        } else {
            Text(String(localized: "Once enabled, Emuqu sends one morning push per day with your recovery score. Never marketing — never twice.", bundle: LanguageManager.appBundle))
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
        Text(String(localized: "Master switch for in-workout audible / haptic coaching (HR-spike calls, drift, terrain, mile splits). Off = the recording timeline still logs what would have triggered, but the coach stays silent. The speaker icon on the recording screen also mutes the coach for the current session only.", bundle: LanguageManager.appBundle))
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
                Text(verbatim: interval.displayName).tag(interval)
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
        Text(String(localized: "Both off by default — only meaningful after you've asked the Coach to load a route (\"take me home\", \"to the parking lot\", \"to Sequoyah Park\"). Turn alerts fire at ~500 ft, ~200 ft, and AT each turn (metric: 150 m / 60 m / 0). Turn-as-marker updates fire AFTER each completed turn with the leg's time, pace, and HR — the same data as mile markers but bucketed by route segment. Alerts queue around in-flight AI conversations.", bundle: LanguageManager.appBundle))
    }

    private var systemAlertsSection: some View {
        Section {
            systemAlertsFields
        } header: {
            Text(String(localized: "System alerts", bundle: LanguageManager.appBundle))
        } footer: {
            systemAlertsFooter
        }
    }

    @ViewBuilder
    private var systemAlertsFields: some View {
        Toggle(String(localized: "HRV anomaly alerts", bundle: LanguageManager.appBundle), isOn: Bindable(settingsManager).settings.hrvAnomalyAlertsEnabled)
        Toggle(String(localized: "Strap battery-low alerts", bundle: LanguageManager.appBundle), isOn: Bindable(settingsManager).settings.batteryLowAlertsEnabled)
        Toggle(String(localized: "iCloud sync failure alerts", bundle: LanguageManager.appBundle), isOn: Bindable(settingsManager).settings.syncFailureAlertsEnabled)
    }

    @ViewBuilder
    private var systemAlertsFooter: some View {
        Text(String(localized: "HRV alerts are off by default — they can be noisy. Battery-low and sync-failure alerts surface real problems that cost you data if missed.", bundle: LanguageManager.appBundle))
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
        Text(String(localized: "Emuqu never sends marketing pushes. The only re-engagement push fires once at 14 days of inactivity, then never again.", bundle: LanguageManager.appBundle))
            .scaledFont(size: 12)
            .foregroundStyle(AppTheme.textTertiary)
    }

    /// Build plan §6.13 — verbatim teaser / full-readout templates.
    private var previewBody: String {
        let format = effectiveFormat()
        switch format {
        case .full:
            return String(localized: "Recovery 84 · Normal training is fine — body is well-rested.", bundle: LanguageManager.appBundle)
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
            // Auto currently always resolves to a teaser (open the app
            // for the full readout). The day-30 "graduate to full readout"
            // switch is not wired yet — this view has no access to a
            // first-reading date — so keep the resolved format honest.
            return .teaser
        }
    }

    @MainActor
    private func checkAuthorisationStatus() async {
        let center = UNUserNotificationCenter.current()
        let settings = await center.notificationSettings()
        systemAuthDenied = settings.authorizationStatus == .denied
    }
}
