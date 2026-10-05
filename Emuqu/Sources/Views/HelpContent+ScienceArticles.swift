import SwiftUI

// The sleep, training-load, vitals and HRV-science help categories.
//
// Split out of `HelpContent+Science.swift` when that file passed the
// 1000-line limit — and its own enum rather than an `extension HelpContent`,
// because `check_aggregate_type_size.sh` measures a type as the sum of its
// parts across every file, which is the right measure: splitting a 2000-line
// type into four 500-line extensions does not make it smaller. These four
// categories are a self-contained body of reference copy; nothing else in
// HelpContent reads them, and the only references are the four names in the
// `categories` list.

// The metric band descriptions in this file state a
// range, not a verdict — never "potentially pathological", "clear
// parasympathetic dominance", "This IS your parasympathetic system in action"
// or "Strong sympathetic dominance — something significant is going on".
//
// One HRV-derived number cannot establish an autonomic state or a pathology,
// and App Review Guideline 1.4.1 judges a health app on whether it can
// substantiate what it asserts. The bands still say what is unusual; they no
// longer say what it means about the reader. `Tools/copy_linter` enforces the
// certainty patterns that caught these, so the wording cannot drift back.

enum HelpScienceCatalog {
    // MARK: Sleep Analysis

    @MainActor static let sleepAnalysis = HelpCategory(
        id: "sleep",
        title: "Sleep Analysis",
        icon: "moon.stars.fill",
        color: AppTheme.primaryLight,
        articles: [
            HelpArticle(
                id: "sleep-score",
                title: "Your Sleep Score",
                icon: "bed.double.fill",
                summary: "How the 0-100 sleep quality score works",
                sections: [
                    .text("The sleep score summarises your night as a single number. The inputs below are the ones sleep research consistently associates with restorative sleep; how they are weighted against each other is this app's own judgement call."),
                    .note("""
                        Read the score as a summary, not a measurement. The individual inputs — how long you slept, how much of your time in bed was asleep, how broken up it was — are measured. The weights that combine them into one number out of 100, \
                        and the bands below that turn that number into a word, are calibrated product choices. No study shows that this particular formula predicts recovery, performance or health. Your own trend in it is more useful than any \
                        single night's value.
                        """),
                    .heading("Score Components"),
                    .text("When your watch provides sleep stage data, the app uses an enhanced six-factor formula:"),
                    .keyValue([
                        (label: "Duration (25%)", value: "Hours slept vs your typical sleep target. Sleeping 10% more than target is max benefit."),
                        (label: "Efficiency (20%)", value: "Percentage of time in bed that you were actually asleep, scored against age-adjusted norms if your birthday is set."),
                        (label: "Deep & REM (20%)", value: "Deep and REM adequacy vs age-adjusted targets. Deep sleep is critical for physical recovery; REM for cognitive recovery and memory."),
                        (label: "Continuity (15%)", value: "How disrupted your sleep was — fewer wake-ups and less time awake means better recovery."),
                        (label: "Cycles (10%)", value: "Complete NREM-to-REM cycles achieved vs expected for your sleep duration."),
                        (label: "Architecture (10%)", value: "Whether your deep sleep was front-loaded and REM was back-loaded — the healthy pattern.")
                    ]),
                    .note("If stage data is unavailable (e.g., no Apple Watch), the same six factors are used; the Deep & REM factor is then scored at half marks."),
                    .heading("Score Ranges"),
                    .keyValue([
                        (label: "90-100 · Excellent", value: "Excellent sleep quality"),
                        (label: "75-89 · Good", value: "Good — meeting most targets"),
                        (label: "60-74 · Fair", value: "Fair — room for improvement"),
                        (label: "45-59 · Pay attention", value: "Short of several targets"),
                        (label: "30-44 · Low", value: "Well short of your targets — likely affecting recovery"),
                        (label: "0-29 · Very low", value: "Poor — likely affecting recovery")
                    ]),
                    .note("Deep and REM are each half of the Deep & REM factor. A stage your tracker recorded is scored as recorded, so a night with no deep sleep counts as none. A stage it didn't record at all is scored at half marks (neutral) rather than penalizing you for missing data.")
                ]
            ),
            HelpArticle(
                id: "sleep-latency",
                title: "Sleep Latency",
                icon: "clock.badge.exclamationmark",
                summary: "Why falling asleep instantly isn't a good sign",
                sections: [
                    .text("Sleep onset latency (SOL) — the time from getting into bed to falling asleep — is tracked and displayed, but intentionally excluded from the recovery score."),
                    .heading("What the Ranges Mean"),
                    .keyValue([
                        (label: "<5 minutes", value: "Very fast. Consistent with high sleep pressure — worth noticing if it's your pattern"),
                        (label: "5-10 minutes", value: "Fast — you may be carrying sleep debt"),
                        (label: "10-20 minutes", value: "The range usually described as typical for a well-rested adult"),
                        (label: "20-30 minutes", value: "Slightly slow — consider sleep hygiene adjustments"),
                        (label: ">30 minutes", value: "Difficulty falling asleep — may relate to anxiety, caffeine, or circadian timing")
                    ]),
                    .warning("Falling asleep in under 5 minutes is not a superpower — it usually means high sleep pressure, which is what builds when you're short on rest. If it's your regular pattern, more sleep is the thing to try."),
                    .note("""
                        Where the 5-minute figure comes from: the Multiple Sleep Latency Test, a clinical protocol of four or five scheduled daytime naps recorded under polysomnography, where an average onset under 5 minutes is scored as severe \
                        sleepiness. That is a different measurement from an estimated bedtime latency at home — different time of day, different setup, and a single night rather than an averaged series. The direction transfers; the clinical \
                        classification does not.
                        """),
                    .heading("Why It's Not in the Score"),
                    .text("SOL measures the process of falling asleep, not the outcome of sleep. Your recovery depends on how long you slept, how efficiently, and the quality of your sleep stages — not how quickly you got there. SOL is informational context, not a recovery metric.")
                ]
            ),
            HelpArticle(
                id: "sleep-stages",
                title: "Understanding Sleep Stages",
                icon: "brain.head.profile",
                summary: "Deep, REM, light, and awake — what each stage does for recovery",
                sections: [
                    .heading("Where Stages Come From"),
                    .text("""
                        Sleep stages can come from two sources. If you have an Apple Watch, stages are read from Apple Health. If you don't have a Watch, the app classifies stages directly from your chest strap's RR interval data using HRV patterns — no \
                        Watch required. With a Watch, you can optionally enable \"HRV-Enhanced Watch Stages\" in Settings to refine Watch stages using chest strap HRV evidence.
                        """),
                    .note("""
                        About the HRV-based stages: heart rate variability really does differ between sleep stages, and the features this app uses are the ones published cardiac sleep-staging research uses. Those published classifiers HAVE been \
                        scored against overnight lab polysomnography, and it is worth knowing what they achieve. Reviews of wearable four-class staging (wake / light / deep / REM) put average agreement around 65%, with the better systems \
                        reaching the low-to-high 70s and commercial wrist devices often lower. Even a good one disagrees with the lab on roughly one epoch in three.
                        """),
                    .note("""
                        Emuqu's own agreement with polysomnography is UNKNOWN. Not "probably lower", not "around the published range" — unmeasured. Its thresholds are hand-tuned rather than learned from labelled nights, and it has never been \
                        scored against a lab recording, so no figure above is an estimate of its accuracy. The published numbers are context for the method, not a proxy for this implementation.
                        """),
                    .note("""
                        One structural difference worth knowing while that stays unmeasured: most published systems combine a cardiac signal WITH movement from an accelerometer, and reviews find the movement channel is a large part of what \
                        lifts multi-stage performance. Emuqu classifies from chest-strap RR intervals alone. Use the stage totals rather than any single stretch, and be most sceptical of REM — the hardest stage to separate from light sleep \
                        using the heart alone.
                        """),
                    .heading("Deep Sleep"),
                    .text("Physical recovery happens here. Growth hormone release peaks during deep sleep. Your body repairs tissue, builds muscle, and strengthens the immune system. Target: ~20% of total sleep."),
                    .heading("REM Sleep"),
                    .text("Cognitive recovery and emotional processing. Your brain consolidates memories, processes emotions, and restores mental function. Target: ~25% of total sleep."),
                    .heading("Light (Core) Sleep"),
                    .text("The majority of your night. Serves as the foundation connecting deep and REM cycles. Important for overall recovery but less impactful per minute than deep or REM."),
                    .heading("Awake Time"),
                    .text("Brief awakenings are normal — most people wake 10-20 times per night without remembering. Excessive wake time (>20 minutes total) reduces sleep efficiency."),
                    .tip("You can't directly control your sleep stage ratios, but you can influence them: consistent bedtimes, cool sleeping environment, avoiding alcohol (suppresses REM), and regular exercise (increases deep sleep).")
                ]
            ),
            HelpArticle(
                id: "extended-sleep",
                title: "Watch-Based Sleep Extension",
                icon: "applewatch",
                summary: "How the app detects additional sleep after you remove your strap",
                sections: [
                    .text("If you go back to sleep after removing your chest strap, the app automatically detects the additional sleep using your Apple Watch's passive heart rate data. No action is needed — just open the app when you're done sleeping."),
                    .heading("How It Works"),
                    .steps([
                        "You finish your morning reading and remove your chest strap",
                        "You go back to sleep while still wearing your Apple Watch",
                        "When you open the app later, the dashboard checks for additional sleep",
                        "If detected, the extra sleep is merged into your total automatically"
                    ]),
                    .heading("How Detection Works"),
                    .text("""
                        If your Apple Watch's Sleep Focus is on, the Watch records sleep samples to Apple Health. When the app re-opens, it pulls any sleep that landed after your strap session ended and merges it into your total. This is the only detection \
                        method — only sleep the Watch positively recorded counts.
                        """),
                    .heading("What You'll See"),
                    .bullets([
                        "Your total sleep time increases to include the extended period",
                        "Sleep stages reflect what the Watch recorded (deep, REM, core, awake)",
                        "Your sleep score updates to reflect the longer sleep duration"
                    ]),
                    .tip("Enable Sleep Focus on your Apple Watch for this feature to work. Without Sleep Focus on, the Watch doesn't write the sleep samples the app needs to detect the extension.")
                ]
            )
        ]
    )

