import SwiftUI

// MARK: - Profile Settings Page

struct ProfileSettingsPage: View {
    @Environment(SettingsManager.self) var settingsManager
    /// Two-way access to the settings for controls. An `@Environment` value has
    /// no projected `$` binding, so this stands in for `$settingsManager.settings`.
    private var settingsBinding: Binding<UserSettings> {
        Binding(get: { settingsManager.settings }, set: { settingsManager.settings = $0 })
    }
    @Environment(LanguageManager.self) private var languageManager
    @State private var unitsPreference: UnitsPreference = UnitsPreferenceStore.current

    var body: some View {
        Form {
            avatarSection
            birthdaySection
            fitnessLevelSection
            unitsSection
            recoveryEmailSection
            trainingEmailSection

            // MARK: Address book — names the AI can resolve
            //
            // Lets the user say "email my workout to chris and coach"
            // and have the AI map those names → addresses without
            // typing them. Ad-hoc recipients, distinct from the fixed
            // To/Cc defaults above. The AI can also add/remove via
            // assistant.contacts.add / .remove — this UI is the same
            // store, just direct.
            EmailContactsSection()
        }
        .zenFormBackground()
        .navigationTitle(String(localized: "Profile", bundle: LanguageManager.appBundle))
    }

    /// Build plan §4.6 M3.1 — avatar at the top of the profile
    /// form. Tap to change via PhotosPicker; stored as a 256×256
    /// JPEG on UserSettings.avatarImageData.
    private var avatarSection: some View {
        Section {
            AvatarPickerView()
                .frame(maxWidth: .infinity)
                .padding(.vertical, 8)
        }
        .listRowBackground(Color.clear)
    }

    private var birthdaySection: some View {
        Section {
            birthdayPicker
            .accessibilityLabel(String(localized: "Birthday", bundle: LanguageManager.appBundle))
            .accessibilityHint(String(localized: "Used to compute age-based defaults for max heart rate and zones", bundle: LanguageManager.appBundle))

            ageRow
        }
    }

