import SwiftUI

/// The methodology page — single most important user-facing document in
/// the app. It earns App Store review credibility, positions Emuqu
/// in the Altini / HRV4Training intellectual lineage, and preempts the
/// inevitable "why doesn't my score match Whoop's."
///
/// Located at More → About → How Emuqu Scores Recovery.
///
/// **The body text is verbatim from the approved v2.0 methodology copy.** Do not
/// edit. Do not paraphrase. The exact wording is what gives this page
/// regulatory and reputational weight; loosening any phrase erodes the
/// document.
///
/// `validationSection` is an ADDITION to that text, not an edit. It
/// tightens the page rather than loosening
/// it, which is the direction the "do not edit" rule exists to protect.
///
/// It is here because `ScoringWeights` in Constants.swift carried this
/// comment: *"Weights are calibrated against published practitioner
/// heuristics, **not validated against outcomes**. The methodology page
/// surfaces this honestly."* The page did not. Nowhere in its original text
/// did it say the weights were unvalidated; the nearest thing was
/// "research-informed observations", which is not the same admission. A
/// source comment asserting a disclosure that does not exist is worse
/// than no comment, because it stops anyone from going to look.
///
/// Either the sentence in Constants had to go or the disclosure had to
/// exist. The disclosure is the one worth having.
///
/// This file is allowlisted in the build-time copy linter
/// (`Tools/copy_linter/prohibited_terms.json`) because the verbatim text
/// includes the prohibited terms in their negated forms ("does not
/// diagnose," "we are not FDA-approved"). Those negations are the entire
/// point of the page.
struct RecoveryMethodologyView: View {
    @Environment(\.dependencies) var dependencies
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                methodologyTitle
                scoreInputsSection
                acwrRemovalSection
                acwrEvidenceSection
                scopeSection
                validationSection
                referencesSection
                limitsSection
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 24)
        }
        .navigationTitle(Text("How Emuqu scores recovery", bundle: LanguageManager.appBundle))
        .navigationBarTitleDisplayMode(.inline)
        .background(AppTheme.background.ignoresSafeArea())
        .task { dependencies.services.validationTelemetry.recordMethodologyView() }
    }

    @ViewBuilder
    private var methodologyTitle: some View {
        Text(verbatim: String(localized: "Recovery Score Methodology", bundle: LanguageManager.appBundle))
            .font(.largeTitle.weight(.semibold))
            .foregroundStyle(AppTheme.textPrimary)

    }

    @ViewBuilder
    private var scoreInputsSection: some View {
        paragraph(String(localized: "Recovery is calculated from three physiological inputs measured overnight:", bundle: LanguageManager.appBundle))

        bullets(scoreInputBullets)

        paragraph(String(localized: "Training load and trajectory are shown separately, on their own surface, and do not affect your recovery score.", bundle: LanguageManager.appBundle))

        paragraph(String(localized: """
            This is intentional. Training load already manifests downstream as \
            suppressed HRV, elevated resting heart rate, and altered breathing — \
            counting it again in the score would penalize the same physiological \
            event twice.
            """, bundle: LanguageManager.appBundle))

    }

    private var scoreInputBullets: [String] {
        [
            String(localized: "HRV (60%) — your autonomic nervous system's recovery signal", bundle: LanguageManager.appBundle),
            String(localized: "Sleep (25%) — duration and efficiency", bundle: LanguageManager.appBundle),
            String(localized: "Vitals (15%) — resting heart rate, respiratory rate, wrist temperature", bundle: LanguageManager.appBundle)
        ]
    }

    @ViewBuilder
    private var acwrRemovalSection: some View {
        heading(String(localized: "Why we removed Acute:Chronic Workload Ratio (ACWR)", bundle: LanguageManager.appBundle))

        paragraph(String(localized: "Earlier versions of Emuqu used ACWR (Acute:Chronic Workload Ratio) as a 30% input to the recovery score. We removed it.", bundle: LanguageManager.appBundle))

        paragraph(String(localized: "The 2020-2025 sports science literature has substantially dismantled ACWR as a useful metric:", bundle: LanguageManager.appBundle))

    }

    @ViewBuilder
    private var acwrEvidenceSection: some View {
        bullets(acwrEvidenceBullets)

        paragraph(String(localized: """
            The replacement architecture — physiology-only recovery, with \
            load shown on a parallel surface as forward-looking context — \
            follows Marco Altini (HRV4Training) and the Doherty/Altini 2025 \
            systematic review of 14 commercial composite scores.
            """, bundle: LanguageManager.appBundle))

    }

    private var acwrEvidenceBullets: [String] {
        [
            String(localized: "Impellizzeri et al. (2020) found no evidence supporting ACWR's use for individual decision-making.", bundle: LanguageManager.appBundle),
            String(localized: "Impellizzeri et al. (2021) showed that replacing the chronic workload denominator with random numbers produces nearly identical statistical relationships — the chronic component contributes no real signal.", bundle: LanguageManager.appBundle),
            String(localized: "Lolli et al. (2019) demonstrated that the 7-day acute window is mathematically contained within the 28-day chronic window, producing spurious correlation r≈0.5 in the absence of any physiological relationship.", bundle: LanguageManager.appBundle),
            String(localized: "The \"sweet spot\" thresholds (Gabbett 2016) have been the subject of formal critique without retraction.", bundle: LanguageManager.appBundle),
            String(localized: "ACWR has zero peer-reviewed validation in walking, hiking, recreational training, or masters athletes 40+.", bundle: LanguageManager.appBundle)
        ]
    }

    @ViewBuilder
    private var scopeSection: some View {
        heading(String(localized: "What Emuqu does and does not do", bundle: LanguageManager.appBundle))

        bullets([
            String(localized: "Emuqu is a wellness tool, not a medical device.", bundle: LanguageManager.appBundle),
            String(localized: "Emuqu does not predict injury, diagnose any condition, or replace clinical judgment.", bundle: LanguageManager.appBundle),
            String(localized: "Emuqu's scores are research-informed observations of your measured physiology.", bundle: LanguageManager.appBundle)
        ])

    }

    @ViewBuilder
    private var validationSection: some View {
        heading(String(localized: "What is validated, and what is calibrated", bundle: LanguageManager.appBundle))

        paragraph(String(localized: "Emuqu draws a hard line between the two, and it is worth knowing which side of it any given number sits on.", bundle: LanguageManager.appBundle))

        bullets(validationBullets)

        validationClosing
    }

    /// The two closing paragraphs, lifted out so `validationSection` stays a
    /// layout rather than a wall of prose.
    @ViewBuilder
    private var validationClosing: some View {
        paragraph(String(localized: """
            Where measured accuracy figures exist for a method this app uses, \
            they are quoted in the relevant Help Center article rather than \
            hidden here: the agreement of HRV sleep staging with lab \
            polysomnography, the error of optical versus ECG intervals, the \
            sensitivity and specificity of wearable illness flags, and the \
            limits of agreement on DFA a1 during hard exercise.
            """, bundle: LanguageManager.appBundle))

        paragraph(String(localized: """
            This is normal for a composite wellness score, commercial ones \
            included. Very few publish which half is which. Your own trend \
            in the number is more informative than the number.
            """, bundle: LanguageManager.appBundle))
    }

    /// The four lines that carry this section. Extracted so
    /// `validationSection` stays a layout, and so the list can be read
    /// without the surrounding SwiftUI.
    private var validationBullets: [String] {
        [
            String(localized: """
                Validated: the HRV metrics themselves. RMSSD, SDNN and pNN50 are checked on every build against \
                6,000 ECG-derived intervals from 20 PhysioNet recordings, compared with an independent implementation \
                of the Task Force (1996) definitions.
                """, bundle: LanguageManager.appBundle),
            String(localized: """
                Validated by others: the Polar H10's ability to find beats as accurately as a clinical ECG, \
                established in published validation literature. Emuqu never sees an ECG and cannot check this itself.
                """, bundle: LanguageManager.appBundle),
            String(localized: "Research-informed: which signals belong in a recovery score, and the ln(RMSSD) z-score method used to normalise HRV (Plews 2013, Buchheit 2014).", bundle: LanguageManager.appBundle)
        ] + calibrationBullets
    }

    /// The two bullets that say what is not validated, split from
    /// `validationBullets` to keep each list short.
    private var calibrationBullets: [String] {
        [
            String(localized: """
                Calibrated, not validated: the 60/25/15 weights, the score bands, the sleep score's six-factor formula, \
                the HRV-derived sleep stages, the vitals thresholds, and the resting DFA α1 reference range. These are \
                practitioner-informed product choices. No outcome study shows that these particular numbers predict \
                recovery, performance or health.
                """, bundle: LanguageManager.appBundle),
            String(localized: """
                Not unique to us: Doherty, Baldwin, Lambe, Burke and Altini (2025) reviewed 14 composite scores across 10 \
                wearable manufacturers and found none with rigorous independent validation in the peer-reviewed \
                literature. Where such scores have been tested they track acute physiological stress reasonably and \
                discriminate poorly at the top of the range. Ours is in the same position; the difference is that this \
                page says so.
                """, bundle: LanguageManager.appBundle)
        ]
    }

    /// Citations stay in English: they name published papers and journals,
    /// which are cited in their original language.
    @ViewBuilder
    private var referencesSection: some View {
        heading(String(localized: "References", bundle: LanguageManager.appBundle))

        referenceList([
            "Plews, Laursen, Stanley, Kilding, Buchheit (2013). Training adaptation and HRV in elite endurance athletes. Sports Medicine 43:773-781.",
            "Buchheit (2014). Monitoring training status with HR measures. Frontiers in Physiology 5:73.",
            "Banister, Calvert, Savage, Bach (1975). A systems model of training. (TRIMP/CTL/ATL/TSB framework)",
            "Foster (1998). Monitoring training in athletes with reference to overtraining syndrome. Medicine & Science in Sports & Exercise 30(7):1164-1168. (Monotony / strain)",
            "Impellizzeri, Tenan, Kempton, Novak, Coutts (2020). Acute:chronic workload ratio: conceptual issues and fundamental pitfalls. IJSPP 15(6):907-913.",
            "Impellizzeri, Woodcock, Coutts, Fanchini, McCall, Vigotsky (2021). What role do chronic workloads play in the acute to chronic workload ratio? Sports Medicine 51:581-592.",
            "Doherty, Baldwin, Lambe, Burke, Altini (2025). Composite scoring across 14 commercial wearables: a systematic review. Translational Exercise Biomedicine 2(2):128-144."
        ])

    }

    @ViewBuilder
    private var limitsSection: some View {
        heading(String(localized: "Limits", bundle: LanguageManager.appBundle))

        paragraph(String(localized: """
            HRV does not see musculoskeletal fatigue, tendon overuse, or eccentric \
            muscle damage — those are mechanical, tissue-specific signals not \
            captured by autonomic measurements. HRV also has 24-48 hour latency: \
            yesterday's hard session may not show in this morning's reading. \
            Listen to your body. The score is one input, not the answer.
            """, bundle: LanguageManager.appBundle))
    }

    // MARK: - Helpers

    private func heading(_ text: String) -> some View {
        Text(verbatim: text)
            .font(.title3.weight(.semibold))
            .foregroundStyle(AppTheme.textPrimary)
            .padding(.top, 4)
    }

    private func paragraph(_ text: String) -> some View {
        Text(verbatim: text)
            .font(.callout)
            .foregroundStyle(AppTheme.textSecondary)
            .fixedSize(horizontal: false, vertical: true)
            .lineSpacing(2)
    }

    private func bullets(_ items: [String]) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            ForEach(items, id: \.self) { bulletRow($0) }
        }
    }

    private func bulletRow(_ item: String) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Text(verbatim: "•")
                .font(.callout)
                .foregroundStyle(AppTheme.textSecondary)
            Text(verbatim: item)
                .font(.callout)
                .foregroundStyle(AppTheme.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func referenceList(_ refs: [String]) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            ForEach(refs, id: \.self) { ref in
                Text(verbatim: ref)
                    .font(.footnote)
                    .foregroundStyle(AppTheme.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .lineSpacing(2)
            }
        }
    }
}