    // MARK: Training Load

    @MainActor static let trainingLoad = HelpCategory(
        id: "training",
        title: "Training Load",
        icon: "figure.run",
        color: AppTheme.terracotta,
        articles: [
            HelpArticle(
                id: "elevation-accuracy",
                title: "How Emuqu Measures Elevation",
                icon: "mountain.2.fill",
                summary: "Barometric altitude, and the signal processing behind your elevation gain",
                sections: [
                    .text("Elevation gain is one of the hardest metrics in a fitness app to get right. GPS altitude has ±5–10 m of noise per fix; sum it naively over a 60-min walk and you get 2× the real climb. Emuqu implements the sports-biomechanics sensor-fusion approach instead."),
                    .heading("What we do"),
                    .steps([
                        "During your walk, the app collects every reading from the iPhone's barometric pressure sensor (CMAltimeter) at ~1 Hz. Every sample is buffered — nothing is discarded at collect time.",
                        "At session stop, the full sample buffer runs through a symmetric moving-average smoother (15-sample window ≈ 15 seconds). This matches the ~8 s complementary-filter time constant recommended in the sports-fusion literature.",
                        "Gain and loss are summed from the smoothed signal: a climb or descent counts once the smoothed altitude turns back by 2 m — well above the CMAltimeter documented noise floor (0.3–0.5 m).",
                        "The processed value is written to the session archive. The live ticker showing elevation during your walk is just a rough estimate; the number that lands in History is the properly-processed one."
                    ]),
                    .heading("Why this is more accurate than threshold-on-raw"),
                    .bullets([
                        "Barometric readings have random noise. Per-sample differencing accumulates bias (√N × noise) over a session.",
                        "Smoothing BEFORE differencing kills high-frequency noise without biasing the sustained trend — the actual climb.",
                        "The offline smoother has zero phase lag (symmetric kernel) — so the climbs aren't shifted in time.",
                        "A small threshold (2 m) on the smoothed signal catches only real terrain changes, not sensor jitter."
                    ]),
                    .note("Every iPhone since iPhone 6 has a barometer. If the barometer isn't available, the app falls back to GPS altitude and counts only changes of 5 m or more, which is much less precise."),
                    .heading("Older sessions (from before this fix)"),
                    .text("""
                        Sessions recorded before the barometer buffer existed have no stored samples to post-process. Open the session summary and tap \"Look up and save real elevation\" — it queries a real terrain DEM (USGS NED 10 m in the US, NASA \
                        SRTM 30 m elsewhere) at each GPS coordinate along your route, applies a 15 m sustained-climb threshold calibrated against barometric ground truth, and writes the result back. Always an approximation vs the live barometer, but \
                        much closer to truth than raw GPS altitude.
                        """),
                    .heading("Why no raw-GPS-altitude smoothing?"),
                    .text("GPS vertical accuracy is ±5–10 m per fix. Over a typical walk that integrates to massive overcount or severe undercount depending on the threshold. It isn't signal to be extracted — you need a different sensor. That's what the barometer is for."),
                    .heading("References"),
                    .bullets([
                        "Barczyk & Nemra 2014 — \"A Sensor Fusion Method for Tracking Vertical Velocity and Height Based on Inertial and Barometric Altimeter Measurements,\" PMC4179067.",
                        "Apple CMAltimeter documentation — sub-meter barometric accuracy in steady conditions.",
                        "Zaliva & Franchetti (Carnegie Mellon) — Barometric + GPS altitude fusion whitepaper."
                    ])
                ]
            ),
            HelpArticle(
                id: "training-metrics",
                title: "Training Metrics Explained",
                icon: "chart.bar.fill",
                summary: "ATL, CTL, TSB, ACWR, Monotony, and Strain — what they mean for your training",
                sections: [
                    .text("Training load integration pulls workout data from Apple Health and calculates key metrics used by elite athletes and coaches worldwide."),
                    .heading("The Core Metrics"),
                    .keyValue([
                        (label: "ATL", value: "Acute Training Load — 7-day exponentially weighted average. Represents recent fatigue."),
                        (label: "CTL", value: "Chronic Training Load — 42-day exponentially weighted average. Represents fitness."),
                        (label: "TSB", value: "Training-load balance (form) — CTL minus ATL. Positive = fresh, negative = fatigued."),
                        (label: "ACWR", value: "Acute:Chronic Workload Ratio — ATL / CTL. Flags rapid load spikes relative to your fitness base.")
                    ]),
                    .heading("Reading TSB"),
                    .bullets([
                        "Positive TSB = recent load is below your chronic base — the bookkeeping equivalent of fresh",
                        "TSB near zero = Balanced — training matches recovery",
                        "Negative TSB = Training load exceeds your recovery — building fitness but accumulating fatigue",
                        "Very negative TSB = Heavy accumulated fatigue — consider a recovery week"
                    ]),
                    .note("""
                        How much to trust TSB. It comes from Banister's impulse-response model, which has been fitted to real athletes across running, swimming, cycling and triathlon for fifty years — so it is a genuine model, not an invention. \
                        But the reviews of it (Hellard and colleagues) find the fitted parameters are often unstable and the fit frequently not accurate enough to PROJECT a future performance, and Banister himself suggested re-fitting every \
                        60–90 days against regular maximal tests — which nobody does outside a lab. Read TSB as an accounting summary of what you have done, not a forecast of what you will do.
                        """),
                    .heading("Monotony & Strain"),
                    .text("Foster's Monotony and Strain complement ACWR by looking at your training pattern rather than just the load spike."),
                    .keyValue([
                        (label: "Monotony", value: "How repetitive your training is over 7 days. Above 2.0 in a week with real training, Load & Trajectory and the Training Load screen warn that your training has been unusually similar day to day, and the Training Load screen shows the value."),
                        (label: "Strain", value: "Your weekly training load multiplied by monotony. The app doesn't show it as a number; high strain with high monotony is the classic accumulated-fatigue pattern the monotony warning points to.")
                    ]),
                    .tip("The fix for high monotony is simple: vary your training. Hard days, easy days, rest days. A 3:1 structure (three progressive days, one recovery) keeps monotony low naturally."),
                    .note("Training context (ATL, CTL, TSB, yesterday's TRIMP) is permanently baked into every session at capture time. This ensures historical accuracy even if your workout data changes later.")
                ]
            ),
            HelpArticle(
                id: "acwr-zones",
                title: "ACWR Training Zones",
                icon: "gauge.with.dots.needle.bottom.50percent",
                summary: "The acute:chronic workload ratio and what it tells you",
                sections: [
                    .text("""
                        The Acute:Chronic Workload Ratio (ACWR) compares your recent training (7 days) to your longer-term fitness (42 days). The original framing (Gabbett 2016) tied this ratio to outcomes in elite team-sport athletes; subsequent research \
                        (Impellizzeri et al. 2020/2021) demonstrated that the chronic denominator carries little real signal — replacing it with random numbers produced nearly identical statistical relationships. Emuqu shows ACWR as a descriptive \
                        load-range indicator, and does not present it as a predictor of any outcome.
                        """),
                    .note("""
                        Where ACWR does and doesn't act: it does NOT feed your Recovery Score — that score is physiology only. It DOES apply a small damper to Training Readiness above 1.3, on the general principle that the body absorbs gradual change \
                        better than abrupt change. That damper is heavily restrained: it scales down when your chronic load is too low for the ratio to be stable, and is capped near zero on mornings when your recovery score already says you're \
                        recovered. Your own physiology outranks the bookkeeping when the two disagree.
                        """),
                    .heading("The Ranges"),
                    .keyValue([
                        (label: "< 0.8 — Below your usual", value: "Recent training is lower than your fitness base. Could be a taper, a rest week, illness, or natural variation."),
                        (label: "0.8–1.0 — Maintenance", value: "Recent training roughly matches your longer-term base — enough to hold your fitness."),
                        (label: "1.0–1.3 — In range", value: "Recent training is a little above your longer-term base. Sustainable territory for building fitness."),
                        (label: "1.3–1.5 — Above your usual", value: "Recent training is heavier than your longer-term base. Could be a planned overreach block or an unstructured ramp — context matters."),
                        (label: "> 1.5 — Sharp increase", value: "Recent training has jumped well beyond your usual range. The size of the change is what's worth noticing — an easier session helps your body absorb the work.")
                    ]),
                    .note("ACWR is a descriptive number, not a precise predictor of anything. A 1.4 during a planned overreach in a periodized program is different from a 1.4 after a month off. Read it as one of several signals — alongside HRV, sleep, monotony, and how you actually feel."),
                    .warning("A sudden jump (e.g. 0.8 → 1.6 in a week) is more notable than a gradual climb. Not because the number is dangerous in itself, but because the body adapts to gradual change better than to abrupt change."),
                    .tip("A well-built chronic training load (high CTL) gives you more capacity to handle heavier weeks. Build CTL gradually and vary your training intensity day-to-day to keep Monotony low.")
                ]
            )
        ]
    )