    /// Wheel, not the compact calendar. The compact style opens on the
    /// current month and pages back one month at a time: a tester born in
    /// 1964 had to tap through more than seven hundred months. The wheel's
    /// year column is one flick.
    private var birthdayPicker: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(String(localized: "Birthday", bundle: LanguageManager.appBundle))
            DatePicker(
                String(localized: "Birthday", bundle: LanguageManager.appBundle),
                selection: Binding(
                    get: { settingsManager.settings.birthday ?? (Calendar.current.date(byAdding: .year, value: -30, to: Date()) ?? Date()) },
                    set: { settingsManager.settings.birthday = $0 }
                ),
                in: ...Date(),
                displayedComponents: .date
            )
            .datePickerStyle(.wheel)
            .labelsHidden()
            .frame(maxWidth: .infinity)
        }
    }

    @ViewBuilder
    private var ageRow: some View {
        if let age = settingsManager.settings.age {
            HStack {
                Text(String(localized: "Age", bundle: LanguageManager.appBundle))
                Spacer()
                Text(String(localized: "\(age) years", bundle: LanguageManager.appBundle))
                    .foregroundColor(AppTheme.textSecondary)
            }
            .accessibilityElement(children: .combine)
            .accessibilityValue(String(localized: "\(age) years", bundle: LanguageManager.appBundle))
        }
    }

    private var fitnessLevelSection: some View {
        Section {
            fitnessLevelPicker
            biologicalSexPicker
        }
    }

    private var fitnessLevelPicker: some View {
        Picker(String(localized: "Fitness Level", bundle: LanguageManager.appBundle), selection: Binding(
            get: { settingsManager.settings.fitnessLevel },
            set: { settingsManager.settings.fitnessLevel = $0 }
        )) {
            Text(String(localized: "Not Set", bundle: LanguageManager.appBundle)).tag(FitnessLevel?.none)
            ForEach(FitnessLevel.allCases) { level in
                Text(level.rawValue).tag(Optional(level))
            }
        }
        .accessibilityLabel(String(localized: "Fitness level", bundle: LanguageManager.appBundle))
        .accessibilityHint(String(localized: "Your typical training intensity — tunes age-adjusted HRV ranges", bundle: LanguageManager.appBundle))
    }

    private var biologicalSexPicker: some View {
        Picker(String(localized: "Biological Sex", bundle: LanguageManager.appBundle), selection: Binding(
            get: { settingsManager.settings.biologicalSex },
            set: { settingsManager.settings.biologicalSex = $0 }
        )) {
            Text(String(localized: "Not Set", bundle: LanguageManager.appBundle)).tag(UserSettings.BiologicalSex?.none)
            ForEach(UserSettings.BiologicalSex.allCases) { sex in
                Text(sex.displayName).tag(Optional(sex))
            }
        }
        .accessibilityLabel(String(localized: "Biological sex", bundle: LanguageManager.appBundle))
        .accessibilityHint(String(localized: "Used for sex-dependent TRIMP calculations", bundle: LanguageManager.appBundle))
    }

    private var unitsSection: some View {
        Section {
            distancePacePicker
            temperaturePicker
        } header: {
            Text(String(localized: "Units", bundle: LanguageManager.appBundle))
        } footer: {
            unitsFooter
        }
    }

    @ViewBuilder
    private var unitsFooter: some View {
        let resolved = unitsPreference.resolved
        let summary: String = {
            switch resolved {
            case .imperial:
                return String(localized: "miles, feet, min/mile", bundle: LanguageManager.appBundle)
            case .metric, .auto:
                return String(localized: "kilometres, metres, min/km", bundle: LanguageManager.appBundle)
            }
        }()
        Text(String(localized: "Affects workout distance, elevation, and pace throughout the app. Currently showing: \(summary). GPX and TCX exports stay metric — that's what Strava and Garmin require.", bundle: LanguageManager.appBundle))
    }

    private var distancePacePicker: some View {
        Picker(String(localized: "Distance & Pace", bundle: LanguageManager.appBundle), selection: $unitsPreference) {
            ForEach(UnitsPreference.allCases) { pref in
                Text(pref.displayName).tag(pref)
            }
        }
        .onChange(of: unitsPreference) { _, newValue in
            UnitsPreferenceStore.current = newValue
        }
        .accessibilityLabel(String(localized: "Distance and pace units", bundle: LanguageManager.appBundle))
        .accessibilityHint(String(localized: "Automatic follows your device region; otherwise metric or imperial", bundle: LanguageManager.appBundle))
    }

    private var temperaturePicker: some View {
        Picker(String(localized: "Temperature", bundle: LanguageManager.appBundle), selection: settingsBinding.temperatureUnit) {
            ForEach(TemperatureUnit.allCases) { unit in
                Text(unit.rawValue).tag(unit)
            }
        }
        .accessibilityLabel(String(localized: "Temperature unit", bundle: LanguageManager.appBundle))
    }

    /// Email defaults — used app-wide
    ///
    /// Two categories so the user can route recovery emails one
    /// place (themself / a doctor) and training emails another
    /// (themself / a coach / a partner). Same person frequently
    /// — but the split is free in UI complexity and matters when
    /// it does. Used by the morning report PDF, the workout PDF,
    /// AND the AI's `assistant.email.compose` action — set
    /// once, every email surface knows.
    private var recoveryEmailSection: some View {
        Section {
            recoveryEmailToRow
            recoveryEmailCcRow
        } header: {
            Text(String(localized: "Recovery emails", bundle: LanguageManager.appBundle))
        } footer: {
            Text(String(localized: "Pre-fills To and Cc for the morning report PDF AND any recovery / HRV / sleep emails the AI assistant composes.", bundle: LanguageManager.appBundle))
        }
    }

    private var recoveryEmailToRow: some View {
        HStack {
            Image(systemName: "moon.stars.fill")
                .foregroundStyle(AppTheme.primary)
                .frame(width: 22)
            TextField(String(localized: "you@example.com", bundle: LanguageManager.appBundle), text: Binding(
                get: { settingsManager.settings.defaultRecoveryEmailRecipient ?? "" },
                set: { settingsManager.settings.defaultRecoveryEmailRecipient = $0.isEmpty ? nil : $0 }
            ))
            .textInputAutocapitalization(.never)
            .autocorrectionDisabled()
            .keyboardType(.emailAddress)
        }
    }

    private var recoveryEmailCcRow: some View {
        HStack {
            Image(systemName: "envelope.badge.fill")
                .foregroundStyle(AppTheme.textSecondary)
                .frame(width: 22)
            TextField(String(localized: "cc — doctor@example.com, …", bundle: LanguageManager.appBundle), text: Binding(
                get: { settingsManager.settings.defaultRecoveryEmailCC ?? "" },
                set: { settingsManager.settings.defaultRecoveryEmailCC = $0.isEmpty ? nil : $0 }
            ))
            .textInputAutocapitalization(.never)
            .autocorrectionDisabled()
            .keyboardType(.emailAddress)
        }
    }

    private var trainingEmailSection: some View {
        Section {
            trainingEmailToRow
            trainingEmailCcRow
        } header: {
            Text(String(localized: "Training emails", bundle: LanguageManager.appBundle))
        } footer: {
            Text(String(localized: "Pre-fills To and Cc for workout PDF reports AND any training / workout / session emails the AI composes. You can always edit the addresses in Apple's mail composer before tapping Send.", bundle: LanguageManager.appBundle))
        }
    }

    private var trainingEmailToRow: some View {
        HStack {
            Image(systemName: "figure.run")
                .foregroundStyle(AppTheme.terracotta)
                .frame(width: 22)
            TextField(String(localized: "you@example.com", bundle: LanguageManager.appBundle), text: Binding(
                get: { settingsManager.settings.defaultTrainingEmailRecipient ?? "" },
                set: { settingsManager.settings.defaultTrainingEmailRecipient = $0.isEmpty ? nil : $0 }
            ))
            .textInputAutocapitalization(.never)
            .autocorrectionDisabled()
            .keyboardType(.emailAddress)
        }
    }

    private var trainingEmailCcRow: some View {
        HStack {
            Image(systemName: "envelope.badge.fill")
                .foregroundStyle(AppTheme.textSecondary)
                .frame(width: 22)
            TextField(String(localized: "cc — coach@example.com, …", bundle: LanguageManager.appBundle), text: Binding(
                get: { settingsManager.settings.defaultTrainingEmailCC ?? "" },
                set: { settingsManager.settings.defaultTrainingEmailCC = $0.isEmpty ? nil : $0 }
            ))
            .textInputAutocapitalization(.never)
            .autocorrectionDisabled()
            .keyboardType(.emailAddress)
        }
    }
}

