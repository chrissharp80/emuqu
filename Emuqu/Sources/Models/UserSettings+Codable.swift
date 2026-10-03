import Foundation

// `UserSettings`' hand-written `Codable` conformance, split out of
// `UserSettings+Model.swift` to keep that file under the 1000-line
// limit. The decoder is not one monolithic initializer: it seeds
// `self` from the designated `init()` and then fills each settings domain from
// its own small function, mirroring the grouping the encoder uses.
//
// This file is
// the app's forward/backward compatibility surface — a changed default here is
// a silent behaviour change for existing users, not a formatting choice.

extension UserSettings {

    /// One decode-with-a-default, in one place.
    ///
    /// Eighty call sites spelled this out as
    /// `(try? container.decode(T.self, forKey: k)) ?? d`. That form swallows
    /// two different failures with the same silence: a key that is ABSENT —
    /// expected, this file is the compatibility surface — and a key whose value
    /// is the wrong TYPE, which is a corrupt payload and the only one worth
    /// knowing about. Funnelling them here keeps the tolerance exactly as it
    /// was and adds the trace: a present-but-unreadable setting now says so,
    /// once, instead of resetting to its default without a word.
    static func decoded<T: Decodable>(
        _ type: T.Type,
        _ key: CodingKeys,
        from container: KeyedDecodingContainer<CodingKeys>,
        default fallback: T
    ) -> T {
        optional(type, key, from: container) ?? fallback
    }

    /// The nil-defaulting variant, for fields whose absence is itself the value.
    static func optional<T: Decodable>(
        _ type: T.Type,
        _ key: CodingKeys,
        from container: KeyedDecodingContainer<CodingKeys>
    ) -> T? {
        do {
            return try container.decodeIfPresent(type, forKey: key)
        } catch {
            debugLog("[UserSettings] \(key.stringValue) present but unreadable — using the default: \(error)", level: .warning)
            return nil
        }
    }
    /// Decode with a default for every field, so a schema change never drops a
    /// user's settings — an absent key falls back to the documented default
    /// rather than failing the whole decode.
    init(from decoder: Decoder) throws {
        self.init()
        let container = try decoder.container(keyedBy: CodingKeys.self)
        decodeProfile(from: container)
        decodeFitnessMarkers(from: container)
        decodeEmailDefaults(from: container)
        decodeTrainingState(from: container)
        decodeNotifications(from: container)
        decodeAppearance(from: container)
        decodeRoutingMode(from: container)
        decodeOnboarding(from: container)
        decodeExportAndPerformance(from: container)
        decodeCoachAutomation(from: container)
    }

    /// Identity, sleep schedule and session-merge preferences.
    ///
    /// `typicalSleepHours` is clamped to a physiologically sane 3–14 h: a
    /// corrupt or absurd encoded value (0, negative, 500) would otherwise poison
    /// sleep-completion ratios everywhere downstream. `customMergeGapHours` is
    /// clamped to its documented 1–12 range and the split gap to non-negative,
    /// for the same reason. The schema version is absent in legacy data and
    /// decodes as 0, so a future migration can dispatch on it.
    private mutating func decodeProfile(from container: KeyedDecodingContainer<CodingKeys>) {
        sourceSchemaVersion = Self.decoded(Int.self, .schemaVersion, from: container, default: 0)
        customTags = Self.decoded([ReadingTag].self, .customTags, from: container, default: [])
        birthday = Self.optional(Date.self, .birthday, from: container)
        fitnessLevel = Self.optional(FitnessLevel.self, .fitnessLevel, from: container)
        biologicalSex = Self.optional(BiologicalSex.self, .biologicalSex, from: container)
        baselineRMSSD = Self.optional(Double.self, .baselineRMSSD, from: container)
        baselineHR = Self.optional(Double.self, .baselineHR, from: container)
        typicalSleepHours = min(14.0, max(3.0, Self.decoded(Double.self, .typicalSleepHours, from: container, default: 8.0)))
        defaultWindowSelectionMethod = Self.decoded(WindowSelectionMethod.self, .defaultWindowSelectionMethod, from: container, default: .consolidatedRecovery)
        expectedBedtime = (Self.optional(Date.self, .expectedBedtime, from: container))
            ?? Calendar.current.date(from: DateComponents(hour: 22, minute: 0)) ?? Date()
        sessionMergeMode = Self.decoded(SessionMergeMode.self, .sessionMergeMode, from: container, default: .defaultGap)
        customMergeGapHours = min(12.0, max(1.0, Self.decoded(Double.self, .customMergeGapHours, from: container, default: 4.5)))
        sleepSplitGapMinutes = max(0, Self.decoded(Int.self, .sleepSplitGapMinutes, from: container, default: 20))
    }