    // MARK: Vitals
}

// Continued: vitals and HRV science. Split to keep each enum
// body under the 500-line SwiftLint limit — the same reason the categories
// left HelpContent in the first place.
extension HelpScienceCatalog {
    static let vitals = HelpCategory(
        id: "vitals",
        title: "Recovery Vitals",
        icon: "stethoscope",
        color: AppTheme.mist,
        articles: [
            HelpArticle(
                id: "vitals-overview",
                title: "What Vitals Tell You",
                icon: "heart.circle.fill",
                summary: "Respiratory rate, SpO2, temperature, and resting HR as recovery signals",
                sections: [
                    .text("Recovery vitals from your Apple Watch add context that HRV alone can miss — overnight breathing, temperature and resting heart rate, which shift with hard training, alcohol, heat, altitude, and sometimes the start of an illness."),
                    .heading("The Vitals"),
                    .keyValue([
                        (label: "Respiratory Rate", value: "Breaths per minute during sleep. Typical: 12-20. More than 2 above your 7-day baseline is a notable deviation."),
                        (label: "Blood Oxygen (SpO2)", value: "Average during sleep. Typical range: 95-100%. Sustained readings below 95% are worth raising with a clinician."),
                        (label: "Wrist Temperature", value: "Actual temperature with deviation from your 7-day baseline. More than 0.5°C above baseline is a notable deviation."),
                        (label: "Resting Heart Rate", value: "Your overnight heart rate from the strap's analysis window, or Apple's resting heart rate when there's no strap recording. Elevated relative to your baseline often accompanies incomplete recovery.")
                    ]),
                    .heading("When Two Signals Move Together"),
                    .text("""
                        When BOTH respiratory rate AND wrist temperature sit above your baseline, the app surfaces that combination rather than letting either pass unremarked. Two signals moving together is more informative \
                        than one, and this pattern often appears a day or two before people report feeling unwell. It is a prompt to pay attention, not a finding — plenty of ordinary things move both numbers, including a \
                        warm bedroom, alcohol, and a hard session the day before.
                        """),
                    .note("""
                        How well this works, in numbers — and the numbers are humbling. In CONTROLLED studies, where volunteers were deliberately inoculated with flu or a cold while wearing research sensors, models on these signals separated \
                        infected from uninfected at roughly 88-92%. The often-quoted "detects it a day before symptoms" figure from that work is about something narrower: distinguishing MILD from MODERATE illness, not detecting that an \
                        infection was present at all.
                        """),
                    .warning("""
                        The real-world number is the one that matters. A prospective study of health-care workers wearing consumer smartwatches generated 665 alerts, of which 512 were acted on with a test. Across the study there were 80 \
                        infection events in total, but only 63 of them had an alert before them — 17 arrived with no warning at all. On the paper's own intent-to-treat definition the positive predictive value was 4% for SARS-CoV-2 and 9% for \
                        respiratory infections generally.
                        """),
                    .warning("""
                        Both halves of that matter. Nine or more alerts in ten were not a confirmed infection, so an alert is weak evidence on its own. And roughly one infection in five produced no alert, so silence is not reassurance. A low \
                        daily false-positive rate and a useful alert are not the same thing: on any given day infection is rare, so most positives are false even when the daily error rate looks small.
                        """),
                    .note("""
                        Two more things worth knowing about that evidence. It used a trained convolutional model over resting heart rate, respiratory rate, RMSSD, HRV entropy, a five-day history and demographics — not hand-set thresholds like \
                        the ones here. And the widely repeated "43% sensitivity, 95% specificity" pair did not come from that prospective study at all; it came from earlier retrospective work based on self-reported illness with no laboratory \
                        confirmation. Emuqu's own rule has never been tested by either method.
                        """),
                    .tip("""
                        Vitals are a 15% weighted factor in your recovery score (Tier 3). SpO2 is handled separately: any reading below 95% applies a flat -10. That is a deliberately blunt product rule for a signal with one \
                        threshold and no baseline comparison — not a clinical assessment. Apple states that Apple Watch blood-oxygen measurements are for general fitness and wellness, and are not intended for medical use.
                        """),
                    .note("""
                        Why that threshold is blunt on purpose. Across validation studies the Apple Watch averages very close to a reference oximeter — pooled bias near zero — but INDIVIDUAL readings in the 90-100% range can sit up to about \
                        six percentage points either side of the true value. A single 93% could be a true 93%, or a true 99%. Accuracy is poorer at genuinely low saturation, and optical oximetry is documented to over-read in people with \
                        darker skin. One night below 95% is a reason to look again, not a finding.
                        """),
                    .note("""
                        Tap the Vitals chip on your Dashboard to see your vitals; they also appear on the Sleep screen. Most require an Apple Watch. Without one, vitals sections won't appear and your score will fall back to the HRV-only or HRV + Sleep tier — sleep \
                        stages still work via HRV classification from your chest strap.
                        """)
                ]
            )
        ]
    )