// MARK: - Email Contacts Section
//
// Inline address-book editor. Lives in Profile so the user can
// curate the names the AI resolves in `assistant.email.compose`.
// Same store the AI writes to via `assistant.contacts.add` /
// `.remove`, so changes round-trip cleanly.
private struct EmailContactsSection: View {
    @Environment(\.dependencies) var dependencies
    private var store: EmailContactStore { dependencies.app.emailContactStore }
    @State private var newName: String = ""
    @State private var newEmail: String = ""
    @State private var newNotes: String = ""
    @State private var showInvalidEmail = false

    var body: some View {
        Section {
            addContactForm
            existingContactsList
        } header: {
            Text(String(localized: "Email contacts", bundle: LanguageManager.appBundle))
        } footer: {
            Text(store.contacts.isEmpty
                ? String(localized: "Save people the AI can address by name. \"Email my workout to chris and coach\" looks up the addresses here. The AI can also add or remove contacts when you ask.", bundle: LanguageManager.appBundle)
                : String(localized: "Tap any contact to swipe-delete. The AI resolves names case-insensitively when you say things like \"email this to chris\".", bundle: LanguageManager.appBundle))
        }
    }

    /// Add form. Inline so adding is two taps + type, no modal.
    private var addContactForm: some View {
        VStack(spacing: 8) {
            newContactNameRow
            newContactEmailRow
            newContactNotesRow
            addContactButtonRow
        }
        .padding(.vertical, 4)
        .alert("Invalid email", isPresented: $showInvalidEmail) {
            Button(String(localized: "OK", bundle: LanguageManager.appBundle), role: .cancel) {}
        } message: {
            Text(String(localized: "Enter an address with '@' and a domain (e.g. coach@team.com).", bundle: LanguageManager.appBundle))
        }
    }

