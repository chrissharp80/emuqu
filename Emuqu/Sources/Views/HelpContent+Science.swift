import SwiftUI

// The core help categories and the age-adjusted HRV-science article, split out
// of `HelpContent.swift`. The data model — categories, articles,
// sections — stays behind. `HelpContent+Articles.swift` already holds the
// assistant/data/personalisation categories, so this file is deliberately named
// for what it contains rather than reusing that name.

// MARK: - Content

/// Help copy is assembled with theme colors, so it is read on the main actor
/// like the views that show it.
@MainActor
enum HelpContent {
    /// Every category in the selected language. The content below is written
    /// in English; `HelpLocalization` translates it as it is handed out.
    static func categories(forAge age: Int? = nil) -> [HelpCategory] {
        englishCategories(forAge: age).map(\.localized)
    }

    static func englishCategories(forAge age: Int? = nil) -> [HelpCategory] {
        [
            gettingStarted,
            recording,
            recoveryScore,
            HelpScienceCatalog.sleepAnalysis,
            HelpScienceCatalog.trainingLoad,
            HelpScienceCatalog.vitals,
            HelpScienceCatalog.hrvScience(forAge: age),
            aiAssistant,
            getMeBack,
            yourData,
            personalization,
            appNavigation
        ]
    }

    // MARK: Getting Started