    // MARK: HRV Science

    @MainActor static func hrvScience(forAge age: Int? = nil) -> HelpCategory {
        HelpCategory(
            id: "hrv-science",
            title: "HRV Science",
            icon: "brain",
            color: AppTheme.sdnnColor,
            articles: [whatIsHRV(forAge: age), metricsGuide(forAge: age), dfaExplainedArticle()]
        )
    }

    /// The standalone DFA \u{03B1}1 article — the one metric that gets its own piece,
    /// because it describes something the amplitude metrics cannot.
    private static func dfaExplainedArticle() -> HelpArticle {
        HelpArticle(
            id: "dfa-explained",
            title: "DFA \u{03B1}1 — The Hidden Gem",
            icon: "waveform.circle.fill",
            summary: "What fractal correlation adds to the amplitude metrics",
            sections: dfaExplainedSections
        )
    }

    /// The body of the DFA article, kept apart from its metadata.
    ///
    /// This article must not run a fixed resting-\u{03B1}1
    /// interpretation: 0.75-1.0 as "the gold standard … consolidated and
    /// load-bearing", \u{03B1}1 near 0.5 as "not recovery", and a high RMSSD
    /// alongside it as "a mirage". None of that is established. The published
    /// 0.75 anchor comes from graded EXERCISE protocols, where \u{03B1}1 falls as
    /// intensity rises; it was never a resting readiness band.
    ///
    /// The clinching argument was internal, not literary. Deep sleep — the
    /// stage most associated with physical restoration — carries the LOWEST
    /// \u{03B1}1 of the night. `WindowSelector.RecoveryWindow` cites the figures
    /// (PMC4100066): N1 0.89 \u{00B1} 0.23, N2 0.85 \u{00B1} 0.16, N3 0.78 \u{00B1} 0.21.
    /// N3 sits on the bottom EDGE of the 0.75 "gold standard" line, with a
    /// spread wide enough that a large share of perfectly normal deep sleep
    /// falls below it. A band whose lower bound bisects the most restorative
    /// stage of the night cannot be the line between real recovery and noise.
    ///
    /// Care is needed with the neighbouring claim. `HRVSleepStageClassifier`
    /// cites Bunde 2000 / Penzel 2003 for deep sleep being "~0.5-0.7", and
    /// those papers do report NREM heart rates as essentially uncorrelated —
    /// but ABOVE the breathing-cycle timescale, which is not where \u{03B1}1 is
    /// measured. \u{03B1}1 is the short-scale exponent, inside the respiratory
    /// band. Both citations are sound about different scales; only the
    /// PMC4100066 figures speak to \u{03B1}1 directly, so those are the ones
    /// quoted to users. See the note in `HRVSleepStageClassifier`.
    ///
    /// What survives: \u{03B1}1 describes correlation structure rather than
    /// amplitude, which is genuinely something RMSSD does not capture, and the
    /// ranges are still worth showing. They are shown as ranges now.
    private static var dfaExplainedSections: [ArticleSection] {
        [
            .text("""
                DFA \u{03B1}1 (Detrended Fluctuation Analysis, short-term scaling exponent) is the least intuitive number the app computes. RMSSD tells you HOW MUCH your beat-to-beat intervals vary. \u{03B1}1 describes the PATTERN of that variation — \
                whether successive intervals are correlated with each other or drift independently. Two recordings can share an RMSSD and differ in \u{03B1}1.
                """),
            .heading("What the number describes"),
            .text("""
                Around 1.0, intervals are strongly correlated — each one carries information about the next. Around 0.5, they are statistically uncorrelated. Neither of those is a verdict on you. \u{03B1}1 moves with intensity, with sleep stage, with \
                posture and with breathing, so the same value means different things in different contexts.
                """)
        ] + dfaRangeSections
    }

    /// The range table and the two notes that qualify it.
    private static var dfaRangeSections: [ArticleSection] {
        [
            .heading("Typical resting ranges"),
            .keyValue([
                (label: "0.75-1.0", value: "The most common range for a resting adult recording. The app treats it as its reference range."),
                (label: "0.60-0.75", value: "Below the reference range. Common, and on its own not a concern."),
                (label: "~0.5", value: "Intervals close to uncorrelated. Uncommon in a resting adult recording — worth repeating the reading."),
                (label: ">1.0", value: "More correlated than the reference range. Seen with stress and with mental load, and also simply with slow, regular breathing."),
                (label: "<0.5", value: "Outside the range these bands were characterised over — worth a second reading before reading anything into it.")
            ]),
            .note("""
                Where the numbers come from: the 0.75 figure is well established as a threshold marker during GRADED EXERCISE, where \u{03B1}1 falls predictably as intensity rises (Rogers & Gronwald). Its use as a fixed RESTING readiness scale is this \
                app's own convention and is not validated. Sleep research is a good reason for caution about it: \u{03B1}1 is at its lowest during deep sleep — around 0.78 for N3 against 0.85 for N2 and 0.89 for N1 — which puts the stage most \
                associated with physical restoration at the very bottom of the range above, not the top.
                """)
        ] + dfaLiveExerciseNotes
    }