    /// Physiological markers and the thresholds derived from them.
    ///
    /// A present `maxHR` is clamped to 100–240 bpm; absent stays absent, because
    /// "no maximum recorded" and "maximum of 100" drive different zone maths.
    private mutating func decodeFitnessMarkers(from container: KeyedDecodingContainer<CodingKeys>) {
        vo2MaxOverride = Self.optional(Double.self, .vo2MaxOverride, from: container)
        useHealthKitVO2Max = Self.decoded(Bool.self, .useHealthKitVO2Max, from: container, default: false)
        maxHR = (Self.optional(Int.self, .maxHR, from: container)).map { min(240, max(100, $0)) }
        lactateThresholdHR = Self.optional(Int.self, .lactateThresholdHR, from: container)
        bodyWeightKg = Self.optional(Double.self, .bodyWeightKg, from: container)
        userRestingHR = Self.optional(Int.self, .userRestingHR, from: container)
        homeAddress = Self.optional(String.self, .homeAddress, from: container)
        runningFTPWatts = Self.optional(Int.self, .runningFTPWatts, from: container)
        cyclingFTPWatts = Self.optional(Int.self, .cyclingFTPWatts, from: container)
        enableZwiftBroadcast = Self.decoded(Bool.self, .enableZwiftBroadcast, from: container, default: false)
        enableWebSearch = Self.decoded(Bool.self, .enableWebSearch, from: container, default: false)
    }

    /// Report email recipients, per category.
    ///
    /// Legacy migration — a user who only ever set the old single default fields
    /// (pre-categorisation) has both new categories seeded from that value, so
    /// behaviour is unchanged. The separate settings then override per category
    /// as the user updates them.
    private mutating func decodeEmailDefaults(from container: KeyedDecodingContainer<CodingKeys>) {
        defaultEmailRecipient = Self.optional(String.self, .defaultEmailRecipient, from: container)
        defaultEmailCC = Self.optional(String.self, .defaultEmailCC, from: container)
        defaultRecoveryEmailRecipient = Self.optional(String.self, .defaultRecoveryEmailRecipient, from: container)
        defaultRecoveryEmailCC = Self.optional(String.self, .defaultRecoveryEmailCC, from: container)
        defaultTrainingEmailRecipient = Self.optional(String.self, .defaultTrainingEmailRecipient, from: container)
        defaultTrainingEmailCC = Self.optional(String.self, .defaultTrainingEmailCC, from: container)
        if defaultRecoveryEmailRecipient == nil { defaultRecoveryEmailRecipient = defaultEmailRecipient }
        if defaultRecoveryEmailCC == nil { defaultRecoveryEmailCC = defaultEmailCC }
        if defaultTrainingEmailRecipient == nil { defaultTrainingEmailRecipient = defaultEmailRecipient }
        if defaultTrainingEmailCC == nil { defaultTrainingEmailCC = defaultEmailCC }
    }

    /// Sleep/training integration, training breaks, comeback and overreach state.
    private mutating func decodeTrainingState(from container: KeyedDecodingContainer<CodingKeys>) {
        enableSleepIntegration = Self.decoded(Bool.self, .enableSleepIntegration, from: container, default: true)
        enableHRVSleepAugmentation = Self.decoded(Bool.self, .enableHRVSleepAugmentation, from: container, default: false)
        penalizeMissingSleep = Self.decoded(Bool.self, .penalizeMissingSleep, from: container, default: false)
        enableTrainingLoadIntegration = Self.decoded(Bool.self, .enableTrainingLoadIntegration, from: container, default: true)
        trainingBreakStartDate = Self.optional(Date.self, .trainingBreakStartDate, from: container)
        trainingBreakEndDate = Self.optional(Date.self, .trainingBreakEndDate, from: container)
        trainingBreakReason = Self.optional(String.self, .trainingBreakReason, from: container)
        comebackModeStartDate = Self.optional(Date.self, .comebackModeStartDate, from: container)
        peakingDetectionEnabled = Self.decoded(Bool.self, .peakingDetectionEnabled, from: container, default: true)
        intentionalOverreachActive = Self.decoded(Bool.self, .intentionalOverreachActive, from: container, default: false)
        intentionalOverreachEndDate = Self.optional(Date.self, .intentionalOverreachEndDate, from: container)
        trainingGoal = Self.decoded(TrainingGoal.self, .trainingGoal, from: container, default: .maintain)
    }