    static let gettingStarted = HelpCategory(
        id: "getting-started",
        title: "Getting Started",
        icon: "sparkles",
        color: AppTheme.softGold,
        articles: [
            HelpArticle(
                id: "what-is-flow-recovery",
                title: "What is Emuqu?",
                icon: "heart.text.square",
                summary: "An overview of what the app does and how it helps you",
                sections: [
                    .text("Emuqu is an HRV monitoring app that answers one simple question: \"How am I today?\""),
                    .text("It connects to your Polar heart rate monitor — the H10 chest strap (ECG) or Verity Sense optical sensor (PPG) — and integrates with Apple Health for sleep, training, and vitals data. Together, these paint a complete picture of your daily recovery."),
                    .heading("The Five Tabs"),
                    .keyValue([
                        (label: "Dashboard", value: "Your daily readiness — score, HRV, sleep, vitals and the training-load page, plus your recent sessions (View all opens History)"),
                        (label: "Record", value: "Collect HRV data from your Polar device"),
                        (label: "Fitness", value: "Record workouts with live heart rate and GPS, and review effort and training load"),
                        (label: "Flo ✨", value: "In-app chat that knows your data — Apple Intelligence by default, paid models with your own API key"),
                        (label: "More", value: "Trends, Settings (data, sync, tags, AI keys + memory), Help Center and About")
                    ]),
                    .tip("The Dashboard tab is your daily starting point. Everything else feeds into it. Tap the ✨ button on the Dashboard for instant AI-coached answers about today's score.")
                ]
            ),
            HelpArticle(
                id: "your-first-reading",
                title: "Your First Reading",
                icon: "1.circle.fill",
                summary: "Step-by-step guide to your first HRV measurement",
                sections: [
                    .text("Your first reading takes about 3 minutes and gives you a snapshot of your current recovery state."),
                    .heading("Quick Reading (Recommended First Time)"),
                    .steps([
                        "Go to the Record tab and select Quick Reading",
                        "Put on your Polar device — moisten the H10 electrodes or press the Verity Sense button to turn it on",
                        "Tap your device in the known devices list, or tap Scan for Devices to find it",
                        "Once connected, choose 3 min (Standard) duration",
                        "Sit still, breathe normally, and tap Start",
                        "Follow the breathing mandala if you like — it helps, but isn't required",
                        "When finished, tap View Full Report for your complete analysis"
                    ]),
                    .tip("Morning readings — right after waking, before getting out of bed — are the most consistent time for a spot reading. They give the most consistent, comparable results day to day."),
                    .heading("What Your First Numbers Mean"),
                    .text("""
                        Don't worry about absolute values yet. HRV is highly individual — what matters is YOUR baseline over time. A 40ms RMSSD might be excellent for one person and below average for another. From your third night the app scores you \
                        against your own baseline, cautiously at first. The Dashboard shows your score from the 14th night, once that baseline has settled.
                        """)
                ]
            ),
            HelpArticle(
                id: "building-your-baseline",
                title: "Building Your Baseline",
                icon: "chart.line.uptrend.xyaxis",
                summary: "Why the first two weeks matter and what to expect",
                sections: [
                    .text("Your personal baseline is the foundation of everything the app does. It's what makes your recovery score meaningful — not a generic number, but YOUR number relative to YOUR normal."),
                    .heading("The Timeline"),
                    .keyValue([
                        (label: "Nights 1-2", value: "General HRV thresholds. The app is learning."),
                        (label: "Night 3+", value: "Your ln(RMSSD) is compared against your own history (up to 60 days). Until 7 nights the comparison is deliberately cautious, so early scores stay near the middle."),
                        (label: "Night 14+", value: "Baseline stabilizes. The Dashboard shows your recovery score and verdict; before this it shows \"Building your baseline\"."),
                        (label: "Night 28+", value: "The score reads \"Full algorithm\". The baseline keeps growing to 60 nights, where it is at its most stable.")
                    ]),
                    .heading("Tips for a Good Baseline"),
                    .bullets([
                        "Record at the same time each day — morning is best",
                        "One reading a night goes into the baseline; if you record more than once in a night, the cleaner, more settled one is kept",
                        "Don't stress about \"bad\" readings — your baseline needs to capture your full range",
                        "Only overnight recordings go into the baseline. Quick readings still show their own result, but they are not added to it"
                    ]),
                    .note("Your displayed baseline is a 7-day rolling snapshot of recent trends. Z-score normalization uses up to 60 days of history (from up to 90 stored data points) for a stable statistical reference.")
                ]
            ),
            HelpArticle(
                id: "devices-setup",
                title: "Setting Up Your Device",
                icon: "antenna.radiowaves.left.and.right",
                summary: "H10 and Verity Sense setup, fit, and care",
                sections: [
                    .heading("Polar H10 (ECG Chest Strap)"),
                    .text("The H10 is a chest-strap ECG sensor; published studies compare its beat detection closely with clinical ECG. Its internal recording survives Bluetooth disconnections."),
                    .steps([
                        "Moisten the electrode pads with water or electrode gel",
                        "Place the strap snug but comfortable, just below your chest muscles",
                        "The H10 powers on automatically when it detects skin contact",
                        "In the app, go to Record and tap Scan for Devices — it should appear within seconds"
                    ]),
                    .tip("The electrodes need moisture to conduct. Dry electrodes = noisy signal = poor data. A few drops of water is all it takes."),
                    .divider,
                    .heading("Polar Verity Sense (Optical PPG)"),
                    .text("The Verity Sense is convenient and comfortable for overnight use. It measures optically rather than electrically, which is noisier between individual beats; the app filters what it can, and the intervals it produces are good for tracking your own trend."),
                    .note("""
                        Worth knowing where the two differ. Against a clinical ECG the H10 is excellent for time-domain HRV — peer-reviewed work reports concordance of 0.99 or better and mean absolute error under 1% for RMSSD and SDNN. For \
                        the Verity Sense the picture is thinner: it matches the H10 almost perfectly for HEART RATE, but the RMSSD comparison this app relies on comes from a single graduate thesis rather than peer-reviewed longitudinal \
                        validation. That work found posture-dependent agreement and a mean absolute error above 20%.
                        """),
                    .warning("""
                        What that means in practice: use one strap or the other and stay with it. An error above 20% is larger than most real day-to-day changes in RMSSD, so Verity numbers should never share a baseline with H10 numbers. Whether \
                        a Verity trend is still reliable for tracking YOUR own change over time is a reasonable expectation rather than something that thesis established. DFA \u{03B1}1 is the most interval-sensitive metric of all and is the \
                        one to trust least on an optical sensor.
                        """),
                    .steps([
                        "Press the button on the sensor to power it on (LED flashes)",
                        "Clip it into the armband and wear snugly on your forearm or upper arm",
                        "Ensure the optical sensor sits flat against your skin with no gaps",
                        "In the app, go to Record and tap Scan for Devices"
                    ]),
                    .note("The Verity Sense auto-disconnects after sessions to preserve battery. You don't need to manually disconnect."),
                    .divider,
                    .heading("Both Devices"),
                    .bullets([
                        "Paired devices appear in the \"Known Devices\" list for one-tap reconnection",
                        "Swipe left or long-press a device to remove it from the list",
                        "Battery level shows when connected — critical (<10%) disables recording",
                        "Keep your phone within Bluetooth range (~3-5 meters) during recording"
                    ])
                ]
            )
        ]
    )