    /// The two notes that qualify the resting bands — where the 0.75 anchor
    /// comes from, and how much a live in-workout value can be trusted.
    private static var dfaLiveExerciseNotes: [ArticleSection] {
        [
            .note("""
                One more caveat, for the live \u{03B1}1 readout during workouts. Even a chest strap is not the same as an ECG for this metric: against ECG, chest-strap \u{03B1}1 shows limits of agreement of about \u{00B1}10% at low intensity, \
                widening to roughly +58% / \u{2212}41% at high intensity. The band the app shows you (Easy / Threshold / Hard) is a reasonable live guide, but a single \u{03B1}1 value at hard effort carries a lot of uncertainty, and that is \
                before anything the artifact filter has had to correct.
                """),
            .tip("The default window selection method (Best Recovery) prefers windows with \u{03B1}1 in the 0.75-1.0 range, which is how it lands on a stable, low-movement stretch of the night rather than a restless one. That is a window-picking rule, not a judgement about the reading it produces.")
        ]
    }

    // MARK: Age-Personalized Articles

    private static func whatIsHRV(forAge age: Int?) -> HelpArticle {
        HelpArticle(
            id: "what-is-hrv",
            title: "What Is HRV?",
            icon: "waveform.path.ecg",
            summary: "Heart rate variability — what it is and why it matters",
            sections: [
                .text("Heart Rate Variability (HRV) is the variation in time between consecutive heartbeats. A heart rate of 60 bpm doesn't mean one beat per second — the intervals vary: 980ms, 1020ms, 970ms, 1050ms. That variation IS your HRV."),
                .heading("Why Variability Is Good"),
                .text("A healthy heart doesn't beat like a metronome. Higher variability means your autonomic nervous system (ANS) is responsive — it can quickly shift between \"go\" (sympathetic) and \"rest\" (parasympathetic) modes. This flexibility = resilience."),
                .heading("What Affects HRV"),
                .bullets(hrvInfluences(forAge: age)),
                .tip("HRV is one of the most sensitive non-invasive markers of autonomic nervous system function. Changes in HRV often appear before you feel anything subjectively.")
            ]
        )
    }

    /// What moves HRV. The age line is personalised when we know the reader's age.
    private static func hrvInfluences(forAge age: Int?) -> [String] {
        let ageBullet = age.map {
            HelpLocalization.format("Age — at {age}, your ANS has a natural baseline that differs from a 20-year-old's. This is normal physiology, and the app accounts for it", ["age": "\($0)"])
        } ?? "Age (HRV naturally decreases with age)"
        return [
            "Sleep quality and duration",
            "Training load and recovery status",
            "Stress (both physical and psychological)",
            "Alcohol consumption",
            "Illness and immune activation",
            ageBullet,
            "Fitness level (higher fitness generally = higher HRV)"
        ]
    }

    /// One age band's RMSSD reference copy. The literal token `{age}` inside
    /// `context` stands in for the reader's actual age and is substituted at
    /// lookup, since a stored string cannot interpolate.
    private struct RMSSDAgeBand {
        let upperBound: Int
        let groupLabel: String
        let range: String
        let median: String
        let context: String
        let athleteGroup: String
        let athleteRange: String
    }

    /// Age-banded RMSSD norms. Kept as a table rather than a switch so the copy
    /// for one decade can be edited without reading the other six.
    private static let rmssdAgeBands: [RMSSDAgeBand] = [
        RMSSDAgeBand(
            upperBound: 20, groupLabel: "Under 20", range: "30-120 ms", median: "~55 ms",
            context: "Your autonomic nervous system is at its most dynamic. High variability is normal and expected — enjoy it. Focus on building consistent habits now.",
            athleteGroup: "Young athletes", athleteRange: "70-130+ ms"
        ),
        RMSSDAgeBand(
            upperBound: 30, groupLabel: "20s", range: "25-105 ms", median: "~42 ms",
            context: "Your ANS is near peak capacity. You have a wide range to work with, and good sleep and fitness habits pay off directly in higher HRV.",
            athleteGroup: "Endurance athletes in their 20s", athleteRange: "60-120+ ms"
        ),
        RMSSDAgeBand(
            upperBound: 40, groupLabel: "30s", range: "20-80 ms", median: "~35 ms",
            context: "Your parasympathetic tone is starting a gradual, natural decline. Aerobic fitness and sleep quality become increasingly important levers for maintaining strong HRV.",
            athleteGroup: "Active athletes in their 30s", athleteRange: "45-90+ ms"
        ),
        RMSSDAgeBand(
            upperBound: 50, groupLabel: "40s", range: "15-60 ms", median: "~25 ms",
            context: "HRV has declined meaningfully from your 20s — that's biology, not a problem. An RMSSD of 25ms at {age} reflects the same relative autonomic health as 42ms at 25. Your personal baseline is what matters now.",
            athleteGroup: "Athletes in their 40s", athleteRange: "30-75+ ms"
        ),
        RMSSDAgeBand(
            upperBound: 60, groupLabel: "50s", range: "10-50 ms", median: "~22 ms",
            context: "Your autonomic nervous system has matured significantly. Lower absolute numbers are completely expected. Consistent aerobic exercise is the single strongest lever for maintaining parasympathetic tone at this stage.",
            athleteGroup: "Active individuals in their 50s", athleteRange: "25-55+ ms"
        ),
        RMSSDAgeBand(
            upperBound: 70, groupLabel: "60s", range: "8-40 ms", median: "~18 ms",
            context: "Decades of life bring natural changes in autonomic function. What matters is YOUR baseline and how it trends. Many active people in their 60s maintain strong relative parasympathetic tone through consistent exercise and quality sleep.",
            athleteGroup: "Fit individuals in their 60s", athleteRange: "20-45+ ms"
        ),
        RMSSDAgeBand(
            upperBound: Int.max, groupLabel: "70+", range: "6-35 ms", median: "~15 ms",
            context: "HRV values are naturally lower, but the relative patterns still carry the same meaning. A rising trend in YOUR numbers still means improving recovery; a falling trend still means your body needs attention.",
            athleteGroup: "Active individuals over 70", athleteRange: "15-35+ ms"
        )
    ]