    /// Daily report scheduling plus every alert toggle.
    private mutating func decodeNotifications(from container: KeyedDecodingContainer<CodingKeys>) {
        dailyReportEnabled = Self.decoded(Bool.self, .dailyReportEnabled, from: container, default: false)
        dailyReportDelivery = Self.decoded(DailyReportDelivery.self, .dailyReportDelivery, from: container, default: .smart)
        if let fixedTime = Self.optional(Date.self, .dailyReportFixedTime, from: container) {
            dailyReportFixedTime = fixedTime
        }
        dailyReportFormat = Self.decoded(DailyReportFormat.self, .dailyReportFormat, from: container, default: .auto)
        hrvAnomalyAlertsEnabled = Self.decoded(Bool.self, .hrvAnomalyAlertsEnabled, from: container, default: false)
        batteryLowAlertsEnabled = Self.decoded(Bool.self, .batteryLowAlertsEnabled, from: container, default: true)
        syncFailureAlertsEnabled = Self.decoded(Bool.self, .syncFailureAlertsEnabled, from: container, default: true)
        coachAlertsEnabled = Self.decoded(Bool.self, .coachAlertsEnabled, from: container, default: true)
        enableMileMarkerNotifications = Self.decoded(Bool.self, .enableMileMarkerNotifications, from: container, default: false)
        mileMarkerInterval = Self.decoded(MileMarkerInterval.self, .mileMarkerInterval, from: container, default: .everyDistanceUnit)
        enableTurnByTurnAlerts = Self.decoded(Bool.self, .enableTurnByTurnAlerts, from: container, default: false)
        enableTurnMarkerUpdates = Self.decoded(Bool.self, .enableTurnMarkerUpdates, from: container, default: false)
    }

    /// Theme, units, avatar and the voice/watch presentation preferences.
    private mutating func decodeAppearance(from container: KeyedDecodingContainer<CodingKeys>) {
        appearanceTheme = Self.decoded(AppearanceTheme.self, .appearanceTheme, from: container, default: .light)
        do {
            colorTheme = try container.decode(ColorTheme.self, forKey: .colorTheme)
        } catch {
            debugLog("[UserSettings] colorTheme decode failed, falling back to .blue: \(error)")
            colorTheme = .blue
        }
        temperatureUnit = Self.decoded(TemperatureUnit.self, .temperatureUnit, from: container, default: .fahrenheit)
        avatarImageData = Self.optional(Data.self, .avatarImageData, from: container)
        watchDisplayOnlyMode = Self.decoded(Bool.self, .watchDisplayOnlyMode, from: container, default: true)
        preferredSTTProvider = Self.decoded(STTProviderKind.self, .preferredSTTProvider, from: container, default: .apple)
        preserveClipboardForPaste = Self.decoded(Bool.self, .preserveClipboardForPaste, from: container, default: true)
    }

    /// Migrate v1 → v2: the old `smartProviderRoutingEnabled` Bool meant "Auto".
    /// Take the new enum if present; otherwise translate the legacy bool.
    /// Default is `.manual`, which is the behaviour that existed before either.
    private mutating func decodeRoutingMode(from container: KeyedDecodingContainer<CodingKeys>) {
        if let mode = Self.optional(RoutingMode.self, .routingMode, from: container) {
            routingMode = mode
        } else if let legacyBool = Self.optional(Bool.self, .smartProviderRoutingEnabled, from: container) {
            routingMode = legacyBool ? .auto : .manual
        } else {
            routingMode = .manual
        }
    }