    private var newContactNameRow: some View {
        HStack(spacing: 8) {
            Image(systemName: "person.crop.circle.badge.plus")
                .foregroundStyle(AppTheme.primary)
                .frame(width: 22)
            TextField(String(localized: "Name (e.g. Chris, Coach)", bundle: LanguageManager.appBundle), text: $newName)
                .textInputAutocapitalization(.words)
        }
    }

    private var newContactEmailRow: some View {
        HStack(spacing: 8) {
            Image(systemName: "envelope")
                .foregroundStyle(AppTheme.textSecondary)
                .frame(width: 22)
            TextField(String(localized: "email@example.com", bundle: LanguageManager.appBundle), text: $newEmail)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .keyboardType(.emailAddress)
        }
    }

    private var newContactNotesRow: some View {
        HStack(spacing: 8) {
            Image(systemName: "text.bubble")
                .foregroundStyle(AppTheme.textSecondary)
                .frame(width: 22)
            TextField(String(localized: "Notes — optional (e.g. coach, partner)", bundle: LanguageManager.appBundle), text: $newNotes)
                .textInputAutocapitalization(.sentences)
        }
    }

    private var addContactButtonRow: some View {
        HStack {
            Spacer()
            Button {
                addContact()
            } label: {
                Label(String(localized: "Add contact", bundle: LanguageManager.appBundle), systemImage: "plus.circle.fill")
                    .font(.subheadline.weight(.semibold))
            }
            .buttonStyle(.borderedProminent)
            .disabled(!canAdd)
        }
    }

    /// Existing contacts list. Swipe-to-delete; tap to view full
    /// details (we keep the row simple — the AI sees more in
    /// contacts.list).
    @ViewBuilder
    private var existingContactsList: some View {
        if !store.contacts.isEmpty {
            ForEach(sortedContacts) { contact in
                contactRow(contact)
            }
            .onDelete(perform: deleteContacts)
        }
    }

    private func contactRow(_ contact: EmailContact) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(contact.name)
                .font(.body.weight(.semibold))
            Text(contact.email)
                .font(.caption)
                .foregroundStyle(AppTheme.textSecondary)
            if let notes = contact.notes, !notes.isEmpty {
                Text(notes)
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
        }
        .padding(.vertical, 2)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(contact.name), \(contact.email)\(contact.notes.map { ", \($0)" } ?? "")")
    }

    private var sortedContacts: [EmailContact] {
        store.contacts.sorted { $0.name.lowercased() < $1.name.lowercased() }
    }

    private var canAdd: Bool {
        !newName.trimmingCharacters(in: .whitespaces).isEmpty &&
        !newEmail.trimmingCharacters(in: .whitespaces).isEmpty
    }

    private func addContact() {
        let name = newName.trimmingCharacters(in: .whitespaces)
        let email = newEmail.trimmingCharacters(in: .whitespaces)
        let notes = newNotes.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty, !email.isEmpty else { return }
        guard email.contains("@"), email.contains(".") else {
            showInvalidEmail = true
            return
        }
        store.add(EmailContact(
            name: name,
            email: email,
            notes: notes.isEmpty ? nil : notes
        ))
        newName = ""
        newEmail = ""
        newNotes = ""
    }

    private func deleteContacts(at offsets: IndexSet) {
        let list = sortedContacts
        for idx in offsets where list.indices.contains(idx) {
            store.remove(id: list[idx].id)
        }
    }
}

// MARK: - Sleep Settings Page

struct SleepSettingsPage: View {
    @Environment(SettingsManager.self) var settingsManager
    /// Two-way access to the settings for controls. An `@Environment` value has
    /// no projected `$` binding, so this stands in for `$settingsManager.settings`.
    private var settingsBinding: Binding<UserSettings> {
        Binding(get: { settingsManager.settings }, set: { settingsManager.settings = $0 })
    }
    @Environment(RRCollector.self) var collector
    @Environment(LanguageManager.self) private var languageManager