    /// The band this age falls in, with `{age}` resolved in its copy.
    ///
    /// Returns the band itself rather than a five-member tuple (which would be
    /// `RMSSDAgeBand` minus `upperBound`, member for member, under a
    /// `large_tuple` waiver).
    private static func rmssdContext(forAge age: Int) -> RMSSDAgeBand {
        let band = rmssdAgeBands.first { age < $0.upperBound } ?? rmssdAgeBands[rmssdAgeBands.count - 1]
        return RMSSDAgeBand(
            upperBound: band.upperBound,
            groupLabel: band.groupLabel,
            range: band.range,
            median: band.median,
            context: HelpLocalization.format(band.context, ["age": "\(age)"]),
            athleteGroup: band.athleteGroup,
            athleteRange: band.athleteRange
        )
    }

    /// The RMSSD portion of the metrics guide.
    ///
    /// Personalised against the reader's age band when we know it, generic when
    /// we do not — genuinely different copy rather than a formatting variation,
    /// which is why it was a branch and not a parameter.
    private static func rmssdIntroSections(forAge age: Int?) -> [ArticleSection] {
        guard let age else {
            return [.tip("Set your birthday in Settings \u{2192} Profile to see ranges personalized for your age. For now, here are general population guidelines — what matters most is YOUR trend over time.")]
                + genericRMSSDSections()
        }
        return [.tip(HelpLocalization.format("These ranges are calibrated for your age ({age}). Your autonomic nervous system at {age} is different from a 25-year-old's — that's normal physiology. What matters most is YOUR personal trend over time, not how your numbers compare to someone else's.", ["age": "\(age)"]))]
            + personalizedRMSSDSections(forAge: age)
    }

    /// The definition of RMSSD — identical whether or not we know the reader's age.
    private static func rmssdOpening() -> [ArticleSection] {
        [
            .heading("RMSSD — Your Core Recovery Metric"),
            .text("Root Mean Square of Successive Differences. Measures the beat-to-beat variation in your heart rate, driven primarily by your parasympathetic (rest-and-digest) nervous system. It is the most widely studied HRV measure for day-to-day tracking."),
            .keyValue([
                (label: "What it measures", value: "Parasympathetic nervous system activity — your body's \"brake pedal\""),
                (label: "Higher means", value: "Stronger vagal tone, better recovery capacity, more resilient nervous system"),
                (label: "Lower means", value: "Reduced recovery, accumulated stress, or incomplete adaptation to training")
            ])
        ]
    }

    /// The log-transform note and the what-moves-it list that close the RMSSD
    /// entry in both the personalised and the generic variant.
    private static func rmssdMovers() -> [ArticleSection] {
        [
            .note("""
                The app uses ln(RMSSD) — the natural log — for scoring and trend analysis. The log transform reduces the impact of outliers and makes day-to-day changes more proportional. A jump from 30\u{2192}60 ms and 60\u{2192}120 ms both represent \
                the same relative improvement in log space.
                """),
            .note("""
                Why a percentage is the wrong unit. A 20% drop means something very different for someone whose RMSSD swings 15% day to day than for someone whose swings 40%. The published approach (Plews, Buchheit) is to express today \
                against YOUR own spread — the smallest worthwhile change, half a standard deviation of your log-transformed baseline. That is what the app computes, and why the same millisecond drop can read as "stable" one week and \
                "below baseline" another.
                """),
            .heading("What Moves Your RMSSD"),
            .bullets([
                "Drives it UP: quality sleep, aerobic fitness, proper recovery between hard sessions, hydration, relaxation techniques",
                "Drives it DOWN: poor sleep, heavy sustained training load, alcohol (even moderate amounts), illness, acute stress, dehydration",
                "Below your own normal: no fixed percentage is used. The app converts ln(RMSSD) to a z-score against your rolling baseline and treats ±0.5 SD as no meaningful change — the smallest-worthwhile-change band from Plews and Buchheit",
                "Consistently above your average is the pattern usually associated with being well recovered"
            ]),
            .divider
        ]
    }

    /// RMSSD copy quoting the reader's own age band.
    private static func personalizedRMSSDSections(forAge age: Int) -> [ArticleSection] {
        let ctx = rmssdContext(forAge: age)
        return rmssdOpening() + [
            .text(HelpLocalization.format("For your age group ({group}):", ["group": HelpLocalization.string(ctx.groupLabel)])),
            .keyValue([
                (label: "Your typical range", value: HelpLocalization.format("{range} (median {median})", ["range": ctx.range, "median": ctx.median])),
                (label: "Above median", value: "Your parasympathetic system is responding well — strong recovery capacity for your age"),
                (label: "Below median", value: "Room to improve through better sleep, stress management, or aerobic fitness"),
                (label: ctx.athleteGroup, value: HelpLocalization.format("Often {range}", ["range": ctx.athleteRange]))
            ]),
            .text(ctx.context)
        ] + rmssdMovers()
    }

    /// RMSSD copy for a reader whose age we do not know: the full age table.
    private static func genericRMSSDSections() -> [ArticleSection] {
        rmssdOpening() + [
            .text("General population ranges (age-dependent):"),
            .keyValue([
                (label: "Age 20-29", value: "Typical: 25-105 ms (median ~42 ms)"),
                (label: "Age 30-39", value: "Typical: 20-80 ms (median ~35 ms)"),
                (label: "Age 40-49", value: "Typical: 15-60 ms (median ~25 ms)"),
                (label: "Age 50+", value: "Typical: 6-50 ms, lower with each decade (median ~22 ms in the 50s, ~18 ms in the 60s, ~15 ms over 70)"),
                (label: "Endurance athletes", value: "Often 20-50% above age norms")
            ])
        ] + rmssdMovers()
    }

    /// The metrics that are not age-dependent — SDNN, pNN50, heart rate, LF/HF
    /// power and the rest — as shared copy with actionable guidance. Each metric
    /// keeps its own factory so the copy for one never crowds out the others.
    private static func metricsGuideSharedSections() -> [ArticleSection] {
        [
            sdnnSection(),
            pnn50Section(),
            heartRateSection(),
            lfPowerSection(),
            hfPowerSection(),
            lfhfRatioSection(),
            poincareSection(),
            dfaAlpha1Section(),
            stressIndexSection(),
            readinessSection()
        ].flatMap { $0 }
    }

    /// SDNN
    private static func sdnnSection() -> [ArticleSection] {
        [
                .heading("SDNN — Total Autonomic Power"),
                .text("Standard Deviation of all NN intervals. Unlike RMSSD which only captures beat-to-beat changes, SDNN reflects TOTAL heart rate variability — both your sympathetic (fight-or-flight) and parasympathetic (rest-and-recover) branches working together."),
                .keyValue([
                    (label: "What it measures", value: "Overall autonomic nervous system capacity — both branches combined"),
                    (label: "Higher means", value: "Greater overall ANS flexibility — your body can respond to diverse demands"),
                    (label: "Lower means", value: "Reduced autonomic function or one branch dominating the other"),
                    (label: "Typical range", value: "Short-term (5 min): 50-100+ ms. Depends heavily on recording duration.")
                ]),
                .tip("Compare SDNN only between recordings of similar duration. A 5-minute and 8-hour recording aren't comparable because slower rhythms need time to express. RMSSD is more consistent across different recording lengths — that's why it's the primary recovery metric."),
                .divider
        ]
    }