    // MARK: Recording

    static let recording = HelpCategory(
        id: "recording",
        title: "Recording",
        icon: "waveform.path.ecg",
        color: AppTheme.primary,
        articles: [
            HelpArticle(
                id: "extended-recording",
                title: "Extended (Overnight) Recording",
                icon: "moon.fill",
                summary: "How overnight recordings work and how to get the best results",
                sections: [
                    .text("Extended recordings capture your entire night of sleep for the most comprehensive recovery analysis. The app finds the optimal 5-minute window from hours of data."),
                    .heading("Starting a Recording"),
                    .steps([
                        "Connect your Polar device before bed",
                        "On the Record tab, make sure Extended is selected",
                        "Add any tags you want (Morning tag is auto-added if the recording ends between 4–10 AM)",
                        "Tap Start Extended Recording",
                        "Lock your screen and go to sleep — the strap's Bluetooth connection keeps the recording running"
                    ]),
                    .heading("Getting Your Results"),
                    .text("""
                        When you're ready, tap I'm Up. With an H10, the app first downloads the night from the strap's memory and merges it with the streamed \
                        data. It then finds the best 5-minute analysis window, and the full Recovery Report opens automatically once analysis completes — no extra tap required.
                        """),
                    .heading("How It Stays Alive"),
                    .bullets([
                        "Heartbeat data arriving from the strap over Bluetooth keeps the recording running in the background",
                        "Your screen locks normally — no bright screen all night",
                        "If the app is closed, your data is safe — it's backed up about once a minute"
                    ]),
                    .tip("For H10 users: the app runs a hybrid recording — internal device memory (primary) plus Bluetooth streaming (backup). Even if Bluetooth drops all night, your data is captured internally on the H10.")
                ]
            ),
            HelpArticle(
                id: "quick-reading",
                title: "Quick Reading (Spot Check)",
                icon: "clock.fill",
                summary: "2-5 minute daytime readings for on-the-spot recovery checks",
                sections: [
                    .text("Quick readings are perfect for spot checks or tracking how you feel at any time of day."),
                    .heading("Duration Options"),
                    .keyValue([
                        (label: "2 minutes", value: "Basic — enough for RMSSD and core metrics"),
                        (label: "3 minutes", value: "Standard — recommended balance of speed and accuracy"),
                        (label: "5 minutes", value: "Full — complete analysis including frequency domain")
                    ]),
                    .heading("During Recording"),
                    .bullets([
                        "Sit still and breathe normally",
                        "A breathing mandala helps guide coherent breathing — optional but beneficial",
                        "Toggle voice guidance for spoken \"Breathe in\" / \"Breathe out\" cues",
                        "You can stop early if needed — the button is always available",
                        "Live stats show beats collected, elapsed time, and average RR interval"
                    ]),
                    .tip("""
                        The breathing mandala paces a ~5.5-breaths-per-minute pattern (11-second cycle). Slow paced breathing near this rate reliably increases the size of the heart-rate oscillation, which is why \
                        readings taken with it look cleaner. Two things worth knowing: the rate that maximises the effect is individual (roughly 4.5–6.5 per minute), and because 5.5 per minute is 0.09 Hz the \
                        enlarged oscillation lands in the LF band, so expect LF and LF/HF to rise and HF to fall during a paced reading.
                        """)
                ]
            ),
            HelpArticle(
                id: "split-sleep",
                title: "Split Sleep (Pause & Resume)",
                icon: "arrow.triangle.2.circlepath",
                summary: "Wake up mid-night? Pause your recording and resume later",
                sections: [
                    .text("If you wake up in the middle of the night, you don't have to lose your data or start over."),
                    .heading("How It Works"),
                    .steps([
                        "Tap Pause — your recording stops, analysis runs immediately, and the segment saves",
                        "A score preview shows your RMSSD, readiness, and HR — your data is safe",
                        "Do whatever you need — leave the app, close the screen, take your time",
                        "When ready to go back to sleep, open the Record tab",
                        "If within your merge window, a Continue Recovery card appears with your score",
                        "Tap Resume — a new linked segment starts"
                    ]),
                    .text("The best recovery score across all linked segments is used for your dashboard. Both segments are preserved in your history."),
                    .heading("Merge Window"),
                    .text("The merge window controls how long after pausing the app will offer to resume. Configure it in Settings → Sleep → Split Sleep → Combine Segments:"),
                    .keyValue([
                        (label: "Off", value: "Segments are always scored independently"),
                        (label: "Default (4.5 hrs)", value: "Standard gap — covers most mid-night wakes"),
                        (label: "Custom (1-12 hrs)", value: "Set your own window for unusual schedules")
                    ]),
                    .note("If your device disconnects or battery drops to ≤5% while paused, the session auto-finalizes. If the app is killed mid-pause, state is restored from disk on next launch.")
                ]
            ),
            HelpArticle(
                id: "data-quality",
                title: "Understanding Data Quality",
                icon: "checkmark.shield.fill",
                summary: "What artifact percentage means and how to improve it",
                sections: [
                    .text("After each recording, the app shows a quality assessment. Understanding it helps you get the most accurate readings."),
                    .heading("Quality Indicators"),
                    .keyValue([
                        (label: "Artifact %", value: "Percentage of heartbeats that look abnormal. <10% is good, <5% is excellent."),
                        (label: "Clean Beats", value: "Number of valid heartbeats. 200+ is good for analysis."),
                        (label: "Quality Score", value: "Overall signal quality percentage.")
                    ]),
                    .heading("Types of Artifacts"),
                    .bullets([
                        "Ectopic beats — Heart beat too different from neighbors (>20% deviation from local median)",
                        "Missed beats — Gap where a beat should be (>50% longer than expected)",
                        "Extra beats — Two beats where one should be (>30% shorter than expected)",
                        "Technical — Signal noise or impossible values (<300ms or >2000ms intervals)"
                    ]),
                    .heading("Improving Quality"),
                    .bullets([
                        "H10: Moisten electrodes, check strap fit, ensure good skin contact",
                        "Verity Sense: Ensure flat contact with skin, snug armband, no gaps",
                        "Both: Stay still during recording, avoid talking or moving",
                        "Replace old straps — electrodes degrade over time"
                    ]),
                    .tip("The app corrects mild artifacts automatically using interpolation and median replacement, and the window selector will not use a window above 15% artifacts."),
                    .note("""
                        Different metrics tolerate artifacts differently, so one number cannot cover them all. RMSSD and SDNN survive light correction well. DFA \u{03B1}1 is the most sensitive: Gronwald & Rogers report that correction introduces \
                        minimal bias below 3% and still little at 6%, which is why the live \u{03B1}1 readout stops reporting a value once more than 6% of a window has been corrected rather than showing a number built largely from interpolation.
                        """)
                ]
            )
        ]
    )