    @State private var isRetroApplying = false
    @State private var retroApplyProgress = 0
    @State private var retroApplyTotal = 0
    @State private var showingRetroApplyAlert = false
    @State private var retroApplyMessage = ""
    @State private var retroApplyTask: Task<Void, Never>?
    /// Confirmation dialog before kicking off a retro-apply pass. Without
    /// this, toggling "HRV-Enhanced Watch Stages" silently re-classifies
    /// every archived sleep session — surprising and slow on archives
    /// with hundreds of sessions. The pending-toggle target is captured
    /// here so we can revert if the user cancels (the toggle has already
    /// been flipped by the time `.onChange` fires).
    @State private var showingRetroApplyConfirm = false
    @State private var pendingHRVAugmentation: Bool = false
    /// Snapshot of the toggle's value at view-load time — used to
    /// detect whether `.onChange` fired because of a real user interaction
    /// (different from the snapshot) or because the settings file was
    /// just loaded with a value that re-triggered the binding (e.g. a
    /// reinstall fresh-loaded the value, or a SettingsManager publisher
    /// fired before the view's first body pass). Without this guard, an
    /// install that resets the toggle to its default would silently
    /// kick off a full re-scan the moment the user reopens Sleep
    /// Settings — exactly a user complaint.
    @State private var initialHRVAugmentationSnapshot: Bool?
    /// Reentrancy guard for the HRV-augmentation toggle. Set true immediately
    /// before any PROGRAMMATIC write to `enableHRVSleepAugmentation` (the
    /// onChange revert and the confirm-dialog applies) so the write's
    /// re-fired `.onChange` returns early instead of looping. Prevents an
    /// infinite-loop hang (the toggle wrote its value back inside
    /// its own onChange, and each iteration also forced a full settings-file
    /// write, freezing the main thread).
    @State private var isRevertingHRVToggle = false

    var body: some View {
        Form {
            sleepModeSection
            scheduleSection
            appleHealthSleepSection
            splitSleepSection
        }
        .zenFormBackground()
        .navigationTitle(String(localized: "Sleep", bundle: LanguageManager.appBundle))
    }

    /// Build plan §M3.3 line 1219 — "Auto / Manual segmented. If Auto:
    /// derived bedtime + typical sleep + wake time from HealthKit
    /// history. If Manual: editable."
    private var sleepModeSection: some View {
        Section {
            HStack {
                Text(String(localized: "Mode", bundle: LanguageManager.appBundle))
                Spacer()
                Text(settingsManager.settings.enableSleepIntegration
                     ? String(localized: "Auto", bundle: LanguageManager.appBundle)
                     : String(localized: "Manual", bundle: LanguageManager.appBundle))
                    .foregroundStyle(AppTheme.textSecondary)
                    .font(.subheadline)
            }
        } header: {
            Text("Sleep Schedule", bundle: LanguageManager.appBundle)
        } footer: {
            Text("Auto: bedtime, typical sleep, and wake time derive from your Apple Health sleep history. Manual: edit the values below — they override the auto derivation.", bundle: LanguageManager.appBundle)
        }
    }

    private var scheduleSection: some View {
        Section {
            bedtimePicker
            typicalSleepPicker
            wakeTimeRow
        } header: {
            Text("Schedule", bundle: LanguageManager.appBundle)
        } footer: {
            Text("Your usual bedtime and sleep duration. Sets your overnight window for sleep analysis. Shift workers: set bedtime to when you normally go to sleep.", bundle: LanguageManager.appBundle)
        }
    }

    private var bedtimePicker: some View {
        DatePicker(
            String(localized: "Bedtime", bundle: LanguageManager.appBundle),
            selection: settingsBinding.expectedBedtime,
            displayedComponents: .hourAndMinute
        )
        .accessibilityLabel(Text("Bedtime", bundle: LanguageManager.appBundle))
        .accessibilityHint(Text("Your usual bedtime. Sets the overnight window for sleep analysis.", bundle: LanguageManager.appBundle))
    }