    /// pNN50
    private static func pnn50Section() -> [ArticleSection] {
        [
                .heading("pNN50 — Recovery Fraction"),
                .text("The percentage of successive heartbeats that differ by more than 50ms. Think of it as: \"What fraction of my heartbeats are showing strong parasympathetic influence right now?\""),
                .keyValue([
                    (label: "What it measures", value: "The proportion of heartbeats with significant vagal modulation"),
                    (label: "0-5%", value: "Low. Common during stress, after poor sleep, or after hard training"),
                    (label: "5-15%", value: "Moderate — a typical resting range"),
                    (label: "15-25%+", value: "High — at rest, usually seen alongside a high RMSSD"),
                    (label: "Why it matters", value: "Sometimes easier to intuit than RMSSD: \"15% of my heartbeats show strong recovery activity\" is tangible")
                ]),
                .divider
        ]
    }

    /// Heart Rate
    private static func heartRateSection() -> [ArticleSection] {
        [
                .heading("Heart Rate — The Essential Context"),
                .text("Mean HR, Min HR, and Max HR aren't just side numbers — they're essential context for interpreting everything else. HRV without heart rate is only half the picture."),
                .keyValue([
                    (label: "Mean HR", value: "Your average during the 5-min analysis window. Lower at rest = fitter cardiovascular system. Typical resting: 50-80 bpm."),
                    (label: "Min HR", value: "Lowest rate in the full recording. During overnight sessions, this typically occurs in deep sleep — it's a marker of your deepest recovery state."),
                    (label: "Max HR", value: "Highest rate in the full recording. Overnight spikes may indicate disrupted sleep, movement, or stress dreams.")
                ]),
                .text("Your overnight heart rate, against your own baseline, moves the recovery score by up to 10 points: lower than usual adds, higher subtracts. A rise of 5+ bpm over your usual level suggests incomplete recovery even if RMSSD looks normal."),
                .note("Resting HR above baseline with RMSSD below baseline is a pattern worth watching. It commonly follows hard training, short sleep, alcohol or stress, and sometimes illness. If it lasts several days, an easier day is reasonable."),
                .divider
        ]
    }

    /// LF Power
    private static func lfPowerSection() -> [ArticleSection] {
        [
                .heading("LF Power — Not What You Think"),
                .text("""
                    Low Frequency power (0.04-0.15 Hz). Often incorrectly called \"sympathetic activity\" in older references. Modern research has debunked this — LF actually reflects your baroreceptor loop, the system that constantly fine-tunes blood \
                    pressure, using BOTH nervous system branches.
                    """),
                .keyValue([
                    (label: "What it actually measures", value: "Baroreceptor-mediated blood pressure regulation — a mixed signal"),
                    (label: "High LF at rest", value: "Active blood pressure regulation. Not necessarily stress."),
                    (label: "Very low LF", value: "Uncommon at rest. Read it next to your other metrics rather than on its own"),
                    (label: "Bottom line", value: "Don't interpret LF in isolation. It's context for other metrics, not a standalone verdict.")
                ]),
                .note("The \"LF = sympathetic\" myth was debunked by Billman (2013) and Reyes del Paso (2013). LF power during rest is substantially mediated by vagal activity. The app includes it for completeness but never uses it as a primary recovery indicator."),
                .divider
        ]
    }

    /// HF Power
    ///
    /// This section must not say slow breathing "directly increases
    /// HF power" or that the mandala's ~5.5 breaths/minute shows up
    /// there. It does not, under the bands this app uses. HF is 0.15-0.40 Hz,
    /// which is 9-24 breaths/minute. 5.5 breaths/minute is 0.092 Hz, and 0.092
    /// falls inside LF (0.04-0.15). Slow breathing does amplify respiratory
    /// sinus arrhythmia — but with fixed spectral bands
    /// the enlarged peak MOVES OUT of HF and into LF. Users following such a tip
    /// would watch HF drop while doing the thing the tip said would
    /// raise it, and conclude the reading was broken.
    private static func hfPowerSection() -> [ArticleSection] {
        [
                .heading("HF Power — Your Vagal Signature"),
                .text("""
                    High Frequency power (0.15-0.4 Hz), the band most closely tied to parasympathetic activity. These oscillations come from respiratory sinus arrhythmia — your heart speeds up when you inhale and slows \
                    when you exhale. That band corresponds to breathing between about 9 and 24 breaths per minute, which is where normal resting breathing sits.
                    """),
                .keyValue([
                    (label: "What it measures", value: "Parasympathetic (vagal) activity via your breathing-heart rate coupling"),
                    (label: "Higher means", value: "Strong vagal tone — your recovery system is engaged and responsive"),
                    (label: "Lower means", value: "Reduced vagal activity, or simply that you were breathing more slowly than the band covers"),
                    (label: "Key insight", value: "HF depends on your breathing RATE, not just your vagal tone. Breathe slower than ~9 per minute and the signal moves to a different band.")
                ]),
                .tip("""
                    If you used the breathing mandala, expect LF power to rise and HF to FALL — that is the expected result, not a bad reading. The mandala paces you at ~5.5 breaths/minute (0.092 Hz), and that sits \
                    inside the LF band (0.04-0.15 Hz), below HF's 0.15 Hz floor. The breathing is amplifying respiratory sinus arrhythmia exactly as intended; the enlarged peak simply lands in LF. This is also why LF/HF \
                    climbs during a paced-breathing reading, and why that particular rise says nothing about stress.
                    """),
                .divider
        ]
    }

    /// LF/HF Ratio
    ///
    /// The bands here must not read "Parasympathetic dominant",
    /// "Balanced", "Sympathetically shifted". Thirty lines above, `lfPowerSection`
    /// correctly tells the reader that the LF-equals-sympathetic idea was
    /// debunked, citing Billman 2013 — whose paper is titled, in full, "The
    /// LF/HF ratio does not accurately measure cardiac sympatho-vagal balance".
    /// Citing the refutation and then printing the conclusion it refutes is wrong.
    ///
    /// The bands are described by what they are: positions in a ratio's
    /// range. The same four rows
    /// are there, and the ratio is still charted and trended. Only the
    /// autonomic verdicts attached to them are gone.
    ///
    /// Note this does NOT touch `HRVSleepStageClassifier`, which uses LF/HF as
    /// a REM-versus-N2 discriminator. "This ratio separates two sleep stages"
    /// is a different and better-supported claim than "this ratio measures
    /// autonomic balance" (Vanoli 1995, Herzig 2017).
    private static func lfhfRatioSection() -> [ArticleSection] {
        [
                .heading("LF/HF Ratio — A Trend, Not a Verdict"),
                .text("The ratio of Low Frequency to High Frequency power. Its value is in how it moves for YOU across days, not in where a single reading lands. Both bands move with breathing rate as much as with autonomic state, so a single number carries less than it appears to."),
                .keyValue([
                    (label: "< 1.0", value: "HF power exceeds LF. Common at rest, and expected when breathing normally rather than slowly."),
                    (label: "1.0-2.0", value: "The most common resting range."),
                    (label: "2.0-5.0", value: "LF clearly exceeds HF. Seen with stress and caffeine — and also, reliably, with slow or paced breathing."),
                    (label: "> 5.0", value: "Well above the usual resting range. Read it next to your RMSSD, sleep and recent training before drawing a conclusion.")
                ]),
                .warning("""
                    This is the most debated metric in HRV, and the debate is settled enough to say plainly: the ratio does not measure the balance between your sympathetic and parasympathetic systems. Billman (2013) took that interpretation apart \
                    directly, and it fails for the reason given in the LF section above — LF is not a sympathetic signal. Watch the ratio's trend if you find it useful, but rely on RMSSD for recovery decisions.
                    """),
                .divider
        ]
    }