    /// Onboarding, one-time migration flags, trial, iCloud and heat tracking.
    ///
    /// `hasCompletedOnboarding` defaults to true so existing users are not sent
    /// back through onboarding. The three migration flags default to **false**
    /// on decode so a returning user runs each one-time migration exactly once;
    /// a fresh install encodes `true` directly from the in-memory default and
    /// skips them.
    private mutating func decodeOnboarding(from container: KeyedDecodingContainer<CodingKeys>) {
        hasCompletedOnboarding = Self.decoded(Bool.self, .hasCompletedOnboarding, from: container, default: true)
        hasAcknowledgedScoreArchitectureChange = Self.decoded(Bool.self, .hasAcknowledgedScoreArchitectureChange, from: container, default: false)
        hasRunScoreHistoryRecompute = Self.decoded(Bool.self, .hasRunScoreHistoryRecompute, from: container, default: false)
        hasFixedTempAsymmetry = Self.decoded(Bool.self, .hasFixedTempAsymmetry, from: container, default: false)
        trialStartDate = Self.optional(Date.self, .trialStartDate, from: container)
        iCloudSyncEnabled = Self.decoded(Bool.self, .iCloudSyncEnabled, from: container, default: true)
        // False for everyone, existing users included: nobody has agreed to the
        // Open-Meteo lookup until they tap the button that explains it.
        heatTrackingEnabled = Self.decoded(Bool.self, .heatTrackingEnabled, from: container, default: false)
    }

    /// The coach report and periodic-coach settings, with the model's
    /// defaults when absent.
    private mutating func decodeCoachAutomation(from container: KeyedDecodingContainer<CodingKeys>) {
        enablePeriodicCoachUpdates = Self.decoded(Bool.self, .enablePeriodicCoachUpdates, from: container, default: true)
        periodicCoachCadenceSec = Self.decoded(Int.self, .periodicCoachCadenceSec, from: container, default: 300)
        enableAutoCoachReport = Self.decoded(Bool.self, .enableAutoCoachReport, from: container, default: false)
    }

    private func encodeCoachAutomation(into container: inout KeyedEncodingContainer<CodingKeys>) throws {
        try container.encode(enablePeriodicCoachUpdates, forKey: .enablePeriodicCoachUpdates)
        try container.encode(periodicCoachCadenceSec, forKey: .periodicCoachCadenceSec)
        try container.encode(enableAutoCoachReport, forKey: .enableAutoCoachReport)
    }

    /// Apple Health export, capture mode, and the AI / battery toggles.
    /// Defaults preserve prior behaviour: assistant features on, screen managed
    /// by iOS, and no silent Health writes for a user who never opted in.
    private mutating func decodeExportAndPerformance(from container: KeyedDecodingContainer<CodingKeys>) {
        enableHealthKitExport = Self.decoded(Bool.self, .enableHealthKitExport, from: container, default: false)
        exportSDNN = Self.decoded(Bool.self, .exportSDNN, from: container, default: true)
        exportHeartRate = Self.decoded(Bool.self, .exportHeartRate, from: container, default: true)
        exportRestingHeartRate = Self.decoded(Bool.self, .exportRestingHeartRate, from: container, default: true)
        exportSleepData = Self.decoded(Bool.self, .exportSleepData, from: container, default: false)
        defaultCaptureMode = Self.decoded(String.self, .defaultCaptureMode, from: container, default: "both")
        forceAIEnglish = Self.decoded(Bool.self, .forceAIEnglish, from: container, default: false)
        hideFitnessTab = Self.decoded(Bool.self, .hideFitnessTab, from: container, default: false)
        enableAIAssistant = Self.decoded(Bool.self, .enableAIAssistant, from: container, default: true)
        enableVoiceMode = Self.decoded(Bool.self, .enableVoiceMode, from: container, default: true)
        enableWatchConnectivity = Self.decoded(Bool.self, .enableWatchConnectivity, from: container, default: true)
        // `?? true`, matching the in-memory default. The declaration says the
        // toggle is "Kept ON by default to avoid surprising existing users with
        // a behavioural regression on launch" — and defaulting the DECODE to
        // false did exactly that: every user whose stored settings predate the
        // key got auto-lock during recording, which is the regression the
        // default exists to prevent. Unlike the migration flags, this is a
        // preference, not a one-shot marker, so it has no reason to differ.
        keepScreenOnDuringRecording = Self.decoded(Bool.self, .keepScreenOnDuringRecording, from: container, default: true)
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try encodeProfile(into: &container)
        try encodeFitnessMarkers(into: &container)
        try encodeEmailDefaults(into: &container)
        try encodeTrainingState(into: &container)
        try encodeNotifications(into: &container)
        try encodeAppearance(into: &container)
        try encodeExportAndPerformance(into: &container)
        try encodeCoachAutomation(into: &container)
    }