    private var typicalSleepPicker: some View {
        Picker(
            String(localized: "Typical Sleep", bundle: LanguageManager.appBundle),
            selection: settingsBinding.typicalSleepHours
        ) {
            ForEach(Array(stride(from: 5.0, through: 10.0, by: 0.5)), id: \.self) { hours in
                Text(formatDuration(hours)).tag(hours)
            }
        }
        .accessibilityLabel(Text("Typical sleep duration", bundle: LanguageManager.appBundle))
    }

    private var wakeTimeRow: some View {
        HStack {
            Text("Wake Time", bundle: LanguageManager.appBundle)
            Spacer()
            Text(formattedWakeTime)
                .foregroundColor(AppTheme.textSecondary)
        }
        .accessibilityElement(children: .combine)
        .accessibilityValue(formattedWakeTime)
    }

    /// Apple Health sleep integration
    ///
    /// Lives here rather than on a "Health Integration" page: sleep
    /// toggles belong next to the sleep schedule they affect, not in a
    /// separate biometrics grab-bag.
    private var appleHealthSleepSection: some View {
        withRetroApplyDialogs(appleHealthSleepForm)
    }

    private var appleHealthSleepForm: some View {
        Section {
            useAppleHealthSleepToggle
            hrvSleepToggles
            retroApplyProgressRow
        } header: {
            Text("Apple Health Sleep Data", bundle: LanguageManager.appBundle)
        } footer: {
            Text(appleHealthSleepFooter)
        }
    }

    /// The two prompts the HRV-stage toggle can raise: the confirmation before
    /// re-classifying archived sessions, and the result afterwards.
    private func withRetroApplyDialogs(_ content: some View) -> some View {
        content
    .alert(
        Text("Sleep Data Updated", bundle: LanguageManager.appBundle),
        isPresented: $showingRetroApplyAlert
    ) {
        Button(String(localized: "OK", bundle: LanguageManager.appBundle)) {}
    } message: {
        Text(retroApplyMessage)
    }
    .confirmationDialog(
        retroApplyPrompt,
        isPresented: $showingRetroApplyConfirm,
        titleVisibility: .visible
    ) {
        retroApplyChoices
    } message: {
        Text("This will re-classify every archived session's sleep using the new setting. Or apply only to sessions you record from now on.", bundle: LanguageManager.appBundle)
    }
    }

    private var appleHealthSleepFooter: String {
        settingsManager.settings.enableHRVSleepAugmentation && settingsManager.settings.enableSleepIntegration
            ? String(localized: "Refines Apple Watch sleep stages using chest strap HRV data. Changes apply to all previous sessions. Without a Watch, HRV classification always runs.", bundle: LanguageManager.appBundle)
            : String(localized: "Include Apple Health sleep data in your recovery score. Without a Watch, sleep stages are classified from chest strap HRV data automatically.", bundle: LanguageManager.appBundle)
    }

    private var retroApplyPrompt: Text {
        Text(pendingHRVAugmentation
            ? "Apply HRV-Enhanced Stages to past sessions?"
            : "Remove HRV-Enhanced Stages from past sessions?",
            bundle: LanguageManager.appBundle)
    }

    @ViewBuilder
    private var retroApplyChoices: some View {
            Button(String(localized: "Apply to All Sessions", bundle: LanguageManager.appBundle)) {
                // Guard the write so the resulting onChange accepts the
                // value instead of re-prompting.
                isRevertingHRVToggle = true
                settingsManager.settings.enableHRVSleepAugmentation = pendingHRVAugmentation
                initialHRVAugmentationSnapshot = pendingHRVAugmentation
                startRetroApply()
            }
            Button(String(localized: "Just for New Sessions", bundle: LanguageManager.appBundle)) {
                isRevertingHRVToggle = true
                settingsManager.settings.enableHRVSleepAugmentation = pendingHRVAugmentation
                initialHRVAugmentationSnapshot = pendingHRVAugmentation
            }
            Button(String(localized: "Cancel", bundle: LanguageManager.appBundle), role: .cancel) {
                // Toggle was already reverted to oldValue in onChange —
                // nothing else to do here.
            }
    }