    /// SD1 / SD2
    private static func poincareSection() -> [ArticleSection] {
        [
                .heading("SD1 & SD2 — Your Heart's Fingerprint"),
                .text("From the Poincar\u{00E9} scatter plot — each heartbeat interval plotted against the next one. The resulting cloud of points creates a visual fingerprint of your autonomic state that numbers alone can't convey."),
                .keyValue([
                    (label: "SD1", value: "Width of the cloud. Captures rapid beat-to-beat variation — mathematically equivalent to RMSSD/\u{221A}2. This is your parasympathetic signature."),
                    (label: "SD2", value: "Length of the cloud. Captures slower rhythms and overall variability — the combined output of both ANS branches."),
                    (label: "The shape tells the story", value: "A wide, spread-out comet means more beat-to-beat variation; a tight, narrow cluster means less. Compare it with your own past plots rather than a fixed ideal.")
                ]),
                .text("Look at the Poincar\u{00E9} plot in your reports. Over time you'll develop an intuition for what YOUR recovered and stressed patterns look like — it's often more immediately insightful than any single number."),
                .divider
        ]
    }

    /// DFA α1
    ///
    /// No fixed resting interpretation here either — the same rule as
    /// `dfaExplainedSections`, in shorter form. See that comment
    /// for why; the short version is that the 0.75 anchor is an exercise
    /// finding, and measured deep sleep (N3, PMC4100066) sits around
    /// \u{03B1}1 0.78 with a wide spread, so a "white noise, not real
    /// recovery" line below 0.75 would contradict normal sleep.
    private static func dfaAlpha1Section() -> [ArticleSection] {
        [
                .heading("DFA \u{03B1}1 — Correlation Structure"),
                .text("Detrended Fluctuation Analysis. Where RMSSD measures how much your intervals vary, \u{03B1}1 describes how those variations are patterned — whether successive intervals are correlated with one another or drift independently. It is a different question, not a better answer."),
                .keyValue([
                    (label: "0.75-1.0", value: "The app's resting reference range, and where most resting adult recordings sit."),
                    (label: "0.60-0.75", value: "Below the reference range. Common on its own."),
                    (label: "~0.5", value: "Intervals close to uncorrelated. Uncommon in a resting adult recording — worth a repeat before reading anything into it."),
                    (label: "> 1.0", value: "More correlated than the reference range — seen with stress and mental load, and also with slow regular breathing."),
                    (label: "< 0.5", value: "Outside the range these bands were characterised over. Worth a repeat reading before reading anything into it.")
                ]),
                .tip("\u{03B1}1 has its own article (\"DFA \u{03B1}1 — The Hidden Gem\") covering where the numbers come from and why the resting ranges are a convention rather than a validated scale."),
                .divider
        ]
    }

    /// Stress Index
    private static func stressIndexSection() -> [ArticleSection] {
        [
                .heading("Stress Index — How Uniform Your Rhythm Is"),
                .text("""
                    From Russian space medicine — originally developed to monitor cosmonauts. Measures how rigidly your heart is beating by analyzing the shape of your RR interval distribution. When stress rises, your heart rhythm narrows and becomes \
                    uniform; the Stress Index captures that compression.
                    """),
                .keyValue([
                    (label: "< 50", value: "The low end of the range. Typical of good sleep or deep relaxation."),
                    (label: "50-100", value: "The usual resting range."),
                    (label: "100-150", value: "Somewhat above the usual resting range. Caffeine, light activity or mild stress can all do this."),
                    (label: "150-300", value: "Well above the usual resting range. Read it next to your RMSSD, sleep and recent training."),
                    (label: "> 300", value: "Far above the usual resting range. If your RMSSD is also low, an easier day is a reasonable choice; repeat the reading if it surprises you.")
                ]),
                .note("Read Stress Index alongside RMSSD: RMSSD tracks how much your intervals vary from beat to beat, while Stress Index tracks how narrow their overall spread is. When both move the unusual way for 2+ days, consider an easier day."),
                .divider
        ]
    }

    /// The Readiness entry. It must describe `StressAnalyzer.computeReadinessScore`
    /// as it is. It is a nearness score, not a "better or worse" one: a night
    /// 31% above the usual RMSSD earns no RMSSD points, and α1 and the PNS/SNS
    /// balance can then take it to 3.5 under a 95 Recovery Score.
    private static let ansReadinessExplanation = """
        Available from day one. Starts at a neutral 5. RMSSD within 15% of your usual level adds 2, within 30% adds 1, and more than 40% below or 50% above it takes 2 off \
        (population ranges stand in until you have a baseline). DFA \u{03B1}1 between 0.75 and 1.0 adds 2, between 0.60 and 1.25 adds 0.5, and anything else takes 1 off. \
        The PNS/SNS balance moves it by up to 1.5 either way, and recent hard training lifts it, since low HRV is expected then. It rewards being near your norm rather than \
        above it, so a night well above your usual HRV can still score low when \u{03B1}1 and the PNS/SNS balance pull it down.
        """

    /// Readiness & Recovery Score
    private static func readinessSection() -> [ArticleSection] {
        [
                .heading("Readiness (1-10) vs Recovery Score (0-100)"),
                .text("Two composite scores that serve different purposes at different stages of your baseline development."),
                .keyValue([
                    (label: "Readiness (1-10)", value: ansReadinessExplanation),
                    (label: "Recovery Score (0-100)", value: """
                        Compares you with your own baseline from the third night. Full z-score normalization using up to 60 days of historical data, \
                        integrating sleep quality and vitals (respiratory rate, wrist temperature, resting heart rate). The complete picture.
                        """)
                ]),
                .text("Once your Recovery Score activates, it becomes the primary indicator on your dashboard. Readiness remains in your detailed report as a quick sanity check."),
                .tip("""
                    When Readiness and Recovery Score disagree, that's information: Readiness only sees HRV; Recovery Score integrates sleep and vitals. High Readiness + low Recovery Score = your HRV looks fine today but poor sleep or elevated breathing \
                    rate is showing up. Low Readiness + decent Recovery Score = today's HRV dipped but your sleep and vitals fundamentals look solid.
                    """)
        ]
    }

    private static func metricsGuide(forAge age: Int?) -> HelpArticle {
        var introSections: [ArticleSection] = [
            .text("Every metric in the app tells you something specific about YOUR body. This guide explains what each one means for you in practice — not just definitions, but what your numbers should look like, what moves them, and what to actually do about it.")
        ]

        introSections += rmssdIntroSections(forAge: age)
        let sharedSections = metricsGuideSharedSections()

        return HelpArticle(
            id: "metrics-guide",
            title: "Metrics Reference",
            icon: "list.bullet.rectangle",
            summary: "Complete guide to every HRV metric — ranges, interpretation, and what to do",
            sections: introSections + sharedSections
        )
    }
}