    /// Identity, sleep schedule and session-merge preferences.
    private func encodeProfile(into container: inout KeyedEncodingContainer<CodingKeys>) throws {
        try container.encode(Self.currentSchemaVersion, forKey: .schemaVersion)
        try container.encode(customTags, forKey: .customTags)
        try container.encodeIfPresent(birthday, forKey: .birthday)
        try container.encodeIfPresent(fitnessLevel, forKey: .fitnessLevel)
        try container.encodeIfPresent(biologicalSex, forKey: .biologicalSex)
        try container.encodeIfPresent(baselineRMSSD, forKey: .baselineRMSSD)
        try container.encodeIfPresent(baselineHR, forKey: .baselineHR)
        try container.encode(typicalSleepHours, forKey: .typicalSleepHours)
        try container.encode(expectedBedtime, forKey: .expectedBedtime)
        try container.encode(sessionMergeMode, forKey: .sessionMergeMode)
        try container.encode(customMergeGapHours, forKey: .customMergeGapHours)
        try container.encode(sleepSplitGapMinutes, forKey: .sleepSplitGapMinutes)
        try container.encode(defaultWindowSelectionMethod, forKey: .defaultWindowSelectionMethod)
    }

    /// Physiological markers and the thresholds derived from them.
    private func encodeFitnessMarkers(into container: inout KeyedEncodingContainer<CodingKeys>) throws {
        try container.encodeIfPresent(vo2MaxOverride, forKey: .vo2MaxOverride)
        try container.encode(useHealthKitVO2Max, forKey: .useHealthKitVO2Max)
        try container.encodeIfPresent(maxHR, forKey: .maxHR)
        try container.encodeIfPresent(lactateThresholdHR, forKey: .lactateThresholdHR)
        try container.encodeIfPresent(bodyWeightKg, forKey: .bodyWeightKg)
        try container.encodeIfPresent(userRestingHR, forKey: .userRestingHR)
        try container.encodeIfPresent(homeAddress, forKey: .homeAddress)
        try container.encodeIfPresent(runningFTPWatts, forKey: .runningFTPWatts)
        try container.encodeIfPresent(cyclingFTPWatts, forKey: .cyclingFTPWatts)
        try container.encode(enableZwiftBroadcast, forKey: .enableZwiftBroadcast)
        try container.encode(enableWebSearch, forKey: .enableWebSearch)
    }

    /// Default recipients for the three report emails.
    private func encodeEmailDefaults(into container: inout KeyedEncodingContainer<CodingKeys>) throws {
        try container.encodeIfPresent(defaultEmailRecipient, forKey: .defaultEmailRecipient)
        try container.encodeIfPresent(defaultEmailCC, forKey: .defaultEmailCC)
        try container.encodeIfPresent(defaultRecoveryEmailRecipient, forKey: .defaultRecoveryEmailRecipient)
        try container.encodeIfPresent(defaultRecoveryEmailCC, forKey: .defaultRecoveryEmailCC)
        try container.encodeIfPresent(defaultTrainingEmailRecipient, forKey: .defaultTrainingEmailRecipient)
        try container.encodeIfPresent(defaultTrainingEmailCC, forKey: .defaultTrainingEmailCC)
    }

    /// Sleep/training integration plus the training-state windows —
    /// breaks, comebacks, peaking and intentional overreach.
    private func encodeTrainingState(into container: inout KeyedEncodingContainer<CodingKeys>) throws {
        try container.encode(enableSleepIntegration, forKey: .enableSleepIntegration)
        try container.encode(enableHRVSleepAugmentation, forKey: .enableHRVSleepAugmentation)
        try container.encode(penalizeMissingSleep, forKey: .penalizeMissingSleep)
        try container.encode(enableTrainingLoadIntegration, forKey: .enableTrainingLoadIntegration)
        try container.encodeIfPresent(trainingBreakStartDate, forKey: .trainingBreakStartDate)
        try container.encodeIfPresent(trainingBreakEndDate, forKey: .trainingBreakEndDate)
        try container.encodeIfPresent(trainingBreakReason, forKey: .trainingBreakReason)
        try container.encodeIfPresent(comebackModeStartDate, forKey: .comebackModeStartDate)
        try container.encode(peakingDetectionEnabled, forKey: .peakingDetectionEnabled)
        try container.encode(intentionalOverreachActive, forKey: .intentionalOverreachActive)
        try container.encodeIfPresent(intentionalOverreachEndDate, forKey: .intentionalOverreachEndDate)
    }