    private var useAppleHealthSleepToggle: some View {
        Toggle(String(localized: "Use Apple Health Sleep Data", bundle: LanguageManager.appBundle),
               isOn: settingsBinding.enableSleepIntegration)
            .accessibilityHint(Text("Includes HealthKit sleep samples in your recovery score.", bundle: LanguageManager.appBundle))
    }

    @ViewBuilder
    private var hrvSleepToggles: some View {
        if settingsManager.settings.enableSleepIntegration {
            hrvEnhancedStagesToggle
            Toggle(String(localized: "Lower Score Without Sleep", bundle: LanguageManager.appBundle),
                   isOn: settingsBinding.penalizeMissingSleep)
                .accessibilityHint(Text("When no sleep is detected, the recovery score is lowered instead of hidden.", bundle: LanguageManager.appBundle))
        }
    }

    private var hrvEnhancedStagesToggle: some View {
        Toggle(String(localized: "HRV-Enhanced Watch Stages", bundle: LanguageManager.appBundle),
               isOn: settingsBinding.enableHRVSleepAugmentation)
            .onAppear { snapshotHRVAugmentationIfNeeded() }
            .onChange(of: settingsManager.settings.enableHRVSleepAugmentation) { oldValue, newValue in
                confirmHRVAugmentationChange(from: oldValue, to: newValue)
            }
        .accessibilityHint(Text("Refines Apple Watch sleep stages using chest-strap HRV.", bundle: LanguageManager.appBundle))
    }

    /// Snapshot the value at first body pass so
    /// .onChange can distinguish "user toggled"
    /// from "settings just loaded".
    private func snapshotHRVAugmentationIfNeeded() {
        if initialHRVAugmentationSnapshot == nil {
            initialHRVAugmentationSnapshot = settingsManager.settings.enableHRVSleepAugmentation
        }
    }

    /// REENTRANCY GUARD (prevents a hang). The
    /// revert-write below (`= oldValue`) re-fires this
    /// same handler. Without a guard the handler
    /// ping-pongs the value forever — an infinite loop
    /// that ALSO triggers a full synchronous
    /// settings-file write on every iteration, freezing
    /// the main thread until the app is killed. The old
    /// `oldValue == snapshot && newValue == snapshot`
    /// guard could never be true (onChange only fires
    /// when the value actually changes, so old ≠ new),
    /// so it never broke the loop.
    private func confirmHRVAugmentationChange(from oldValue: Bool, to newValue: Bool) {
        if isRevertingHRVToggle {
            isRevertingHRVToggle = false
            return
        }
        // Real user interaction → ask first. Capture the
        // new value, revert the toggle visually, and let
        // the user confirm. The revert sets the reentrancy
        // flag so the re-fired handler returns immediately.
        pendingHRVAugmentation = newValue
        isRevertingHRVToggle = true
        settingsManager.settings.enableHRVSleepAugmentation = oldValue
        showingRetroApplyConfirm = true
    }

    @ViewBuilder
    private var retroApplyProgressRow: some View {
    if isRetroApplying {
        HStack {
            ProgressView()
                .padding(.trailing, 4)
            Text("Updating \(retroApplyProgress)/\(retroApplyTotal) sessions…", bundle: LanguageManager.appBundle)
                .font(.subheadline)
                .foregroundColor(AppTheme.textSecondary)
        }
        .accessibilityLabel(Text("Updating \(retroApplyProgress) of \(retroApplyTotal) sessions", bundle: LanguageManager.appBundle))
    }
    }

    private var splitSleepSection: some View {
        Section {
            splitThresholdPicker
            combineSegmentsPicker
            customGapWindowPicker
        } header: {
            Text("Split Sleep", bundle: LanguageManager.appBundle)
        } footer: {
            Text(splitFooter)
        }
    }

    private var splitThresholdPicker: some View {
        Picker(
            String(localized: "Split Threshold", bundle: LanguageManager.appBundle),
            selection: settingsBinding.sleepSplitGapMinutes
        ) {
            ForEach([15, 20, 30, 45, 60, 90, 120], id: \.self) { min in
                Text(min < 60 ? "\(min) min" : "\(min / 60)h\(min % 60 > 0 ? " \(min % 60)m" : "")").tag(min)
            }
        }
        .accessibilityLabel(Text("Sleep split threshold", bundle: LanguageManager.appBundle))
    }

