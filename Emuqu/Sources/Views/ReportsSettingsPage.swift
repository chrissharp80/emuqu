import SwiftUI

// MARK: - Reports Settings Page
//
// Settings drill-down for the Reports feature. Surfaces:
//   • Auto-email toggle (controls scheduleCoachReportEmail post-workout)
//   • Default training-email recipient (cross-references the Profile
//     page's email-defaults section so users only set it once).
//   • Direct link into the ReportsListView so the same archive is
//     reachable from both Dashboard and Settings.
//
// The auto-email toggle is the single switch that historically lived
// inside `enableAutoCoachReport` (controlling both PDF generation +
// email staging). For v1 it remains one switch — splitting "generate"
// from "email" would require persisting PDFs to a known location and
// adds storage management we don't need yet (reports are generated
// on-demand from the Dashboard card and Reports list anyway).

struct ReportsSettingsPage: View {
    var settingsManager: SettingsManager

    var body: some View {
        Form {
            browseSection
            autoEmailSection
            recipientSection
            explainerSection
        }
        .navigationTitle(String(localized: "Reports", bundle: LanguageManager.appBundle))
        .navigationBarTitleDisplayMode(.inline)
    }

    // MARK: Browse
    private var browseSection: some View {
        Section {
            NavigationLink {
                ReportsListView()
            } label: {
                browseLinkLabel
            }
        }
    }

    private var browseLinkLabel: some View {
        HStack(spacing: 12) {
            Image(systemName: "doc.text.image.fill")
                .foregroundStyle(AppTheme.primary)
                .frame(width: 22)
            VStack(alignment: .leading, spacing: 2) {
                Text(String(localized: "View All Reports", bundle: LanguageManager.appBundle))
                Text(String(localized: "Recovery, workout, and daily PDFs", bundle: LanguageManager.appBundle))
                    .font(.caption2)
                    .foregroundStyle(AppTheme.textSecondary)
            }
        }
    }

    // MARK: Auto-email after workout
    private var autoEmailSection: some View {
        Section {
            autoEmailFields
        } header: {
            Text(String(localized: "Auto-email", bundle: LanguageManager.appBundle))
        } footer: {
            autoEmailFooter
        }
    }

    @ViewBuilder
    private var autoEmailFields: some View {
        Toggle(isOn: Binding(
            get: { settingsManager.settings.enableAutoCoachReport },
            set: { settingsManager.settings.enableAutoCoachReport = $0 }
        )) {
            autoEmailToggleLabel
        }
    }

    private var autoEmailToggleLabel: some View {
        HStack(spacing: 12) {
            Image(systemName: "envelope.fill")
                .foregroundStyle(AppTheme.terracotta)
                .frame(width: 22)
            VStack(alignment: .leading, spacing: 2) {
                Text(String(localized: "Email after each workout", bundle: LanguageManager.appBundle))
                Text(String(localized: "Sends the daily report when HRR completes", bundle: LanguageManager.appBundle))
                    .font(.caption2)
                    .foregroundStyle(AppTheme.textSecondary)
            }
        }
    }

    @ViewBuilder
    private var autoEmailFooter: some View {
        Text(String(localized: "When on, finishing a workout pre-fills the mail composer with the daily report (or workout-only PDF if no morning HRV). Apple presents the composer — you tap Send. Off = reports stay in the in-app Reports list.", bundle: LanguageManager.appBundle))
    }

    // MARK: Recipient (cross-link to Profile)
    private var recipientSection: some View {
        Section {
            recipientFields
        } header: {
            Text(String(localized: "Default recipient", bundle: LanguageManager.appBundle))
        } footer: {
            recipientFooter
        }
    }

    @ViewBuilder
    private var recipientFields: some View {
        trainingRecipientRow
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

    private var trainingRecipientRow: some View {
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

    @ViewBuilder
    private var recipientFooter: some View {
        Text(String(localized: "Same field as Profile → Email Defaults → Training emails. Set here or there — they share the same value.", bundle: LanguageManager.appBundle))
    }

    // MARK: Explainer
    private var explainerSection: some View {
        Section {
            explainerFields
        } header: {
            Text(String(localized: "What's in each report", bundle: LanguageManager.appBundle))
        }
    }

    @ViewBuilder
    private var explainerFields: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label(String(localized: "Recovery / HRV report", bundle: LanguageManager.appBundle), systemImage: "moon.stars.fill")
                .font(.subheadline.weight(.semibold))
            Text(String(localized: "Per-morning HRV deep-dive: composite recovery score, RMSSD, sleep summary, vitals, methodology. Produced for every overnight HRV session.", bundle: LanguageManager.appBundle))
                .font(.caption)
                .foregroundStyle(AppTheme.textSecondary)
            Divider()
            Label(String(localized: "Daily report", bundle: LanguageManager.appBundle), systemImage: "doc.text.image")
                .font(.subheadline.weight(.semibold))
            Text(String(localized: "Combines this morning's HRV / sleep / training balance with today's workout. Generated when both exist for the same day; otherwise produces a workout-only PDF.", bundle: LanguageManager.appBundle))
                .font(.caption)
                .foregroundStyle(AppTheme.textSecondary)
            Divider()
            Label(String(localized: "Workout report", bundle: LanguageManager.appBundle), systemImage: "doc.text")
                .font(.subheadline.weight(.semibold))
            Text(String(localized: "Per-session deep-dive: hero verdict, autonomic / cardiopulmonary analysis, route map, splits, methodology. Generated for any workout in your archive.", bundle: LanguageManager.appBundle))
                .font(.caption)
                .foregroundStyle(AppTheme.textSecondary)
        }
        .padding(.vertical, 4)
    }
}