    // MARK: Recovery Score

    static let recoveryScore = HelpCategory(
        id: "recovery-score",
        title: "Your Recovery Score",
        icon: "gauge.with.dots.needle.bottom.50percent",
        color: AppTheme.sage,
        articles: [
            HelpArticle(
                id: "understanding-score",
                title: "Understanding Your Score",
                icon: "target",
                summary: "What the 0-100 recovery score means and how to read it",
                sections: [
                    .text("Your recovery score is a single number (0-100) that synthesizes your HRV, sleep, and vitals (respiratory rate, wrist temperature, SpO2) into one answer: how recovered are you today?"),
                    .heading("Score Ranges"),
                    .keyValue([
                        (label: "90-100 · Excellent", value: "Well above your usual range"),
                        (label: "75-89 · Good", value: "Above your usual range"),
                        (label: "60-74 · Fair", value: "Your normal range — the most common"),
                        (label: "45-59 · Pay attention", value: "Below your usual range — an easy day is worth considering"),
                        (label: "30-44 · Low", value: "Well below your usual range"),
                        (label: "0-29 · Very low", value: "Far below your usual range — worth looking at sleep, illness and recent load")
                    ]),
                    .note("""
                        These bands are the app's own, and the honest caveat is that no consumer recovery score has been independently validated: Doherty, Baldwin, Lambe, Burke & Altini (2025) reviewed 14 composite scores across 10 manufacturers \
                        and found none with rigorous independent validation in the peer-reviewed literature. Where composites have been tested, they track acute physiological stress reasonably but discriminate poorly between "good" and \
                        "excellent". So treat a move from 82 to 91 as noise, and a sustained drop as worth attention.
                        """),
                    .heading("What Makes It Personal"),
                    .text("""
                        The score isn't based on population averages. It's based on YOUR personal baseline. Your displayed baseline is a 7-day snapshot, while z-score normalization draws on up to 60 days of history for statistical accuracy. A score of \
                        90 means you're well above YOUR normal — whether your RMSSD is 30ms or 80ms. This is why building your baseline matters.
                        """),
                    .heading("Training Readiness Zone"),
                    .text("""
                        When you've exercised today, a horizontal zone bar appears below the recovery ring showing your training readiness: Rest, Fatigued, Moderate, or Ready. This combines your recovery score with your current training load to answer \
                        the practical question: should I train hard today?
                        """),
                    .note("""
                        Training load (TRIMP, CTL/ATL/TSB, ACWR, Monotony, Strain) lives on the parallel Load & Trajectory page for planning. As of the May 2026 architecture update, training metrics no longer feed the recovery score itself — research \
                        (Impellizzeri 2020/2021) showed the acute:chronic workload ratio is too noisy to predict recovery state day-to-day. The score now answers \"how recovered am I?\" using your physiology only.
                        """),
                    .tip("Day-to-day variation of ±10 points is normal. Look at your 3-day and 7-day trends rather than obsessing over a single day's number."),
                    .warning("For your first two nights, the HRV part of the score uses a simplified 1-10 readiness calculation scaled to 0-100. It works, but it's less precise than the comparison with your own baseline that starts on the third night.")
                ]
            ),
            HelpArticle(
                id: "score-tiers",
                title: "How the Score Is Calculated",
                icon: "function",
                summary: "The three-tier scoring system, and where its numbers come from",
                sections: [
                    .text("The recovery score adapts based on what data is available. As of May 2026, the composite weights are HRV 60% / Sleep 25% / Vitals 15%."),
                    .note("""
                        The inputs are research-backed; the recipe is ours. Which signals belong in a recovery score, and the ln(RMSSD) z-score method used to normalise the biggest of them, come from peer-reviewed work (Plews 2013, Buchheit 2014). \
                        The 60/25/15 split, the score bands, and the thresholds throughout this page are calibrated against practitioner heuristics and have not been validated against outcomes — no study shows this number predicts recovery, \
                        performance or injury. That is normal for a composite wellness score, including the commercial ones; it is worth knowing which half of the score is which.
                        """),
                    .heading("Tier 1 — HRV Only"),
                    .text("Always computed. Your ln(RMSSD) is converted to a z-score using up to 60 days of historical data: how many standard deviations above or below your personal average?"),
                    .bullets([
                        "At your baseline (z ≈ 0) you score in the low-70s — being at your normal IS good recovery, not mediocre. Readings within ±0.5 SD count as \"no change\" (stable).",
                        "Above baseline plateaus — the HRV component tops out around 90 no matter how high HRV goes (a big spike is ambiguous, not \"more recovered\"). Below baseline drops steeply, because under-recovery is the actionable signal.",
                        "Resting heart rate deviation: up to ±10 points",
                        "DFA α1 in the app's resting reference range (0.75-1.0): +5 points; above 1.2: −5 points; below 0.60: −3 points",
                        "7-day CV below 2%: −5 points (may signal high strain); above 12%: −3 points",
                        "Autonomic balance (the PNS index minus the SNS index): −6 points below −1.5, −3 points below −0.5, +2 points at 1.5 or above",
                        "No reading for 7 days or more: the baseline counts as stale, which costs 5 points and 5 more for each further week, up to −20",
                        "With sleep integration on, a night with no sleep data: −10 points"
                    ]),
                    .divider,
                    .heading("Tier 2 — HRV + Sleep"),
                    .text("When sleep integration is enabled and sleep data exists — either from Apple Watch via Apple Health or classified from chest strap HRV data. Sleep quality (0-100) is weighted at 30%, HRV at 70%."),
                    .text("""
                        With Apple Watch stage data, the enhanced sleep score weighs six factors: duration vs your target (25%), sleep efficiency (20%), deep+REM adequacy (20%), sleep fragmentation (15%), complete sleep cycles (10%), and sleep architecture \
                        (10%). Without stage data the same six factors are used, and the deep+REM factor is scored at half marks rather than counting against you.
                        """),
                    .note("Double-penalty dampening: when your HRV z-score is already very low AND your sleep score is poor, the sleep weight drops to 15%. This prevents counting the same bad night twice — low HRV already reflects the poor sleep."),
                    .divider,
                    .heading("Tier 3 — HRV + Sleep + Vitals"),
                    .text("When you have at least one vitals signal (respiratory rate, wrist temperature, or blood oxygen). The composite weights are HRV 60%, Sleep 25%, and Vitals 15%."),
                    // This bullet list must match the code, which is the only
                    // place the user's number actually comes from. It must NOT
                    // read "Respiratory rate (40% of vitals) / Wrist temperature
                    // (35%) / Heart rate dip during sleep (25%)":
                    //
                    // `ScoringWeights.Vitals` is 1/3 each — and
                    // `VitalsScoring.calculateVitalsScore` does not read those
                    // constants at all, it plain-averages whatever sub-scores
                    // exist. So fixed percentages are not the mechanism in use.
                    // And there is no "heart rate dip" sub-score:
                    // `restingHRSubScore` scores resting HR against baseline in
                    // SDs; no dip is computed.
                    .text("The Vitals sub-score (0-100) compares your current readings to your personal baseline. Three sub-scores, weighted equally:"),
                    .bullets([
                        "Respiratory rate: scored against your 7-day baseline, or against the 12-18 br/min population range until that baseline exists",
                        "Wrist temperature: scored on how far ABOVE baseline you are; a cooler-than-baseline night scores full marks, since that usually reflects the room rather than your recovery",
                        "Resting heart rate: scored against your personal baseline in standard deviations"
                    ]),
                    .text("If you only have one or two vitals signals (e.g. resp rate but no temperature), the vitals score is the average of the signals you have — missing signals don't penalize you."),
                    .note("SpO2 is handled separately: any reading below 95% deducts 10 points from the final score. It is a flag rather than a factor — one threshold, no baseline comparison — and the flat penalty is a deliberately conservative product rule, not a clinical assessment."),
                    .divider,
                    .heading("Comeback Mode"),
                    .text("""
                        If you flip the Comeback toggle in Settings → Modes (after illness, injury, or a long break), a score that includes vitals shifts for 21 days to HRV 80% / Sleep 20% / Vitals 0%. This stops noisy temperature or breathing readings \
                        from suppressing your score while your body re-stabilizes. A score without vitals keeps its usual weights, and the SpO₂ penalty still applies. After 21 days, weights return to standard.
                        """),
                    .divider,
                    .heading("Why HRV + Sleep + Vitals (and not Training)?"),
                    .text("""
                        Earlier versions of the app folded training load (specifically the acute:chronic workload ratio, ACWR) into the score. Two systematic reviews (Impellizzeri 2020, 2021) showed ACWR is too noisy to predict day-to-day recovery state \
                        — it's a planning lens, not a recovery lens. So training load now lives on its own page (Load & Trajectory) for planning, and the recovery score answers strictly \"how recovered is your physiology right now?\"
                        """),
                    .tip("The scoring follows Plews et al. (2013) and Buchheit (2014) for the ln(RMSSD) z-score methodology, with vitals scoring informed by the Plews/Buchheit smallest-worthwhile-change band approach.")
                ]
            ),
            HelpArticle(
                id: "comeback-mode",
                title: "Comeback Mode",
                icon: "arrow.uturn.up.circle.fill",
                summary: "Returning from illness, injury, or a long break",
                sections: [
                    .text("Comeback mode is a 21-day setting that adapts your recovery score for periods when your vitals baselines are unreliable — coming back from the flu, a long taper, post-surgery, jet lag, or any extended break."),
                    .heading("What Changes"),
                    .keyValue([
                        (label: "HRV weight", value: "80% (up from 60%)"),
                        (label: "Sleep weight", value: "20% (down from 25%)"),
                        (label: "Vitals weight", value: "0% (down from 15%)")
                    ]),
                    .text("During comeback, vitals are still displayed and tracked — they just don't pull your score down while your respiratory rate, temperature, or sleep heart rate are re-settling to a new baseline."),
                    .heading("When to Use It"),
                    .bullets([
                        "Returning from a cold or flu (last 5+ days of symptoms)",
                        "Post-injury return-to-training, especially after time off",
                        "First 1-3 weeks after a long taper, vacation, or break",
                        "Travel across multiple time zones",
                        "Any time you know your body is in transition and the vitals readings won't reflect a stable \"normal\""
                    ]),
                    .heading("How to Toggle It"),
                    .text("Settings → Modes → Comeback mode. Flip it on, and a 21-day countdown starts. The dashboard shows a small indicator so you know you're in comeback weighting. After 21 days, weights automatically return to the standard 60/25/15."),
                    .tip("You can turn comeback off early if you feel your baseline has stabilized. There's no harm in toggling — the score recomputes immediately on each session."),
                    .note("Comeback mode does not lower the bar for your score — it just changes which signals count toward it. You can still get a high or low score in comeback, based on your HRV and sleep.")
                ]
            ),
            HelpArticle(
                id: "vitals-and-feedback",
                title: "Vitals & Daily Feedback",
                icon: "lungs.fill",
                summary: "How vitals factor in, plus the daily score check",
                sections: [
                    .text("Vitals are the third leg of your recovery score (15% weight under the May 2026 architecture). They're the slow-moving signals that can shift with illness, accumulated fatigue and stress on a different timescale from HRV."),
                    .heading("What Counts as Vitals"),
                    // Not "Sleep heart rate dip … vs your daytime resting
                    // rate" — that describes a sub-score that does
                    // not exist. `VitalsScoring.restingHRSubScore` compares
                    // overnight resting HR against the personal baseline in
                    // standard deviations; no dip is computed anywhere. The
                    // score-tiers article says the same.
                    .keyValue([
                        (label: "Respiratory rate", value: "Breaths per minute during sleep, from Apple Watch."),
                        (label: "Wrist temperature", value: "Skin temperature deviation from your baseline, from Apple Watch (Series 8+)."),
                        (label: "Resting heart rate", value: "Your overnight resting heart rate, compared against your own baseline.")
                    ]),
                    .text("Each is compared against YOUR baseline (built up over the first 14-30 days). The vitals sub-score is the average of whichever signals are present — they carry equal weight. Missing signals don't penalize the score."),
                    .heading("SpO2 Is Different"),
                    .text("""
                        Blood oxygen below 95% triggers a flat -10 penalty on the final score. It's a flag rather than a factor — one threshold, no baseline comparison — and the flat penalty is a deliberately conservative \
                        product rule, not a clinical assessment. Below 95% is less common for a healthy person at sea level; altitude, sleep apnea and illness all move it, and Apple states these readings are for general \
                        fitness and wellness rather than medical use.
                        """),
                    .divider,
                    .heading("How You Feel"),
                    .text("Each morning a chip under the score asks how you feel, on five faces from Terrible to Great, with optional tags such as sore or hungover. Your answer is kept with that night's reading."),
                    .heading("Why It Matters"),
                    .text("""
                        No physiological score is perfect. Your answers sit beside your scores in History, so over weeks you can see where the score and how you felt part ways, and learn your own outliers \
                        (e.g. \"my score reads low after a late dinner\").
                        """),
                    .note("Your answer never changes the score. It is a record for you, not an input to the algorithm."),
                    .tip("If you skip the chip on a day, the score still works fine. It's optional.")
                ]
            ),
            HelpArticle(
                id: "analysis-window",
                title: "The Analysis Window",
                icon: "scope",
                summary: "How the app picks the best 5 minutes from your recording",
                sections: [
                    .text("An extended recording can be hours long, but HRV analysis works best on a short, clean segment. The app automatically finds the optimal ~5-minute window."),
                    .heading("Where It Looks"),
                    .text("The algorithm searches within the 30-70% band of your actual sleep — not your recording time. Sleep boundaries come from Apple Health when available, so if you started recording at 10 PM but didn't fall asleep until 11 PM, the search adjusts automatically."),
                    .heading("What It Looks For (Best Recovery Method)"),
                    .bullets([
                        "High RMSSD — strong parasympathetic activity",
                        "Stable heart rate — low coefficient of variation (<8%)",
                        "DFA α1 in the 0.75-1.0 reference range",
                        "Clean data — less than 15% artifacts",
                        "Sustained, not spiked — isolated high values are filtered out"
                    ]),
                    .heading("Alternative Methods"),
                    .text("In any report, you can switch the window selection method:"),
                    .keyValue([
                        (label: "Best Recovery", value: "Default. Organized, stable, high-quality window."),
                        (label: "Highest RMSSD", value: "Peak parasympathetic activity regardless of stability."),
                        (label: "Highest SDNN", value: "Peak total variability (sympathetic + parasympathetic)."),
                        (label: "Highest Total Power", value: "Peak autonomic nervous system activity."),
                        (label: "Choose Your Own", value: "Tap anywhere on the HRV chart to analyze that moment.")
                    ]),
                    .note("Manual selections are for exploration only — they're never saved to your trends or baseline. The auto-selected window is always your canonical score for consistency.")
                ]
            )
        ]
    )
}