    /// Daily report, alert toggles, and the in-workout announcements.
    private func encodeNotifications(into container: inout KeyedEncodingContainer<CodingKeys>) throws {
        try container.encode(dailyReportEnabled, forKey: .dailyReportEnabled)
        try container.encode(dailyReportDelivery, forKey: .dailyReportDelivery)
        try container.encode(dailyReportFixedTime, forKey: .dailyReportFixedTime)
        try container.encode(dailyReportFormat, forKey: .dailyReportFormat)
        try container.encode(hrvAnomalyAlertsEnabled, forKey: .hrvAnomalyAlertsEnabled)
        try container.encode(batteryLowAlertsEnabled, forKey: .batteryLowAlertsEnabled)
        try container.encode(syncFailureAlertsEnabled, forKey: .syncFailureAlertsEnabled)
        try container.encode(coachAlertsEnabled, forKey: .coachAlertsEnabled)
        try container.encode(enableMileMarkerNotifications, forKey: .enableMileMarkerNotifications)
        try container.encode(mileMarkerInterval, forKey: .mileMarkerInterval)
        try container.encode(enableTurnByTurnAlerts, forKey: .enableTurnByTurnAlerts)
        try container.encode(enableTurnMarkerUpdates, forKey: .enableTurnMarkerUpdates)
        try container.encode(preferredSTTProvider, forKey: .preferredSTTProvider)
        try container.encode(preserveClipboardForPaste, forKey: .preserveClipboardForPaste)
    }

    /// Avatar, units, theme and the one-shot onboarding flags.
    private func encodeAppearance(into container: inout KeyedEncodingContainer<CodingKeys>) throws {
        try container.encodeIfPresent(avatarImageData, forKey: .avatarImageData)
        try container.encode(temperatureUnit, forKey: .temperatureUnit)
        try container.encode(trainingGoal, forKey: .trainingGoal)
        try container.encode(watchDisplayOnlyMode, forKey: .watchDisplayOnlyMode)
        try container.encode(routingMode, forKey: .routingMode)
        try container.encode(hasCompletedOnboarding, forKey: .hasCompletedOnboarding)
        try container.encode(hasAcknowledgedScoreArchitectureChange, forKey: .hasAcknowledgedScoreArchitectureChange)
        try container.encode(hasRunScoreHistoryRecompute, forKey: .hasRunScoreHistoryRecompute)
        try container.encode(hasFixedTempAsymmetry, forKey: .hasFixedTempAsymmetry)
        try container.encodeIfPresent(trialStartDate, forKey: .trialStartDate)
        try container.encode(iCloudSyncEnabled, forKey: .iCloudSyncEnabled)
        try container.encode(heatTrackingEnabled, forKey: .heatTrackingEnabled)
        try container.encode(appearanceTheme, forKey: .appearanceTheme)
        try container.encode(colorTheme, forKey: .colorTheme)
    }

    /// HealthKit export selection, plus the performance / battery
    /// toggles. Every field must be in CodingKeys / encode / decode: a
    /// field with a default but no coding shipped the
    /// "doesn't remember my AI / Voice choices" bug, where save()
    /// silently dropped it on every write.
    private func encodeExportAndPerformance(into container: inout KeyedEncodingContainer<CodingKeys>) throws {
        try container.encode(enableHealthKitExport, forKey: .enableHealthKitExport)
        try container.encode(exportSDNN, forKey: .exportSDNN)
        try container.encode(exportHeartRate, forKey: .exportHeartRate)
        try container.encode(exportRestingHeartRate, forKey: .exportRestingHeartRate)
        try container.encode(exportSleepData, forKey: .exportSleepData)
        try container.encode(defaultCaptureMode, forKey: .defaultCaptureMode)
        try container.encode(forceAIEnglish, forKey: .forceAIEnglish)
        try container.encode(hideFitnessTab, forKey: .hideFitnessTab)
        try container.encode(enableAIAssistant, forKey: .enableAIAssistant)
        try container.encode(enableVoiceMode, forKey: .enableVoiceMode)
        try container.encode(enableWatchConnectivity, forKey: .enableWatchConnectivity)
        try container.encode(keepScreenOnDuringRecording, forKey: .keepScreenOnDuringRecording)
    }
}