    private var combineSegmentsPicker: some View {
        Picker(
            String(localized: "Combine Segments", bundle: LanguageManager.appBundle),
            selection: settingsBinding.sessionMergeMode
        ) {
            ForEach(SessionMergeMode.allCases) { mode in
                Text(mode.displayName).tag(mode)
            }
        }
        .accessibilityLabel(Text("Combine sleep segments mode", bundle: LanguageManager.appBundle))
    }

    @ViewBuilder
    private var customGapWindowPicker: some View {
        if settingsManager.settings.sessionMergeMode == .custom {
            gapWindowPicker
            .accessibilityLabel(Text("Custom gap window in hours", bundle: LanguageManager.appBundle))
        }
    }

    private var gapWindowPicker: some View {
        Picker(
            String(localized: "Gap Window", bundle: LanguageManager.appBundle),
            selection: settingsBinding.customMergeGapHours
        ) {
            ForEach(Array(stride(from: 1.0, through: 12.0, by: 0.5)), id: \.self) { hours in
                Text(formatGap(hours)).tag(hours)
            }
        }
    }

    // MARK: - Retro-apply HRV-enhanced stages to archived sessions
    //
    /// When the user toggles HRV-enhanced Watch stages, every past session
    /// re-runs its sleep classification using the new setting so the history
    /// isn't left inconsistent with current scoring.
    private func startRetroApply() {
        guard !isRetroApplying else { return }
        isRetroApplying = true
        retroApplyProgress = 0
        retroApplyTotal = 0
        retroApplyTask = Task {
            let count = await collector.retroApplySleepSettings { publishRetroProgress($0, total: $1) }
            await MainActor.run { finishRetroApply(count: count) }
        }
    }

    /// The callback arrives off the main actor, so the published counters are
    /// updated in a hop rather than assigned directly.
    private func publishRetroProgress(_ completed: Int, total: Int) {
        Task { @MainActor in
            retroApplyProgress = completed
            retroApplyTotal = total
        }
    }

    @MainActor
    private func finishRetroApply(count: Int) {
        isRetroApplying = false
        retroApplyMessage = String(localized: "Updated sleep data for \(count) sessions.", bundle: LanguageManager.appBundle)
        showingRetroApplyAlert = true
    }

    var formattedWakeTime: String {
        let schedule = settingsManager.settings.sleepSchedule
        let wake = Calendar.current.date(from: DateComponents(hour: schedule.wakeHour, minute: schedule.wakeMinute)) ?? Date()
        let fmt = DateFormatter()
        fmt.timeStyle = .short
        return fmt.string(from: wake)
    }

    func formatDuration(_ hours: Double) -> String {
        let h = Int(hours); let m = Int((hours - Double(h)) * 60)
        return m == 0 ? String(localized: "\(h) hours", bundle: LanguageManager.appBundle) : "\(h)h \(m)m"
    }

    func formatGap(_ hours: Double) -> String {
        let h = Int(hours); let m = Int((hours - Double(h)) * 60)
        return m == 0 ? String(localized: "\(h) hours", bundle: LanguageManager.appBundle) : "\(h)h \(m)m"
    }

    var splitFooter: String {
        let mins = settingsManager.settings.sleepSplitGapMinutes
        let gapDesc = mins < 60 ? String(localized: "\(mins) minutes", bundle: LanguageManager.appBundle) : String(localized: "\(mins / 60) hours", bundle: LanguageManager.appBundle)
        let splitText = String(localized: "Gaps of \(gapDesc) or more in your sleep data are treated as separate sessions.", bundle: LanguageManager.appBundle)
        let mergeText = switch settingsManager.settings.sessionMergeMode {
        case .off: String(localized: " Segments are scored independently.", bundle: LanguageManager.appBundle)
        case .defaultGap: String(localized: " Segments within 4.5 hours count as one night.", bundle: LanguageManager.appBundle)
        case .custom: String(localized: " Segments within \(formatGap(settingsManager.settings.customMergeGapHours)) count as one night.", bundle: LanguageManager.appBundle)
        }
        return splitText + mergeText
    }
}
