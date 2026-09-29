# Emuqu User Manual

## Overview

Emuqu measures your physiology and scores recovery from what it measured. It does three
things:

- **Overnight recovery** — a **Polar H10** chest strap (ECG-based) or **Polar Verity Sense**
  optical sensor (PPG-based) records your heart's beat-to-beat intervals through the night.
  The app finds a physiologically organized window, scores it against your own baseline, and
  freezes the result so it doesn't drift later.
- **Workouts** — walk, run, trail run, hike, bike, indoor bike, treadmill and row, with GPS,
  Apple Watch or strap heart rate, Stryd / FTMS / Concept2 power, splits, routes, offline
  trail recovery and PDF reports.
- **Flo** — an assistant that answers from your own measurements. It runs on-device by
  default, or with your own API key for a cloud model.

It integrates with Apple HealthKit for sleep, training and vitals data.

Emuqu is not a training-plan generator, not an injury predictor, and not a medical device.

---

## App Navigation

The app uses a 5-tab layout. **History**, **Trends**, **Settings**, and the Help Center live one level deep under **More**.

| Tab | Icon | Purpose |
|-----|------|---------|
| **Dashboard** | Heart | Recovery status and daily readiness |
| **Record** | Waveform | Collect HRV data from your Polar device |
| **Fitness** | Figure.run | Live workout recording (run / ride / walk / hike / row) with GPS, barometric elevation, live DFA α1, and post-workout PDF report |
| **Flo** | Sparkles | In-app chat with Apple Intelligence (free) or your own API key for Claude / ChatGPT / Gemini / Grok / DeepSeek, with adaptive Quick / Auto / Deep / Manual routing |
| **More** | Ellipsis | Hub for History (searchable session archive), Trends (charts + stats grid + morning-feeling heatmap), Settings, and the Help Center |

Two tabs hide on demand:

- **Hide Fitness tab** (Settings → More → Modes) — recovery-only / HRV-only users get a 4-tab bar with no workout surfaces. The deep-link routes still resolve, just without a tab item.
- **Disable Flo** (Settings → Flo → master toggle) — the chat tab disappears entirely; the chat ViewModel, provider registry, and Flo inbox all skip work when the tab isn't accessible.

When both are hidden, the bar collapses to **Dashboard / Record / More** (3 tabs).

> **Apple Watch companion app — shipping (re-embedded 2026-07-03).** The `EmuquWatch Watch App` target is embedded in the iOS build again (the "Embed Watch Content" phase was restored after a watchOS build-config fix), so a build installed to your phone now installs the Watch app on a paired watch. Its design is a **phone-mirror + wrist controls** companion: the iPhone owns the Polar strap and the canonical workout; the Watch shows the live workout and offers start/stop/pause on the wrist. `WatchConnectivity` activates normally (`enableWatchConnectivity` defaults on). Mirror-mode wiring polish (reachability, strap-state display) is still being validated on-device, so treat specific wrist behaviors below as the intended design.

### Naming

The chat AI is called **Flo**. The audible mid-workout trigger voice is called **Coach** (so you can audibly distinguish "Flo here" from "Coach here" through AirPods). The auto-generated email goes out as a **Flo Report**. All three are the same model + history surface; what differs is the rendering channel and the on-bubble badge.

---

## Dashboard Tab

The main dashboard displays your recovery status at a glance.

### Recovery Score Card
- Large circular gauge showing overall recovery (0-100)
- Uses ln(RMSSD) z-score normalization against your personal 60-day baseline
- **Architecture (May 2026):** the score is computed from **HRV (60%) + Sleep (25%) + Vitals (15%)**. Training load is shown on the parallel Load & Trajectory page but does not feed the recovery score — heavy training already manifests downstream as suppressed HRV and elevated resting heart rate; counting it again would double-penalise the same physiological event. Full rationale and citations in **Settings → About → "How Emuqu scores recovery."**
- Automatically selects the best available scoring tier:
  - **HRV Only** (Tier 1): cold start, before sleep / vitals data is available
  - **HRV + Sleep** (Tier 2): sleep present, no overnight vitals captured
  - **HRV + Sleep + Vitals** (Tier 3): full-signal day — overnight resting heart rate, respiratory rate, and wrist temperature contribute the 15% Vitals factor
- **Vitals factor (15% of the score):** averages whichever sub-inputs are available — RHR (z-score against personal baseline), respiratory rate (deviation from 7-day baseline), wrist temperature (deviation banded 0.3 / 0.5 / 1.0°C). Missing inputs are dropped, not penalised. SpO2 below 95% applies a separate −10 penalty after the composite (often reflects altitude or sleep apnea rather than recovery state).
- **Confidence pips next to "FLOW RECOVERY™":**
  - ●○○ "Building baseline" — days 0-13, HRV-only scoring with absolute thresholds
  - ●●○ "Provisional baseline" — days 14-27, z-scoring active but baseline still maturing
  - ●●● "Full algorithm" — day 28+, 60-day rolling baseline locked
  - Tap the pips for an explanation
- **Daily feedback chip (below the score):** "Did this match how you felt today?" Thumbs-up / thumbs-down. One tap per day. Stored locally on device, never exfiltrated. The app uses the aggregate signal to evaluate calibration over time.
- **Training Readiness Card** (separate from the score): Shows your training readiness based on your fitness-fatigue balance — how much load your body can absorb relative to what it's adapted to handle. A fit athlete (high CTL) absorbs a given workout easily, while an untrained athlete is heavily impacted by the same effort. The base readiness is computed from training load (CTL/ATL/strain) and then **modulated by your recovery score** as an asymmetric sanity check: when the load model overestimates capacity above what your recovery score supports, recovery wins; when the model already detects overload, the training signal is taken as-is. Zones: Rest / Fatigued / Moderate / Ready. Copy describes recent load in plain "above your usual range" terms rather than reciting ACWR by name.
- **Comeback mode:** When you toggle Settings → Training → "I'm coming back from illness or injury," the score weights shift to **HRV 80% / Sleep 20% / Vitals 0%** for 21 days. RR, RHR, and wrist temperature can stay elevated for weeks after a viral infection; Comeback mode prevents those slow-recovering signals from pulling your score down while HRV catches up. Auto-deactivates on day 21.
- Color coded:
  - **Green** (80+): Well recovered
  - **Gold** (60-79): Moderately recovered
  - **Terracotta** (40-59): Reduced recovery
  - **Dusty Rose** (<40): Poor recovery

### HRV Card
- Shows your latest RMSSD value in milliseconds
- Labels based on value:
  - **Excellent**: 60+ ms
  - **Good**: 45-59 ms
  - **Fair**: 30-44 ms
  - **Low**: <30 ms
- Tap to open HRV Detail View

### Sleep Card
- Total sleep hours from HealthKit or HRV-based classification
- Sleep efficiency percentage
- Sleep stages (deep, REM, core, awake) from Apple Watch or chest strap HRV data
- Automatically extends to capture additional sleep after your strap is removed (Apple Watch required)
- Tap to open Sleep Detail View

### Training Load Card (Load & Trajectory — does NOT feed the recovery score)
*Only appears if Training Load Integration is enabled in Settings and you're not on a training break.*

The Training Load card on the dashboard shows your training trajectory for planning context. It does not affect the Recovery Score number — that's intentional (see "Architecture" above).

- **ACR Gauge**: Acute:Chronic Ratio showing where recent training sits relative to your longer-term base. Labels are descriptive — "Below your usual" / "In range" / "Above your usual" / "Sharp increase" — not risk verdicts. Per Impellizzeri 2020/2021 the ratio's signal value for predicting injury is weaker than the original Gabbett framing claimed; Emuqu shows it as descriptive load-range context, never as an injury predictor.
- **ATL**: Acute Training Load (7-day fatigue)
- **CTL**: Chronic Training Load (42-day fitness)
- **TSB**: Training Stress Balance (form indicator)
- **Foster Monotony banner**: When your training has been unusually similar day-to-day (monotony >2.0) AND the weekly load is meaningfully heavy, a banner appears at the top of the Training Detail page suggesting you mix intensities. Observational only — not a score component.
- Tap to open the full Training Detail view (CTL/ATL/TSB charts, recent workouts, zone explanation)

### Insights Section
Auto-generated insights based on your current metrics and trends.

### Multi-Segment Recovery
When you pause and resume overnight recordings (split sleep), or record two separate sessions on the same night, the app combines both sessions' HRV data for analysis. Window selection runs on the combined data so the best recovery window is found across the entire night. The readiness score reflects the combined analysis, and sleep is displayed as both sessions. The morning results header indicates when a session is part of a multi-segment recording.

### Watch-Based Sleep Extension
If you go back to sleep after removing your chest strap, the app automatically detects the additional sleep using your Apple Watch's passive heart rate data. This happens transparently whenever you open the dashboard — there is no button to tap or setting to enable.

**How it works:**
- The app checks for additional sleep beyond the end of your recorded session
- It first looks for native Apple Watch sleep data (Sleep Focus). If found, the full night is re-fetched from HealthKit.
- If no native sleep data exists (Sleep Focus was off), the app estimates the extra sleep from the overnight drop in your Watch's background heart rate — a heuristic estimate (adaptive HR threshold, smoothed, with artifact guards), not staged or clinically validated sleep
- Detected sleep is merged into your existing sleep total. The extended period appears as an "unspecified" stage in your hypnogram.
- A workout between the session end and detected sleep prevents false positives

**Requirements:** An Apple Watch that records passive heart rate data (all models do this by default).

### Morning Feeling Badge
- **Pre-score prompt**: After accepting an overnight session, the app asks how you're feeling on a 1–5 scale (Terrible → Great) **before revealing your recovery score**, so your answer isn't anchored to the number.
- **Body & Mind tags**: When you rate yourself a 1 or 2, an optional tag picker appears so you can mark *why* — illness, stress, hangover, allergies, poor sleep, etc. Each tag steers the morning narrative toward specific advice.
- **Editable badge**: The feeling badge appears on the Dashboard and Morning Results. Tap to change it any time after recording.
- **Divergence detection**: If your self-rating disagrees with your HRV by more than one category (e.g., HRV says "well recovered" but you feel "poor"), the morning narrative explicitly flags it and routes coaching accordingly.

### Dashboard Toolbar (top-right)

Three icons live in the top-right toolbar:

- **🔔 Notifications** — opens the Notifications settings page.
- **📤 Send Report** (paperplane icon) — menu offering:
  - **Recovery Report** — today's overnight session as a PDF. Disabled if no overnight session exists.
  - **Daily Report** — today's combined daily summary as a PDF (recovery + workout pairing for the day). Disabled if no daily pair exists.
  - **Workout Report** — most recent workout as a PDF. Disabled if no workout exists.
  - **Browse all reports** — opens the full report list view.
  Choosing any of the first three renders the PDF off the main actor (so the AI chat keeps working during render) and opens the system mail composer with the PDF attached for review before sending. A spinner replaces the paperplane while the render is in flight.
- **✨ Ask Flo** (sparkles icon) — one-tap shortcuts to common Flo questions:
  - *Why is my score this?*
  - *Should I train today?*
  - *What changed from yesterday?*
  - *Open AI Assistant…*

  Tapping any of the questions auto-sends it and switches to the Flo tab. The "Open" entry just navigates without sending.

### Action Button
- **"View Full Report"**: Opens the detailed report for today's session (from the morning-results flow)
- **"Take a Reading"**: Appears when no reading exists yet today; navigates to Record tab
- **"Export Report"**: Generate and share a PDF report for the current session

---

## Detail Views

### HRV Detail View
- **Current HRV Hero Card**: Today's RMSSD with baseline comparison
- **Your Averages Card**: Average HRV, HR, and Readiness over last 30 sessions
- **View Full Report Button**: Opens today's detailed report
- **Nervous System Card**: HRV Score (1-10) and ANS balance (sympathetic vs parasympathetic)
- **30-Day Trend Chart**: Line chart with baseline reference line
- **Statistics Card**: 30-day average, range, coefficient of variation, baseline
- **Recent Readings**: Last 7 readings with tap to view report
- **Education Card**: Tips about HRV interpretation

### Sleep Detail View
- **Sleep Score Card**: Composite 0-100 score using six weighted factors. Base weights:
  - Duration (25%) — hours slept vs your typical sleep target
  - Efficiency (20%) — percentage of in-bed time actually asleep
  - Deep sleep (20%) — vs 20% target
  - REM sleep (15%) — vs 25% target
  - Continuity / fragmentation (10%)
  - Timing / regularity (10%)
  - When full stage data is available, an enhanced science-based score additionally incorporates sleep fragmentation, cycle count, architecture, and age-adjusted norms
- **Sleep Duration Card**: Hours slept vs your typical sleep goal
- **Sleep Window Card**: Wall-clock start and end of the sleep window, with the span between them shown in the middle in hours and minutes. Time in bed and awake time are reported separately in the header cards — the Sleep Window card is specifically the bookend times and how long that interval was. For split nights the card shows segment count.
- **Adjust Sleep Button**: Opens a dedicated adjustment screen (see below)
- **Sleep Stages Card**: Visual bar showing deep/light/REM/awake breakdown with percentages. Stages come from Apple Watch via HealthKit when available, or from HRV-based classification of chest strap RR data when no Watch sleep exists.
- **Key Metrics Grid**: Efficiency, awake time, sleep time, time in bed, sleep latency
- **Recovery Vitals**: 2x2 grid showing overnight vitals from Apple Watch:
  - **Respiratory Rate**: Breaths per minute with 7-day baseline comparison
  - **SpO2**: Blood oxygen percentage
  - **Temperature**: Actual wrist temperature with deviation-from-baseline note
  - **Resting HR**: Resting heart rate
  - Tap to open Vitals Detail View
- **Quality Check Card**: Checkmarks comparing each metric to targets
- **Sleep Insights Card**: Auto-generated tips based on your data

#### Adjust Sleep Screen

Tap the **"Adjust Sleep"** button on the Sleep Detail View to open the timeline editor. The timeline is draggable so you can land precisely on the boundary you want.

**Session Tiles:**
- Each tile shows the session time range, duration, and a proportional stage color bar (Deep/Light/REM/Awake)
- Normal nights show 1 tile; split nights show 2 or more tiles with gap indicators between them
- Tap a tile to expand it into the full timeline editor

**Timeline Editor (expanded):**
- A horizontal timeline shows the full sleep window with stage segments color-coded
- **Drag the left handle** to set when you actually fell asleep
- **Drag the right handle** to set when you actually woke up
- The timeline expands past the original recording window, so you can pull boundaries outside the recorded range if the actual sleep extended beyond it
- **Stage breakdown pills**: Deep, Light, REM, and Awake durations recompute live as you drag
- **Duration delta**: Shows how your adjustment differs from the original (e.g., "+12m from original" or "-8m from original")
- **Exclude session**: For multi-session nights, toggle to exclude a session from totals

**Totals Card** (multi-session only):
- Shows adjusted total sleep time across all included sessions
- Displays delta from original total
- Notes how many sessions are excluded

Tap **"Done"** to accept your adjustments or **"Cancel"** to discard them. **Saving an adjustment automatically rescores the session** — your recovery score updates to reflect the new sleep boundaries.

> Opening the app does not rewrite historical sessions' sleep data. Only sessions you explicitly edit here are mutated.

### Training Detail View
- **ACR Card**: Large ACR value with zone label and gauge bar
- **Training Metrics Card**: ATL, CTL, TSB display with coaching-style messages aligned to actual scores
- **ACR Training Zones**:
  - **Under** (<0.8): Undertraining - fitness declining
  - **Maintenance** (0.8-1.0): Maintaining fitness
  - **Optimal** (1.0-1.3): Building fitness
  - **Overreaching** (1.3-1.5): Elevated load — monitor recovery (advisory, not a hard limit)
  - **Injury Risk** (>1.5): Significant load spike — reduce training immediately
- **Monotony & Strain**: The app also tracks Foster's Monotony (how repetitive your training pattern is) and Strain (total load amplified by monotony). High monotony with high strain surfaces a banner suggesting you mix intensities — it's observational context for planning, not a score component.
- **Recent Workouts Card**: List of recent workouts with type, date, duration, TRIMP

### Vitals Detail View
- **Status Banner**: Overall status (Normal/Elevated/Warning)
- **Vitals Score Card**: Score circle with quick stats
- **Expandable Cards** for each vital:
  - Resting Heart Rate
  - Respiratory Rate (with 7-day baseline comparison)
  - Blood Oxygen (SpO2)
  - Wrist Temperature (actual temperature with 7-day baseline deviation note)
- **Explanation Card**: Tips about recovery vitals

---

## First Launch (Onboarding)

On a brand-new install the first thing you see is the **Health Disclaimer**. This is a mandatory, scroll-to-agree gate — the app will not collect or display any data until you accept it. Acceptance is stored **device-local only** (never synced to iCloud), so if you restore onto a new phone you'll be asked to accept it again. You can re-read the accepted disclaimer any time from Settings → About → Health Disclaimer.

An **8-page** onboarding wizard then walks you through initial setup:

1. **Welcome** — Brand splash + "Get started" CTA
2. **What Emuqu does** — Three-card carousel explaining the app's value
3. **Profile** — Birthday, fitness level, and optional lab-measured VO2max
4. **Sensor** — Scan and pair your Polar device (H10 chest strap or Verity Sense optical sensor — same UI handles both; the Record tab uses whichever you paired). "I'll do this later" skip is supported.
5. **Apple Health** — A dedicated permission-priming page. Tapping **Connect** fires the system permission sheet inline; the page handles partial-grant and full-deny states with explicit status cards.
6. **Backup** — Enable iCloud sync (on by default)
7. **Disclaimer** — Mandatory scroll-to-agree health disclaimer with an "I Agree" gate. Acceptance is device-local — restoring to a new phone re-prompts.
8. **You're In** — 14-day calibration messaging + "Take a reading" / "Skip — show me around" CTAs.

Pages 1, 2, 3, 4, 5, and 6 are skippable. The disclaimer page (7) is gated. If you kill the app before tapping the final CTA on page 8, onboarding reappears on next launch. Existing users upgrading from an older version skip onboarding automatically.

### What onboarding does NOT capture (set these later in Settings)

The wizard collects just the minimum needed to render the first dashboard. For accurate zones, training load, and recovery scores you'll want to visit **Settings → Profile & Health** at least once to set:

- **Max heart rate** — falls back to 220 − age if not set. Override with a known lab or field-test value for accurate zones and TRIMP.
- **Resting heart rate** — auto-estimated from HealthKit over time, but a manual value from a lab / watch nightly-low is more accurate and feeds the HR-reserve denominator.
- **Lactate threshold HR (LTHR)** — falls back to 0.88 × max HR. Set this to a lab value or your α1 AeT estimate (the Fitness tab surfaces one after any aerobic workout) for accurate hrTSS.
- **Body weight** — defaults to 75 kg for MET / calorie estimates.
- **Units** — distance, pace/speed, elevation, temperature. Defaults to your device locale; override here if you want (for example) imperial pace with metric distance.

The Fitness tab and overnight-session scoring all work without these, but the numbers get more accurate the more of them you fill in.

---

## Record Tab

Collect HRV data from your Polar device (H10 or Verity Sense).

### Session Type Selection

The Record tab uses a session-first flow — you pick your session type before connecting:

- **Extended** — Overnight or multi-hour sleep recording
- **Quick Reading** — 2, 3, or 5 minute daytime spot check

The default is Extended. After selecting a session type, the connection and recording controls appear.

### Connection Section

**When Disconnected:**
- **Known devices list** — Shows previously connected Polar devices with device icon, name, and ID. Tap any device to reconnect.
  - *Swipe left* on a device to reveal a delete button for removing it from the list
  - *Long press* a device for a context menu with "Remove Device" option
- **"Scan for Devices"** button — Discover new Polar devices nearby
- Instruction: "Put on your Polar device and ensure good sensor contact"

**When Scanning:**
- Shows progress spinner with "Scanning for Polar devices..."
- Lists discovered devices with signal strength (dBm)
- Tap a device name to connect
- **"Stop Scanning"** button

**When Connecting:**
- Shows progress spinner with "Connecting..."

**When Connected:**
- **Device Info Panel** (always visible):
  - Device type and name
  - Battery level with color coding (green/orange/red)
  - Estimated battery life for Verity Sense (~30hr from full)
  - Firmware version
  - H10 memory status (stored session or empty)
  - Last connected time
- Live heart rate display with pulsing animation
- **"Disconnect"** button
- Recording status indicator if active

**Battery Warnings:**
- **Critical (<10%)**: Recording is disabled with a red warning
- **Low (10-20%)**: Orange advisory shown but recording still allowed

### Tag Selection
- Horizontal scrollable row of system tags: Morning, Post-Exercise, Recovery, Evening, Pre-Sleep, etc.
- Tap tags to select/deselect
- **"More"** button opens full tag picker sheet with all system and custom tags

### Extended Recording (Overnight / Multi-Hour)

For overnight HRV monitoring during sleep:

**Starting a Recording:**
1. Connect your Polar device before bed
2. Select any tags you want (Morning tag is auto-added if the recording ends between 4–10 AM)
3. Tap **"Start Extended Recording"**
4. The screen locks normally — silent audio keeps the app running in background

**While Recording:**
- Shows moon icon with "Recording..."
- Displays elapsed time (HH:MM:SS format)
- Shows live heartbeat count (updates in real time as beats are received from the sensor)
- Shows current BPM
- Message: "Keep the app open - silent audio keeps it running in background"
- Instruction: "Tap 'Get Reading' when you're ready to analyze"

**Pausing & Resuming (Split Sleep):**

If you wake up in the middle of the night and want to go back to sleep later:

1. Tap **"Pause"** — the recording stops, a full analysis runs, and the segment is saved immediately (your data is never at risk)
2. A score preview card appears showing your RMSSD, readiness, and HR with "Your data is saved"
3. You can leave the app, close the screen, or do whatever you need
4. When you're ready to resume, open the Record tab — if the paused session is within your merge window (see Settings → Profile &amp; Health → Sleep → Combine Segments (Split Sleep)), a **"Continue Recovery"** card appears with your score and a resume link
5. Tap **"Resume"** — a new linked segment starts with hybrid recording, chained to the original session
6. The best score across all linked segments is used for your recovery period

**Auto-finalize:** If your device disconnects or battery drops to ≤5% while paused, the session automatically finalizes. If the app is killed mid-pause, pause state is restored from disk on next launch.

**Getting Results:**
- When you're ready, tap **"Get Reading"**
- The app analyzes your data and finds the best 5-minute analysis window
- The full Recovery Report opens automatically once analysis completes — no extra tap required
- If using an H10, device data uploads in the background and silently refines the score if it's better
- Verity Sense automatically disconnects after the session to prevent battery drain

**Analysis Window:**
- The app automatically selects the optimal 5-minute window for HRV analysis
- Uses the window selection method set in Settings (default: Auto Select)

### Quick Reading Section (Spot Check)

For daytime 2-5 minute readings:

**Starting:**
- Choose duration: **2 min** (Basic) | **3 min** (Standard) | **5 min** (Full)
- Sit still and relax during recording

**During Recording:**
- Countdown timer showing remaining time
- Progress ring with live HR in center
- Breathing mandala for coherence (breathe with it for better results)
- **Voice guide** — Toggle on/off for spoken "Breathe in" / "Breathe out" cues
- Stats row: Beats collected, elapsed time, average RR interval
- **"Stop Early"** button available

**After Recording:**
- "Reading Complete" card shows RMSSD, HR, and Readiness/SDNN
- **"View Full Report"** button opens detailed results
- **"Done"** button saves and resets
- Verity Sense automatically disconnects after the session

### Data Quality Verification
After recording completes, shows:
- Quality badge (Good/Issues Found)
- Analysis window duration
- Quality score percentage
- Artifact percentage (<10% is good)
- Clean beats count (200+ is good)
- Any errors or warnings

### Results Preview

**For Extended Recordings:**
- The full Recovery Report opens automatically once analysis completes
- Shows RMSSD, Readiness score, HR, sleep data (if available), training load, vitals, and overnight charts
- **"Done"** button saves the session. **"Discard"** button rejects it.
- If H10 device data improves the score, an upward arrow indicator appears on the readiness card

**For Quick Readings:**
- "Reading Complete" card
- Shows RMSSD, HR, Readiness/SDNN
- **"View Full Report"** button
- **"Done"** button

### Data Recovery

**If your device has stored data from a previous session:**
- "Data Found on [Device Name]" alert appears
- **"Recover Data"**: Downloads and analyzes the stored session
- **"Discard & Start Fresh"**: Clears device memory to start new recording

**If fetch fails:**
- "Data Fetch Failed" alert
- Data is still safe on the device
- **"Retry Fetch Data"** button
- **"Dismiss"** button

**If the app crashed mid-recording:**
- The Dashboard shows a banner: "Resume your walk?" / "Interrupted
  recording detected" with the elapsed time, distance, and how long
  ago it started.
- **Resume** — picks up from where you left off (within the resumable
  age window).
- **Save as is** — finalizes whatever was captured.
- **× (Dismiss)** — small icon in the corner. Tapping it shows a
  confirmation: "This clears the prompt AND discards the backed-up
  beats. Tap 'Save as is' instead if you want to keep what was
  captured." Cancel keeps the banner up. Use Dismiss only when you
  really don't care about the data; otherwise pick Save as is.

---

## Flo Tab (the AI Assistant)

The ✨ **Flo** tab opens an in-app chat with one of six AI providers. Every message you send is automatically given your live recovery context — today's session, yesterday's session, last 14 days, baselines, 7-day and 30-day trends, training load, and your morning feeling — so Flo answers from real numbers, not guesses.

> **Naming.** Flo is the chat assistant in this tab. **Coach** is the audible mid-workout observational voice (different subsystem; you'll hear "Coach here" instead of "Flo here" the first time it speaks during a workout). **Flo Report** is the auto-generated daily/weekly email. All three are the same model + history surface; what differs is the rendering channel.

### Adaptive Routing — Quick / Auto / Deep / Manual

Flo picks which model handles each turn according to a **routing mode** you set in **Settings → Flo → Routing**:

- **Quick** — every turn pinned to **Apple Intelligence** on-device. Fastest, free, private. Apple is now wired to the full tool catalog, so it can answer per-workout, route, and breadcrumb queries directly. May still refuse complex multi-week analyses (Apple's safety filter occasionally blocks health-adjacent prompts; switch modes when that happens).
- **Auto** (recommended) — **session-sticky** with **capability-axis classification**. An on-device classifier asks four binary questions of every message:
  - **Does it need a tool?** ("email this", "save this route", per-workout deep-dive)
  - **Does it need the web?** (weather, news, product recommendations)
  - **Does it need historical depth?** (trend over 8 weeks, since I started)
  - **Does it need speculation?** ("predict next week", "what if I rest")

  Zero capability flags → Apple (Quick). One flag → cheap cloud (Haiku 4.5 / Flash-Lite class — "Auto"). Two or more flags → strongest cloud (Sonnet / Opus / GPT-5 / Gemini Pro — "Deep"). Each axis is gated by **both** a keyword marker AND on-device embedding similarity ≥ 0.55, so plain lookups like "what's my recovery score" don't get bumped to Deep just because the word "recovery" embeds near history-depth prototypes.

  Tier persists once chosen so the conversation doesn't drift mid-thread. Within the first **3 settling turns** the proposed tier is taken as-is; after that the session sticks to the higher tier until either a topic shift (cosine > 0.4 vs the running summary embedding) re-classifies, or the message scores zero capability flags (clean Quick lookups can downgrade out of a stuck Deep). On older OS versions where contextual embeddings aren't available, the classifier falls back to keyword markers — same conservative logic, just less precise on paraphrases.
  - **Adversarial-spend cap.** A daily Tier-3 ceiling of 50 turns prevents a runaway loop from emptying your wallet — once hit, Auto downgrades any further Deep turns to the cheap-cloud tier for the rest of the day.
- **Deep** — every turn goes to your strongest configured cloud model. Slowest (1–3 s) and costliest. Same daily cap.
- **Manual** — every turn goes to whatever you picked in the model picker (escape hatch).

If you have **no** paid provider configured, Auto and Deep collapse to Apple Intelligence — same as Quick. The Settings footer says so explicitly. Add an API key for any cloud provider to unlock distinct tiers.

**Voice bypasses the router.** When you start a continuous voice conversation (mic-toggle at the top-left of the chat), every turn skips the classifier and goes to your **primary cloud provider** (the first non-Apple provider you have a key for). If Apple is your only available provider, voice falls through to Apple. This mirrors how production voice AIs (ChatGPT Advanced Voice, Gemini Live, Pi.ai, Granola) handle voice sessions — one model for the duration so the conversation doesn't drift between models mid-sentence.

**Model-name earcon.** When voice mode begins answering you'll hear "Coach here, Sonnet." / "Coach here, Apple." / "Coach here, Haiku." — the second word is the active model. So you always know who's actually talking.

**Deterministic shortcuts.** ~30–50% of voice queries are routine factual lookups ("what's my recovery score", "how did I sleep last night", "what's my RHR"). Flo answers those from a hand-curated 14-pattern catalog **without** an LLM call — zero tokens, zero cost, ~50 ms. Anything ambiguous, anything needing a tool, anything in the speculation/medical/web band falls through to the LLM. The catalog covers: recovery score / RHR / RMSSD today, last night's sleep duration / stages / latency / efficiency, last workout summary, "have I trained recently", body weight, max HR, LTHR, total session count.

**Tier-indicator dot.** Each assistant chat bubble shows a small colored dot (6 px, just below the model badge): **sage green** = Apple/Quick (on-device), **blue** = Auto cloud (cheap-cloud), **purple** = Deep (strongest cloud). Manual-mode and voice-bypass turns show no dot.

**AFM prewarm.** When routing might land on Apple (Quick / Auto / Manual-with-Apple-selected), the chat ViewModel fires `LanguageModelSession.prewarm()` at `.utility` priority during init so the KV-cache is resident before your first message. First-answer latency drops from ~1.5 s to ~300 ms on A17 / M-series chips.

**Cache-health card.** Settings → Troubleshooting → **AI cache health** shows the prompt-cache hit ratio for every cloud provider you've used (cumulative + last-10-turn), so you can see whether your message structure is helping the cache. All on-device — never sent off device.

### First Use

A one-time disclaimer explains:
- **Apple Intelligence** runs entirely on this iPhone — your data never leaves the device.
- **Connected models** (Claude, ChatGPT, Gemini, Grok, DeepSeek) require your own API key and send your data to that vendor when used. Their privacy policy applies. Emuqu does not log, filter, or moderate what they do with the data or what they say back.
- AI responses are informational coaching, not medical advice.

Tap **I understand — continue** once. You won't see this again unless you wipe app data.

### Choosing a Provider

The model picker at the top of the chat shows the active provider + model. Tap it to switch. Available providers:

| Provider | Cost | Where it runs | Required |
|----------|------|---------------|----------|
| **Apple Intelligence** | Free | On-device (iOS 26+) | Apple-Intelligence-capable device |
| **Claude** (Haiku 4.5 / Sonnet 4.6 / Opus 4.7) | ~$0.005–$0.20/msg | Anthropic servers | API key |
| **ChatGPT** (GPT-5.4 nano / mini / full / pro) | ~$0.001–$0.20/msg | OpenAI servers | API key |
| **Gemini** (3.1 Flash-Lite / 3 Flash / 3.1 Pro) | ~$0.001–$0.10/msg | Google servers | API key |
| **Grok** (4.1 Fast instant / reasoning / Grok 4) | ~$0.001–$0.20/msg | xAI servers | API key |
| **DeepSeek** (Chat / Reasoner V3.2) | ~$0.001/msg | DeepSeek servers | API key |

Add API keys in **Settings → Flo**. Keys are stored in the iOS Keychain on this device only and are never synced to iCloud.

### The Chat Screen

- **Top bar**: model picker chip + Stop button (during streaming) + ⋯ menu (Export chat, Refresh data context, Clear conversation).
- **Voice toggle** (top-left): mic icon that starts continuous voice conversation. Different from the dictation mic next to the text field — see *Voice conversation mode* below.
- **Pre-fab questions**: 10 suggestion chips above the input. Tap to send instantly.
- **Input row** (paid models only): text field, dictation mic button, send button.
  - Apple Intelligence path: the text input is replaced with a caption — Apple is best for the structured pre-fab questions due to its content guardrails.
- **Typing indicator**: dots with the provider's avatar appear while waiting for the first token.
- **Streaming response**: tokens appear as they arrive. Markdown (`**bold**`, lists, `code`, links) renders properly.
- **Auto scroll**: the chat lands at the bottom when you open the tab and on every new message.

### How the assistant fetches your data (tool use)

Every provider — Apple Intelligence included —
uses **tool use**. Instead of receiving a big dump of your archive
with every message, the system prompt lists every available data
lookup as a callable **tool**, and the model calls the ones it needs.
Your sessions, sleep, training load, and profile are fetched on
demand, locally on your iPhone, and handed back to the model as
structured JSON. The model then composes the answer.

Why it matters:

- **Faster.** The prompt is small and byte-identical every turn, so each
  provider's prompt cache hits from turn 2 onwards. DeepSeek in
  particular no longer slows to a crawl after five turns.
- **More correct on specific questions.** The model asks for exactly
  the fact it needs ("the session on April 21") rather than skimming a
  flat text dump and approximating.
- **Bounded cost.** Your full archive is not uploaded on every send.
  Only the specific fields the model looks at cross the wire (and on
  Apple Intelligence, nothing crosses the wire — everything stays on
  the phone).

Hard cap: 8 tool calls per question. If the model keeps retrying a bad
argument it'll hit the cap, receive synthetic "missing" results, and
compose a brief failure response.

Apple Intelligence's 4K context window is tight, so before each send
the on-device transcript is **trimmed** — the oldest user/assistant
turn-pairs get dropped (verbatim, never summarised) once the
conversation reaches 70% of the window. The most recent user turn is
always preserved. If a long historical analysis needs the full
transcript, switch to a cloud model.

The on-device session is cached across messages so follow-up
questions feel snappier — only the first message in a sitting pays the
warmup cost. The cache rotates after 20 turns to keep the KV-cache
healthy.

### What the AI can do beyond reading your data

A small set of `[ACTION]` tools let the AI act on your data, not just
read it. The AI will only invoke these on explicit, unambiguous
instruction — never inferred — and always reads the result back to
you for confirmation:

- **Saved-route management** — "rename Daily 1 to Morning Loop", "save
  yesterday's run to my library as Lakefront Loop". List / read is
  always allowed; the rename and save mutations are the actions.
- **Navigation** — "lead me back to where I started" / "route home" /
  "where's the nearest hospital" / "navigate me to Sequoyah Park
  trailhead". Engages a walking route via Apple Maps. Once engaged,
  follow-up questions ("what's next?", "how far now?", "did I miss
  the turn?", "am I there yet?") are answered against your live
  position with no network round-trip — under 10 ms response.
  "Never mind" or "cancel that" clears the route.
- **Email** — staged drafts for recovery / training reports. iOS's
  mail composer always presents for review before sending.

### Where am I / what's nearby

The AI answers location questions instantly during a workout because
the workout's GPS pipeline keeps a resolved-address cache warm
(road, locality, state, country, plus the **nearest cross street**
via MKLocalSearch — "Riverwood Dr near Eastland Ave"). Outside of a
workout, an ambient location service does the same job whenever the
app is foregrounded. The AI's `location.current` tool reads from the
cache; no more 30-second cold-fetch timeouts when you ask "what
street am I on" mid-walk.

If you're somewhere the geocoder can't resolve (deep wilderness, a
brand-new road, water), you can tell the AI verbally: "I'm at the
corner of Cherokee Pkwy and Lyons View" — it'll forward-geocode
that and use it for subsequent questions in the conversation.

#### `location_situation` — one-call situational awareness

A single tool bundles everything situational into one response, so the AI doesn't have to chain four separate calls:

- Current address (road, cross street, locality, state, country)
- Heading and speed
- Nearby POIs in five categories — water / restroom / food / parking / medical (via MKLocalSearch, distance-bounded)
- Active route's next-turn instruction (when a route is engaged)
- Journey block — shape (out-and-back outbound vs returning / loop / point-to-point / unknown), direction (toward origin vs away vs stationary), projected remaining seconds
- Recurrence sub-record when the current trail matches a historical pattern — "morning route near Benelli Dr, you've done this 6 times, median 47 min"

The journey block is computed by `JourneyIntelligenceService` from the active breadcrumb trail alone (no new permissions, no new APIs). The recurrence sub-record is computed by `RecurrenceClassifier` against the breadcrumb archive — coarse buckets on (start coordinate rounded to 100 m, weekday, hour-of-day band), then polyline-signature matching at default 75 m mean per-point offset. Two prior trails in the same bucket are the minimum for a match.

The AI is rule-bound to: **never claim it doesn't know your location, route, or breadcrumbs without calling this tool first**. If the response comes back without a `recurrence` field, the archive simply doesn't have ≥2 prior trails in this hour-band yet — the AI says "I don't see this as a recurring route in your history yet" instead of "I don't have that capability."

#### `location_roads_ahead` — forward-looking road awareness

Separate from `location_situation`, this tool answers "what road am I about to hit / is there a turn coming up" without a destination route engaged. Returns the next 1–3 intersections along your current road with cross-street names and distances, built on the OSM road graph + bearing-aware map matching.

When confidence is high the engine returns a pre-built phrase the AI speaks verbatim ("on Pintail Pointe, approaching Riverwood Dr in 220 ft"). When confidence is below 0.4 OR the phrase is null, the AI is hard-coded to say "I don't have road data for this stretch" — it is not allowed to invent a road name. This rule was tightened after a "roads ahead fabrication" incident where an earlier build let the model paraphrase even when the engine bailed.

Works globally wherever OSM has road coverage; degrades gracefully in unnamed-street regions (Japan, Korea, parts of Latin America) by falling back to neighbourhood phrasing.

### Training-load projections — composable AI primitives

Rather than ship one custom tool per scenario question, Flo exposes a small set of general-purpose projection primitives that the AI composes:

- `training.load.snapshot` — read the user's current ATL / CTL / TSB / ACR as starting state.
- `training.project_from($atl,$ctl,$daily_trimp,$horizon_days)` — project ATL / CTL / TSB forward from arbitrary starting state. Returns the final day's values plus key milestones (day 7, 14, 28).
- `training.days_until_converged_from($atl,$ctl,$daily_trimp,$gap)` — days until |ATL − CTL| ≤ gap, from arbitrary starting state. Returns notRecorded when convergence never happens within 60 days (signals the daily load is unsustainable).
- `training.projected_tsb($daily_trimp)` — single-step projected TSB for the live state.

The AI chains these for multi-stage scenarios: "if I keep 60 TRIMP days until convergence, then switch to 80 TRIMP, what's my TSB at day 28?" — three primitive calls, one composed answer. No per-scenario custom tool.

### Pre-fab Questions

| Chip | What it asks |
|------|--------------|
| How am I doing today? | Plain-English summary of today's recovery state |
| Why is my score what it is? | Factor breakdown + probable causes (uses your scoring rationale, not guesses) |
| Should I train hard today? | ATL/CTL/TSB analysis + readiness recommendation |
| What changed from yesterday? | Day-over-day delta across HRV, sleep, training, vitals |
| How do I compare to my baseline? | Z-score interpretation against your rolling baseline |
| Was my sleep good? | Sleep-stage breakdown + quality assessment |
| Is my training load okay? | Recent-load-vs-usual-range read + Foster's monotony interpretation |
| What should I focus on this week? | 7-day trend insight |
| Am I trending up or down? | Direction + slope analysis |
| What does my HRV tell you? | Translates RMSSD/SDNN/LF-HF/DFA α1 into plain English |

### Voice Input — two modes

There are two different voice affordances in the chat tab.

**Dictation (the mic icon next to the text field).** Tap to start, speak
your question, tap again to stop. Transcript fills the input; you tap
Send. One-shot. Good when you want to review and edit before sending.
Speech recognition runs on-device (`requiresOnDeviceRecognition = true`),
even when the chat is going to a paid model.

**Speech-to-text engine choice.** Settings → Flo → Speech-to-text lets you pick the recognizer used by both dictation and voice conversation mode:

- **Apple Speech (default)** — `SFSpeechRecognizer`. Zero setup, low CPU, immediate. Solid in quiet rooms; degrades in wind / footfall / traffic and can stall without finalizing in noisy environments.
- **WhisperKit** (`WhisperKitSTTBridge`) — open-source CoreML port of OpenAI Whisper. Better accuracy in wind / footfall / noise. First enable downloads the model (~100–400 MB depending on size), then runs entirely on-device with no API key. Settings shows download progress.

Selection switches at the next listening start, not mid-session.

**Voice conversation mode (the mic icon at the top-left of the chat).**
Tap once to open a continuous, hands-free conversation. Speak; the
assistant answers out loud through AirPods / speaker; you interrupt
by speaking. Tap again to end.

Voice conversation is tuned for earbuds + walks — the AI gets an extra
directive to keep replies to 1–3 sentences, no lists or headers. For
full written replies with formatting, use typed input.

#### Interrupting the AI

While the AI is speaking you can interrupt by saying **at least two
words**. One word ("stop!") won't fire — the gate deliberately requires
two to avoid cutting the AI off every time you cough, take a loud step,
or pass a truck. Sustained loud noise alone (wind, traffic) never
triggers an interrupt; only decoded speech does.

The mic button (when the AI is speaking) also forces an immediate
interrupt. The chat's **Stop** button does the same — it now kills
both the LLM response AND the text-to-speech so you don't keep hearing
an answer you've already canceled.

If voice mode keeps mishearing background noise as speech, or stalls
without finalizing, use the **Send now** button in the voice status pill
(visible while listening). It force-commits whatever transcript has
been captured.

#### Known voice limitations

- AirPods are strongly recommended. Phone speaker mixes TTS back into
  the mic; the software echo rejection helps, but occasionally the AI
  will cut itself off mid-sentence when its own words register as
  "new speech."
- Whispers below ~−50 dBFS won't cross the voice-activity threshold and
  won't register as speech. Speak normally or tap **Send now**.
- System interruptions (phone call, Siri, alarm) tear voice mode down
  entirely. You re-tap the mic to resume — we don't auto-resume
  because your context has usually shifted during the interruption.
- Voice is an MVP cut. Expect rough edges. When the AI talks over
  itself, misreads a number, or refuses to stop, tell it so — the
  system prompt is written to respect what you report hearing rather
  than flatly deny it.

### Long-Press Any Message

Context menu options:
- **Remember this** — Saves the message text as a fact in cross-session memory (see below).
- **Copy** — Copies the message text to clipboard.
- **Regenerate** (last assistant message only) — Drops the response and re-runs against the same prompt with the current model. Useful when you switch models and want the new one's take, or the answer was bad.

### Web Search (optional, opt-in)

The AI can search a curated whitelist of authority sources for questions
your on-device data can't answer (recent research, manufacturer
firmware, hardware specs, normative ranges).

**Setup:** Settings → Flo → Web Search section.
1. Get a free Tavily API key (1000 searches/month) — tap the "Get a
   free Tavily key" link — and paste it in, tapping **Save key**. On
   Claude this step is optional: with web search on, Anthropic runs the
   search itself, skipping the excluded sites below but not limited to
   the whitelists.
2. Flip the **Allow web search** toggle on

**What it can search** (curated whitelist):
- **Research intent** (default): PubMed, scholar.google, frontiersin,
  intervals.icu, fellrnr, joefrielsblog, alancouzens, Stephen Seiler,
  Marco Altini, Kubios, EliteHRV, HRV4Training, Oura, ACSM, UpToDate,
  Mayo Clinic, Cleveland Clinic
- **Manufacturer intent**: Polar, Garmin, Stryd, Concept2, Wahoo,
  Tacx, Saris, Apple, Zwift official docs
- **Always excluded**: Pinterest, Quora, Yahoo Answers, WikiHow, eHow

**Hard rules baked into the system prompt:**
- AI prefers your own data over web results — never searches for "your
  CTL" when a fact already has it
- Web results are reference material, NEVER medical advice; the AI
  won't synthesise new training/diet/supplement protocols from search
  content
- Source URLs always cited in Markdown link syntax so you can verify
- One search per turn unless you explicitly asked for a survey

Off by default. Your Tavily key is stored in the iOS Keychain on this
device, never synced to iCloud. Search queries are sent to Tavily —
their privacy policy applies.

### AI Mutation Tools

A small set of `[ACTION]` tools let you ask the AI to act on your data,
not just read it:

- **Rename a saved route** — "Rename Daily 1 to Morning Loop"
- **Save a recent workout** — "Save my last walk as Long Loop" /
  "Save my walk from Tuesday as Smokies Hike"

The AI is rule-bound to: only call these on explicit instruction in
the current turn (no inference from "I really like that loop"); read
the result back to you ("Renamed Daily 1 to Morning Loop" — verbal
receipt); surface disambiguation verbatim if multiple routes share a
name; never undo a mutation on its own initiative.

### Cross-Session Memory ("What the AI Remembers")

The assistant maintains a persistent list of facts about you that get injected into every conversation across all providers:

- Add manually: **Settings → Flo → What the AI Remembers** → type a fact (e.g., "I'm prepping for a marathon", "I have a stress fracture", "Always answer concisely"). Tap +.
- Add from chat: long-press any message → **Remember this**.
- Auto-add: toggle **Auto-remember things** in Settings. After every response the assistant runs a tiny background extraction pass and adds any new facts it identifies. Free on Apple, ~fraction of a cent on connected models. Off by default.
- Remove: swipe a fact in Settings, or **Forget everything** to wipe.

Stored on this device only — never sent anywhere except the AI provider you're chatting with at the time.

### Tappable Date Citations

When the AI mentions a date that matches a session in your archive (e.g., "your session on April 14, 2026"), the date renders as a tappable link. Tap it to open a quick-view sheet showing that session's score, HRV, sleep, training, and cached diagnosis. Read-only — for full editing, open the session from the History tab.

### Switching Models Mid-Conversation

The chat history carries over when you switch providers. The new model receives the full conversation (truncated to its token budget), the same recovery context, the same remembered facts, and any earlier conversation summary. From its perspective, it has been there the whole time.

One nuance: Apple Intelligence has a tighter chat-history budget than paid models. Switching to Apple in the middle of a long chat truncates more aggressively, but the auto-summary of dropped turns still flows through, so context isn't lost.

### Long Conversations

When the conversation grows past the active model's token budget, older turns are dropped from the *send window* (your local chat history is unchanged) and replaced with an auto-summary preamble. The model still sees what was discussed, just compressed. Tap **Clear conversation** in the ⋯ menu to start fresh.

### Keyboard Dismissal

Three ways to dismiss the keyboard so the bottom tab bar reappears:
1. **Swipe down** on the message log.
2. **Tap any blank area** in the message log.
3. **Done button** on the keyboard accessory bar (top-right of keyboard).

Sending a message also auto-dismisses the keyboard.

### Cost Notes (Connected Models)

Emuqu does not show real-time cost in-app to keep the UI clean. Token usage is reported by each provider on their dashboard:
- Anthropic, OpenAI, Google: their respective consoles
- Grok: xAI console
- DeepSeek: DeepSeek console

To minimize cost on paid models:
- **Anthropic prompt caching** is enabled automatically — sends within ~5 minutes after the first reuse the cached system prompt at ~10% cost.
- OpenAI, Grok, and DeepSeek do automatic caching server-side; no extra cost optimization needed.
- Apple Intelligence is always free (on-device).

### Known Limitations

- Apple Intelligence may refuse some health-adjacent questions (its built-in safety filter). When this happens, switch to a connected model.
- First Apple Intelligence call has a few-second cold-start (model loading). Subsequent calls are instant.
- Apple Intelligence uses the same tool catalog as the connected models, so it can fetch specific sessions on demand. But its 4K context window is tight — long conversations get aggressively trimmed, so a deep multi-week historical analysis is still better run on a connected model.
- The Fact Catalog covers sessions, walks, training load, user profile, and recent sleep. Monthly / yearly aggregations are not yet exposed as tools, so "how is my sleep compared to six months ago?" and similar aggregate queries will often come back "I don't have that" (or, worse, hallucinate) until those tools are added.
- Models occasionally still fabricate numbers despite prompt rules. When you catch one, call it out — the assistant is instructed to investigate rather than deny.
- Anthropic Haiku 4.5 is pinned to its dated model ID; Sonnet 4.6 and Opus 4.7 and every OpenAI / Gemini / DeepSeek / Grok ID are still floating aliases, which means the provider can silently repoint them and briefly disrupt prompt caching.
- Single rolling conversation thread — multi-thread history is not yet supported.
- Date citations resolve to the last ~30 days of sessions only.
- Voice conversation mode is an MVP: wind / traffic / phone-speaker acoustics can occasionally confuse the four-gate barge-in. AirPods recommended. See [VOICE_AND_TOOL_USE.md](VOICE_AND_TOOL_USE.md) for the full list of known failure modes.

---

## History Tab

Browse all your past HRV sessions. The list loads quickly using in-memory metadata — full session data is only loaded when you tap a specific session.

### Session Type Filter
Horizontal buttons at top:
- **All**: Show all session types
- **Extended**: Overnight sleep recordings
- **Naps**: Shorter sleep recordings
- **Quick**: Streaming spot checks
- **Breathe**: Apple Watch Breathe app readings

### Tag Filter
Scrollable row below type filter:
- **"All"** button clears tag filters
- System tags with color coding
- Tap multiple tags to filter (shows sessions matching ANY selected tag)

### Search
- Search bar at top
- Search by date, tag name, or notes content

### Session List
Sessions are paginated (10 at a time) and grouped by time period. Scroll to the bottom to load more:
- Today
- Yesterday
- This Week
- Last Week
- [Month Year] for older sessions

**Each Session Row Shows:**
- Session type icon (moon for overnight, clock for quick, etc.)
- Time (analysis window end time for overnight, or session start time)
- Session type badge ("Nap" or "Quick" if applicable)
- Date
- Tags (first 3 shown, "+N" if more)
- RMSSD value (large, right-aligned)
- Recovery score with score breakdown (composite 0-100 showing HRV, sleep, and vitals components under the v2.may2026 architecture)
- Readiness score indicator (shown for any session with a calculable recovery score):
  - Green checkmark: 7+
  - Yellow minus: 5-7
  - Orange exclamation: <5

### Swipe Actions
- **Swipe Left (trailing)**: Red "Delete" button
- **Swipe Right (leading)**: Blue "Edit Tags" button

### Long-Press a Row
Context menu with **Ask Flo about this session** — pre-fills a question in the Flo tab with that session's date, score, and key metrics, then switches to the chat. Works for any session in the last ~30 days.

### Tap Session
Opens the full MorningResultsView in a sheet.

### Empty State
- Shows when no sessions exist or no sessions match filters
- **"Clear Filters"** button appears when filtering

---

## Trends Tab

Analyze patterns across multiple sessions.

### History Calendar (primary surface)

A real monthly calendar grid sits at the bottom of the Trends tab, replacing the dead-tap heatmaps the app used before.

- **Sun–Sat columns**, real month grid (full weeks, including spill days from neighbouring months).
- **Swipe horizontally** to scrub between months. Chevrons in the header do the same. Bounded — you can only navigate to months that have data plus the current month.
- **Each cell shows the day's preferred LOAD** (powerTSS → hrTSS → METs → luciaTRIMP → route-history fallback, per `WorkoutMetadata.preferredTrainingLoad`). Empty days show nothing.
- **Weekly totals** to the right of every row (Sun–Sat). **Monthly total + session count** in the header.
- **Tap a day with sessions** → DaySummarySheet listing each session's headline numbers. Tap a row in the sheet to open the full session detail — `MorningResultsView` for overnight, `FitnessPostSummaryView` for workouts.

### Morning Feeling Heatmap (secondary surface)

Below the calendar, the original morning-feeling heatmap is kept as a smaller card — a colour grid of your daily 1–5 self-rating over the selected period. Different purpose from the calendar (subjective rating, not load), so it sits as a complement, not a duplicate.

### Tag Filter Bar
- **"Filter by Tags"** header
- **"Clear"** button (appears when filters active)
- Filter settings button (slider icon) opens full filter sheet
- Quick chips: "All" + first 4 system tags
- Shows "[excluded count] excluded" if any tags excluded
- Active filter summary: "X of Y sessions" when filtered

**Filter Sheet:**
- Include section: Select tags to show only sessions with those tags
- Exclude section: Select tags to hide sessions with those tags
- **"Clear All Filters"** button

### Period Selector
Horizontal buttons:
- 1 Week | 2 Weeks | 1 Month | 3 Months | All Time

### Overall Trend Card
- Direction icon:
  - Green up arrow: Improving
  - Blue left-right arrows: Stable
  - Orange down arrow: Declining
  - Gray question mark: Insufficient data
- Session count
- Date range

### Trend Chart
**Metric Selector Tabs:**
- RMSSD | SDNN | HR | LF/HF | DFA | Stress | Readiness

**Chart Shows:**
- Blue line with points: Individual readings
- Orange dashed line: 3-day rolling average

**Legend:**
- Blue dot = Value
- Orange dash = 3-day avg

### Statistics Grid
For each metric, shows a card with:
- Metric name
- Mean value with standard deviation (±)
- Trend arrow (up/stable/down)
- Session count
- Deviation from baseline percentage

**Metrics displayed:**
- RMSSD (ms)
- SDNN (ms)
- HR (bpm)
- LF/HF (if available)
- DFA α1 (if available)
- Stress Index (if available)
- Readiness (/10)

### Insights Section
- Lightbulb icon
- Auto-generated insights about your patterns
- "Keep recording to generate insights" if insufficient data

### No Data State
- Chart icon
- "Not Enough Data"
- "Record at least 2 sessions to see trends"

---

## Detailed Report View (MorningResultsView)

Comprehensive recovery report accessed from Dashboard or History.

### Header Section
- "Recovery Report" title
- Session date
- Quality badge (Excellent if artifact <5%, Good otherwise)
- Beat count
- Analysis window info (e.g., "Best 4.9 min window from overnight recording")

### Key Metrics Section
- **HRV Hero Card**: Large RMSSD display with:
  - Value in ms
  - Label (Excellent/Good/Fair/Reduced/Low)
  - Age-adjusted context (if age configured)
  - Tap for explanation popover
- **Heart Rate Stats Row**: Min HR, Avg HR, Max HR, SDNN

### Readiness Section
- "Recovery Readiness" header with info button
- Large gauge (0-10 scale)
- Color-coded score
- Interpretation text

### Training Load Section
*Only appears if training data available*
- ACR gauge with zone indicator
- ATL/CTL/TRIMP metrics
- Recent workouts list (if available)

### Analysis Summary Section
- Dynamically generated paragraph summarizing your recovery status

### Analysis Window
*Only for overnight sessions with raw data and reanalysis support*

**Method Dropdown**: A dropdown menu lets you switch how the app picks the analysis window:
- **Best Recovery (Default)** — Picks the most stable, organized recovery window during deep sleep. This is what most HRV apps report.
- **Highest RMSSD** — Finds your highest parasympathetic activity regardless of stability.
- **Highest SDNN** — Finds your highest total heart rate variability (sympathetic + parasympathetic).
- **Highest Total Power** — Finds the window with the most overall autonomic nervous system activity.

Selecting a method instantly re-runs the analysis and updates all metrics on the page.

**Choose Your Own Window**: Tap the "Choose Window" button to enter manual mode. In this mode:
1. The HRV chart shows a hint: "Tap anywhere to analyze that window"
2. Tap or drag on the chart to place a cursor — when you lift your finger, the tooltip and "Analyze Here" button stay pinned so you can tap it
3. Tap "Analyze Here" to run analysis at that position
4. A comparison banner appears showing **Auto** (the algorithm's pick), **Yours** (your manual selection), and the **Diff** between them
5. On the chart, the auto-selected window dims and your manual window highlights in green
6. Tap "Exit" to leave manual mode and clear the comparison

Manual selections are for exploration only — they are never saved to your trends or baseline. The auto-selected window always remains the canonical score for consistency.

**Provenance**: Below the method picker, the exact time range and sleep segment of the current analysis window are shown.

### Peak Capacity Section
- Highest sustained 5-minute HRV period
- Shows RMSSD value and time

### Session Charts Section

Chart labels adapt to context: "Overnight Summary" / "Heart Rate Overnight" / "HRV Overnight" when sleep data is present; "Session Summary" / "Heart Rate" / "HRV (Rolling RMSSD)" when no sleep data exists.

**HRV Chart** (shown first — primary interaction surface):
- Rolling RMSSD trend throughout the recording
- Analysis window highlighted with time range pill
- When in manual mode, the auto window dims and the manual window shows in green with "Auto" and "Yours" labels
- Tap or drag to explore — tooltip shows RMSSD value and time at cursor position
- After lifting your finger, the cursor pins in place with an "Analyze Here" button
- Tap elsewhere on the chart to move the cursor, or tap "Analyze Here" to run analysis at that point

**HR Chart** (shown below HRV):
- Heart rate trend during the recording
- Sleep stage overlay (if HealthKit data available)
- Analysis window highlighted to match the HRV chart

### Technical Details Section
*Collapsed by default - tap to expand*
- **Tachogram**: RR interval time series chart
- **Poincaré Plot**: SD1/SD2 scatter plot with ellipse
- **Frequency Domain** (if available): LF/HF power, LF/HF ratio
- **Additional Metrics**: pNN50, DFA α1, Stress Index

### Trends Section
- Comparison with recent sessions
- Baseline deviation

### Tags Section
- Current tags on session
- Tap to add/remove tags

### Notes Section
- Text field for session notes
- Auto-saves when changed

### Action Buttons
- **"View PDF Report"**: Generates a professional 3-page PDF report:
  - **Page 1 — Metrics & Data**: Summary card (RMSSD hero, readiness gauge, HR stats), overnight stats, sleep analysis (duration, efficiency, stages), training load (CTL/ATL/TSB/ACWR), recovery vitals (respiratory rate, SpO2, temperature, resting HR), full metrics grids (time domain, frequency domain, nonlinear, ANS), tags and notes
  - **Page 2 — Visualizations** (only for sessions with raw RR data): Overnight HR chart with analysis window highlight, Poincaré plot with SD1/SD2 ellipse, PSD graph with VLF/LF/HF band coloring, RR tachogram with artifact markers, data quality summary, window selection info
  - **Page 3 — Analysis Summary**: Full narrative analysis from the summary generator
- **"Delete"** (if viewing from History): Permanently deletes session
- **"Reanalyze"**: Re-runs analysis using the current window selection method. Useful when algorithm updates improve scoring.

---

## Fitness Tab

The Fitness tab is where you record workouts, get live coaching, and review
the full post-workout report. Chest-strap + GPS gives the most complete
picture; Apple Watch and pure motion-only sessions also work.

### Fitness tab dashboard

When you open the Fitness tab without a workout in progress, you see a
**hero card** for your latest workout. Tap anywhere on the card to open
the full post-workout report. The hero shows:

- Sport badge (icon + activity label) + relative time (e.g. "2 hours ago")
- **Big distance readout** + duration + pace
- **Mini route polyline** traced from the GPS track (no map tiles — fast)
- **Scrollable badge row**: peak HR, elevation gain, α1 average, TRIMP,
  hrTSS — only renders the badges with real data

Below the hero: workout-count tiles for the past 7/30 days, a passive
activity card (phone-tracked steps/distance), the **Get Me Back card**
(see below), and a recent-workouts list.

### Get Me Back mode

Offline breadcrumb-and-arrow trail recovery. Tap **Get Me Back** to
drop a pin where you start; the app captures fixes every 30 s OR 25 m
of movement. Tap **Open** later to see a compass arrow physically
pointing back to the origin — hold the phone flat, rotate your body
until the arrow points up the screen, walk that direction.

Honest about accuracy: the arrow visually fuzzes when GPS is poor
(canopy, urban canyon) and disappears entirely above 100 m of
horizontal accuracy with "Wait for a better fix" — never projects
false confidence. Atomic save on every fix means it survives a crash,
a kill, or a phone-locked-in-pocket day-long use.

Buttons inside the navigation view:
- **Talk to AI** — opens voice chat. The AI sees `breadcrumb.active`
  so it can reason about the trail ("how far back is the trailhead?",
  "should I turn around now?", "what direction is home?").
- **SOS** — confirmation alert with iPhone-14+ satellite-SOS
  guidance (side-button gesture) and a `tel://911` fallback.
- **Clear** — three-way alert: Keep going / End and save (archives
  the trail, default destructive action) / Discard (permanent delete).
- **Settings disclosure** — brightness slider that reverts when you
  leave the screen. Drag down to save battery in daylight.

The next morning if a trail is older than 12 hours, the Dashboard
shows a one-time prompt: "Still keeping yesterday's trail? Keep /
Delete." Always confirms before deleting.

**Auto-archived workout trails.** Every GPS-bearing workout's track
is saved to the breadcrumb archive automatically when the workout
ends — labelled "Run on Apr 29, 8:13 AM" etc. So you can ask the AI
"lead me back to where I parked for my morning run" without having
engaged Get Me Back beforehand. Up to 50 trails kept; oldest evicted.

### Starting a workout

When you tap Start, paired secondary sensors auto-reconnect: a
previously-paired Polar strap (H10 or Verity Sense) reconnects via
its remembered peripheral ID, and a previously-paired Stryd footpod
reconnects in parallel. You don't have to dig through Settings to
re-pair every session. After the workout ends, the strap stays
connected for the post-stop HRR window (~120 s) so the 1-min /
2-min HR drops capture cleanly, then disconnects automatically.
Footpod disconnects the moment the workout ends.

1. Pick a sport — Walk, Run, Trail Run, Hike, Bike, Indoor Bike, Treadmill,
   Row.
2. Pick an HR source — **Strap** (full HRV metrics via RR intervals),
   **Apple Watch** (HR only, no RR-dependent metrics), or **None**
   (time, distance, cadence only).
3. Optionally set a **target HR zone** (1–5). When set, the voice coach
   gently nudges you if you drift out of zone for ≥30 s.
4. Optionally pick a **structured interval plan** — the coach will announce
   each step as it starts.
5. Optionally add **ambient-coach thresholds** — pre-declare physiological
   constraints ("HR > 135 for 30s", "stay above zone 2 power", "pace below
   9:00/mi"). The coach stays silent (your audiobook keeps playing) and
   only ducks in when a threshold breaches past its debounce. Each
   threshold has its own debounce + cooldown so it never nags. HR /
   HR-zone / power / power-%FTP / pace / DFA α1 / cadence are supported.
6. Optionally bind a **route** — three ways to do this:
   - **Discover trails near me** (the big terracotta button) searches
     OpenStreetMap for hiking / mountain biking / road cycling trails in
     a radius you pick (2–50 km), filtered by length and difficulty.
     Results show a map preview, length, distance from you, and a
     colour-coded difficulty badge. Tap "Use this trail" — it binds as
     today's route AND saves to your library so the road-name
     enrichment fires before you start.
   - **Load GPX** — import a one-off GPX file from Files / iCloud /
     anywhere.
   - **Saved routes** — recognised automatically once you've covered
     ~500 m of GPS movement matching one in your library (in either
     direction).

   With a route bound, the AI coach gets the full topography (climbs
   ahead with road names + grade + length, peak altitude, total ascent
   remaining) and can speak about it precisely — "the climb on Old
   Topside Rd in 0.4 miles" instead of "a climb ahead."

### Live road context

Whenever you're outdoors with a GPS fix, Apple's geocoder turns your
position into a street name + city + state every ~50 m of movement
(or every 2 minutes if you're standing still — catches the "turned a
corner without moving the threshold" case). The AI coach gets these
in its live context, so:

- "What street am I on?" → real answer, not "lat 35.96 lon -83.92"
- "How far to the climb on Newfound Gap?" → answered against the
  road-named climb queue
- "You're on Cherokee Pkwy in Knoxville, Tennessee" → contextual
  spoken cues

Free, on-device where possible, no API key. Falls back to silence
when you're somewhere CLGeocoder doesn't recognise (water, deep
wilderness) — never fabricates a wrong street name.

### Power meters

Emuqu treats running, cycling, and rowing power as first-class
metrics:

- **Stryd foot pod** — pairs over BLE RSC. Streams running power at 1 Hz.
- **FTMS bike trainers** (Wahoo Kickr, Tacx, Saris, etc.) — pair over BLE
  FTMS. Streams cycling power.
- **Concept2 PM5 rower** — pairs over the PM5 Rowing service. Streams
  stroke rate, distance, drag factor, and instantaneous power.

Set your **running FTP** and **cycling FTP** separately in **Settings →
Profile & Health → Biometrics**. The post-workout summary surfaces
**Normalised Power (NP)**, **Intensity Factor (IF = NP / FTP)**,
**Power-TSS** (`(NP/FTP)² × hours × 100`), and **Variability Index**
alongside the HR-based hrTSS. Without an FTP, the power-derived metrics
sit out and the card tells you where to set it — the app never invents a
denominator.

### My Routes (route library + route-aware coaching)

After any GPS workout, the post-summary shows an **"Add to my route
library"** action. Name it ("Daily 1", "Long loop", "Saturday hill") and
the route is saved. Manage them in **Settings → My Routes** (rename,
delete).

Next time the app sees you running a saved route — **in either
direction** — it recognises it after about 500 m and binds it to the
session. The AI coach then knows:

- Which route you're on, and which direction
- The next climbs ahead (length + grade + total gain)
- Total ascent still to come
- Peak altitude on the route + how far away the peak is
- Steepest grade still ahead

So instead of a generic "climb ahead", the coach can say:

> "Climb in 200 yards — 0.4 miles at about 7 percent grade. First of 3.
> Save some power."

Routes match direction-agnostically, so a single workout that runs the
loop one way, returns home, then runs it the other way maps to the
**same** saved entry in both directions.

### Live weather context

Whenever you're outdoors with a GPS fix, the AI coach also gets current
weather — temperature, apparent temperature, wind speed + direction,
humidity, conditions (Clear / Overcast / Light rain / Thunderstorm /
etc.) — from Open-Meteo (no API key, free, global). It refreshes every
30 minutes during the workout. Lets the coach make weather-aware
suggestions ("you're already 80 % VO2max in 92 °F heat, ease back").

### Zwift / TrainerRoad / Rouvy broadcaster

When the `enableZwiftBroadcast` toggle is on (**Settings → Profile &
Health → Wearables → Broadcaster**, with a first-enable explainer
sheet), Emuqu advertises itself as a standard Heart Rate Service +
Cycling Power Service peripheral. Lets a user who's already paired their strap
+ Stryd / bike trainer to Emuqu share that data with their
indoor-trainer game without re-pairing each device. Off by default —
only useful indoors.

### During a workout (live view)

- **HR / Pace / Distance / Elevation / Steps** tiles update every second.
- **DFA α1** tile shows your aerobic/threshold/hard band and reports why
  if a value isn't available — "warming up 45 %", "strap silent 32 s",
  "fit failed".
- **Power / METs** tiles appear when the data source is live.
- **Live map** shows your route and current GPS accuracy.

### Voice coach

The voice coach (AirPods recommended) evaluates a rule engine each tick.
It speaks only when a real signal fires (α1 crossing, HR drift, zone
drift, climb ahead, strap dropped) — silence is a feature. When active,
the AI receives a complete live snapshot each tick including wall-clock
time, GPS position + heading, grade, current/peak HR, α1 status, units
preference, recent splits, strap quality. This is what lets the coach
answer "what's my pace?" / "how much farther to the top?" / "am I in my
zone?" with real numbers instead of guesses.

### Post-workout summary

The summary opens instantly when you tap Stop. HRR captures in the
background for the next 120 s and fills in when ready.

Cards shown (each appears only if its underlying data is present):

- **Map** with your route.
- **Headline stats** — distance, duration, avg pace, top speed, elevation
  gain, HR avg/peak, cadence, power, METs, calories, TRIMP, hrTSS.
- **Heart Rate Recovery** — 1-min and 2-min drops from peak, with
  colour-coded thresholds. "No signal" appears when the capture window
  ran but the strap was off.
- **Charts** — HR / Pace / Cadence / Power over time, Elevation profile.
- **DFA α1 Timeline** — your α1 curve with reference lines at AT1 (0.75,
  aerobic threshold) and AT2 (0.50, anaerobic threshold), plus a
  summary of minutes spent in each band.
- **Route by α1 Band** — a second map colouring your route green/yellow/
  orange by physiological zone so you can SEE where you crossed
  thresholds on the course.
- **α1-Estimated LT1** — the HR at which α1 crossed 0.75 this session.
  In lab comparisons this lands within about ±10 bpm of the gas-exchange
  aerobic threshold (Rogers & Gronwald 2021 and later cohorts). When your Settings
  LTHR is still on the default heuristic and differs from the observed
  value by ≥ 5 bpm, the card prompts you to update it.
- **Threshold Crossings** — timestamp, HR, pace at each AT1/AT2 crossing.
- **HR Zone Distribution** — stacked bar + per-zone minutes (Z1-Z5 based
  on YOUR max HR, not session peak).
- **Derived Metrics** — moving-time %, VAM (vertical ascent m/h),
  grade-adjusted pace, calorie rate (kcal/h), avg stride length,
  power:HR ratio.
- **Physiology** — Pa:Hr decoupling, Efficiency Factor.
- **Splits** — per-km (metric) or per-mile (imperial), with pace + HR.
- **Export** — GPX / CSV / TCX to Strava, Garmin Connect, TrainingPeaks,
  etc.

### Training load — how TRIMP and hrTSS are computed

Both values are **anchored to your configured max HR, resting HR, and
LTHR** — never to session peak (which inflated scores on hot/hard days
and made the same walk read differently from cool-day to hot-day).

- **TRIMP** uses **Banister 1991**: continuous, sex-dependent
  exponential integration on heart-rate reserve. Formula:
  `TRIMP = Σ(dur_min × HRR × A × e^(k·HRR))` — male users: A = 0.64,
  k = 1.92; female users: A = 0.86, k = 1.67. Sex is taken from your
  Profile setting and applied per-session. Accepted baseline across
  endurance sports.
- **hrTSS** uses the **HRSS formulation**: session TRIMP divided by
  the TRIMP of exactly 1 hour at your LTHR, ×100. This is what TSS
  was designed to mean — *one hour at threshold = 100 points*.
- **LTHR** defaults to 0.88 × your max HR (Friel's recommended midpoint
  for fit athletes). You can override it in **Settings → Profile &
  Health → Biometrics** if you've done Friel's 30-min time-trial field
  test.
- **Resting HR** preference order: user override (Settings → Profile &
  Health → Biometrics) → tracked HRV baseline → 60 bpm fallback.

### Power-TSS (when you have a power meter)

When the session was recorded with a power source (Stryd / FTMS bike /
PM5 / cycling power meter) AND the matching FTP is set, the post-summary
adds:

- **Normalised Power (NP)** — Coggan's 4-second rolling average → mean
  of the 4th power → 4th root. Better matches the physiological cost of
  variable-effort sessions than raw average.
- **Intensity Factor (IF)** = NP / FTP. 1.0 = exactly your hour-power.
- **Power-TSS** = `(NP / FTP)² × hours × 100`. The canonical
  TrainingPeaks formula — same one Strava, Intervals.icu, TrainerRoad
  use.
- **Variability Index** = NP / avg power. > 1.05 means a punchy,
  variable session; ~1.00 means steady.

If FTP isn't set, these all sit out and the card tells you where to set
it. The app never invents a denominator.

### Running FTP auto-estimator

Most users have never done a 20-minute FTP test and never will. If you have a Stryd foot pod that's been recording normalized power on your runs, Emuqu can derive a credible running FTP from your archive without asking you to do anything.

**What it does:**
- Scans archived workouts in the running family (run, trail run, walk, hike, treadmill) where Stryd power was captured.
- Skips sessions shorter than 20 minutes — short intervals overshoot NP and don't represent threshold.
- Picks the **highest `normalizedPowerWatts`** session as the anchor (a single hard effort is a better threshold proxy than averaging easy days).
- Applies the TrainingPeaks convention: `FTP = best 20-min NP × 0.95`.
- Caches the estimate in `UserDefaults`, along with the source session ID and the date the scan ran. Recomputed weekly.

**Where it's used:** the estimate fills in for power-TSS computations when you haven't set a running FTP manually. Settings → Profile & Health → Biometrics still wins if you set one yourself.

**Limitation:** if your archive only contains easy walks and no hard sessions, the estimate will under-predict your real threshold and inflate every workout's TSS. The estimator only runs when the archive contains a near-threshold anchor; otherwise it sits out rather than guess.

### One-shot load backfill

Old workouts whose strap dropped mid-session — common cause: sweat or contact loss after the warmup — used to surface "1 TRIMP" on the Load page because `extrapolatedTRIMP` was nil and the preferred-load resolver fell all the way through to a junk Banister value.

A one-time backfill (`WorkoutLoadBackfill`) runs once per week to retroactively apply `RouteTRIMPEstimator` to archived workouts that match a saved route shape:

- Lookback: 90 days.
- Idempotent — once an estimate has been written, that workout is skipped.
- Gated on saved-route count: if you add a new saved route, the scan re-runs so workouts that now match the new route get covered.
- Cheap: O(N) over recent workouts, each step is a polyline-shape match against `RouteLibrary` plus a handful of archive reads.

After the first launch with this build, the Load page, recent-workouts list, ATL/CTL chain, and the AI coach all read coherent numbers for your historical workouts without forcing you to re-record anything.

### Turn-by-turn alerts (opt-in, 2026-05-08)

Two new toggles live in **Settings → Notifications → Navigation**:

- **`enableTurnByTurnAlerts`** (default **off**) — when you have a route engaged (via "Save my run" / "Load my Saturday loop" / a discovered trail), you'll hear proactive voice alerts at ~500 ft, ~200 ft, and AT each upcoming turn. Built on a debounced `TurnAlertEngine` so you don't get re-alerted on GPS jitter.
- **`enableTurnMarkerUpdates`** (default **off**) — after each completed turn, the voice coach reads a per-leg recap (HR + pace + elapsed time on that leg). Useful for structured workouts where each leg matters; noisy on casual walks. Both can be on simultaneously.

Both toggles are off by default specifically because the casual-walk user doesn't want continuous talking. Turn-the-toggles-on athletes get the proactive routing without affecting everyone else.

### Validated physiology references

The app cites, in the source code and here, the studies it relies on:

- TRIMP — Banister 1991 (Fellrnr summary: https://fellrnr.com/wiki/TRIMP)
- DFA α1 threshold detection — Rogers & Gronwald 2021 (PMC7845545), with
  Schaffarczyk 2022, Van Hooren 2023 and Sempere-Ruiz 2024 as the later,
  weaker cohorts
- hrTSS HRSS method — intervals.icu / Fellrnr derivation
- LTHR protocol — Joe Friel's 30-min TT method
- Elevation gain via DEM + 10 m sustained-climb threshold — Strava's
  documented approach when barometer data isn't available
  (https://support.strava.com/hc/en-us/articles/115001294564)

Why not more-individualised TRIMP? **TRIMPi** (Manzi 2009) correlates
better with race performance (r = 0.77-0.87) but requires individual
blood-lactate testing in an exercise lab. Most users don't have that.
For users who do, the LTHR override in Settings is the way to feed
lab-tested anchors into the app's calculations.

### Elevation accuracy — how Emuqu actually measures it

Elevation is handled using sports-biomechanics sensor-fusion best
practice (Barczyk & Nemra 2014) — not by smoothing GPS altitude
noise, not by accumulating raw deltas at threshold.

**New recordings** on any iPhone with a barometer (every model
since iPhone 6):

1. The app collects every `CMAltimeter` barometric altitude sample
   (~1 Hz native rate) into a buffer during your walk.
2. At session stop, a post-hoc processor applies:
   - A 15-sample symmetric moving-average smoother (zero phase
     lag since it runs offline) — matches the ~8 s time constant
     recommended in the sports-fusion literature.
   - A 1 m threshold on the smoothed signal (2× the CMAltimeter
     documented noise floor of 0.3-0.5 m).
3. The processed value is written to the archive.

Result: elevation numbers consistent with iSmoothRun / Apple
Fitness / FITIV, all of which also read the same barometer sensor.

**Older recordings** (from before the barometer-buffer fix) have no
stored barometer samples to process. The "Look up real elevation"
button in the summary queries a real terrain DEM (USGS NED 10 m for
US / SRTM 30 m global fallback) for the elevation at each of your
GPS coordinates and re-computes gain with a 15 m sustained-climb
threshold (empirically calibrated against barometric ground truth
in rolling terrain). Writes the result to the archive. Always an
approximation — future walks will be more accurate via the live
barometer path.

**No-barometer devices** (pre-iPhone 6) fall back to GPS altitude
with a tight noise gate — clearly labelled as an estimate in the UI.

**Why not smooth GPS altitude?** GPS vertical accuracy is ±5-10 m
per fix. Over a 60-min walk with 500+ fixes that noise integrates
to either 2× overcount or severe undercount depending on the
threshold. It isn't signal to be extracted — you need a different
sensor. That's what the barometer is for.

### Repairing α1 on historical walks

Pre-filter sessions carried an inflated α1 reading because the live
analyzer was feeding raw RR (including ectopic beats and movement
artifacts) directly into DFA. The summary has a **"Re-analyze α1 for
this session"** button that replays the current Kubios-style artifact
filter + DFA over the stored RR data and writes corrected per-sample
α1 values back to the archive. After tapping, reopen the summary and
the α1 timeline + LT1 estimate reflect the clean values.

### Data quality filters

- **Cadence**: sport-aware cap — 125 spm for walks / hikes, 220 for
  runs, 140 RPM for bikes. Foot-pod readings above the sport's
  physiological maximum are rejected as artifact (jogging cadence
  starts around 150 spm, so a walk seeing 140 is mechanically
  impossible).
- **Tail spike filter**: drops the last few samples of any chart
  series if they exceed 1.5× the trailing-30-sample median.
  Common foot-pod behaviour at stop-time.

---

## Home-screen Widget + Live Activity — REMOVED (2026-07-03)

Emuqu **no longer has a home-screen widget or Live Activity.** The
WidgetKit extension was removed on 2026-07-03 (it was dead code) and the Live
Activity was dropped earlier. Today's recovery score lives on the Dashboard tab
inside the app. (An orphaned writer still copies the score into a shared App
Group container, but nothing reads it — a future cleanup will remove it.)

---

## Apple Watch Companion App

> **Status (re-embedded 2026-07-03):** the Watch target is embedded in the iOS build again — the "Embed Watch Content" phase was restored (the iOS app now embeds the `Watch App` target directly, bypassing the legacy `watchapp2-container`). A build installed to your phone installs the Watch app on a paired watch. The design below is confirmed as **phone-mirror + wrist controls**; some mirror-mode wiring (reachability gating, pre-workout strap-state display) is still being validated on-device, so treat specific wrist behaviors as the intended design.

The watchOS app extends an in-progress iOS workout to the wrist. It is **not a standalone recorder** — every canonical workout is still written by the iOS app, with one entry per workout in HealthKit. The Watch app exists for three reasons:

1. **Live workout view on the wrist** (`WatchLiveView`) — current HR, elapsed time, distance, pace, and current sport, mirrored from the iOS recorder via `WCSession`.
2. **HKWorkoutSession keep-alive** (`WatchWorkoutManager`) — while iOS is recording via Polar, the Watch keeps a parallel `HKWorkoutSession` running so wrist HR is dense (1 Hz) and the Watch stays awake without dimming. The Watch's session never finalizes into a separate `HKWorkout` — `session.end()` is called without writing one, which is what prevents the duplicate "Apple Watch — Outdoor Walk" entries that competitor apps produce.
3. **HR fallback** — if the phone's Polar strap disconnects mid-workout (sweat, the user takes it off for HRR capture, range loss), the Watch's wrist HR is forwarded back to the phone via `WCSession.sendMessage` so HRR capture and live HR can still succeed.

### Watch strap pairing

A separate Bluetooth pipeline on the Watch (`WatchStrapConnector`) lets the Watch itself pair directly with a Polar H10, Polar Verity Sense, or any Bluetooth Heart Rate Service device (UUID 180D, characteristic 2A37). This matters when the iPhone is out of range, in another room, or its app has been terminated — without this pipeline the Watch's "strap" pill went stale and live HR vanished.

- Pair from **Watch app → Strap → Scan**.
- Last-paired peripheral identifier persists on the Watch in `UserDefaults`, so reconnect is automatic on Watch app launch.
- Live HR and RR are pushed back to iOS as `watchStrapSample` messages — the iPhone-side recorder folds them in as a fallback when its own BLE path is empty.
- Permission and connection state (Bluetooth off / not authorised / scanning / connecting / connected) renders in the strap pill so you get a clear status instead of a silent failure.
- BLE in watchOS background is intentionally left to the system. The app does not request `bluetooth-central` background mode and stops scanning aggressively when the Watch app backgrounds — continuous background BLE on the wrist is a battery sink.

### Known Watch limitations

- The Watch app is a **viewer + remote + HR source**, not a standalone recorder. If your iPhone is dead, the Watch alone will not produce a workout.
- HealthKit authorization on the Watch is separate from iOS — the Watch app prompts the first time you tap Start. The auth-failure case is surfaced so the strap-drop fallback no longer silently fails when the prompt was denied or never appeared.
- watchOS `HKWorkoutSession.start()` can throw at app cold-start before `HKHealthStore` is fully booted; the manager logs the start failure into `lastStartError` and surfaces it to the Watch UI so the user knows wrist-HR fallback won't fire.

**Note.** The Watch app is unrelated to the home-screen widget, which was removed on 2026-07-03. Watch ↔ iPhone communication is over `WatchConnectivity` (`WatchConnectivityBridge` on the phone, `WatchSessionManager` on the wrist), not the App Group.

---

## Help Center

The Help Center (accessible from **Settings → Help Center**) provides a searchable library of articles organized into 11 categories:

- **Getting Started**: What is Emuqu, your first reading, building your baseline, setting up your device
- **Recording**: Extended recording, quick readings, split sleep, data quality
- **Your Recovery Score**: Understanding the score, how it's calculated (HRV / Sleep / Vitals 60/25/15 three-tier system), confidence pips, daily feedback chip, the analysis window
- **Comeback mode**: 21-day weighting shift for returning from illness or injury
- **Sleep Analysis**: Sleep score components, sleep latency, understanding sleep stages
- **Training Load**: ATL/CTL/TSB/ACWR metrics explained, ACWR training zones
- **Recovery Vitals**: Respiratory rate, SpO2, temperature, and resting HR as recovery signals
- **HRV Science**: What is HRV, complete metrics reference (age-personalized when birthday is set), DFA α1 explained
- **Your Data**: Data protection layers, recovering lost data, iCloud sync
- **App Navigation**: Dashboard guide, History guide, Trends guide, Breathing Mandala guide
- **Personalization**: Language switching, color themes, lifetime access

All articles are searchable — type in the search bar to filter across all categories.

---

## Settings Tab

Settings uses an iPhone-style hub page with drill-in sub-pages:

### Profile
- **Birthday**: Set your date of birth (used for age-based HRV interpretation and personalized Help content)
- **Age**: Auto-calculated from birthday
- **Fitness Level**: Not Set / Sedentary / Lightly Active / Moderately Active / Active / Very Active / Athlete
- **Biological Sex**: Not Set / Male / Female / Other
- **Temperature Unit**: Celsius (°C) or Fahrenheit (°F)

### Sleep
- **Typical Sleep**: Your normal sleep duration (5-10 hours, 0.5 hour increments)
- **Bedtime**: Your expected bedtime (hour and minute picker). Defines the overnight search window for HealthKit queries, reading detection, daytime HR queries, and baseline classification. Defaults to 10:00 PM.
- **Wake Time**: Auto-computed from bedtime + typical sleep hours (read-only display)
- **Combine Segments (Split Sleep)**: Controls whether separate overnight recordings count as one night
  - **Off**: Segments scored independently
  - **Default (4.5 hrs)**: Segments within 4.5 hours count as one night
  - **Custom**: 1–12 hours in 0.5h steps
- Note: Shift workers should set their actual bedtime for accurate results.

### Profile &amp; Health (4 sub-pages)

The former "Health Integration" grab-bag was split into four focused pages in
the 2026-04 sweep. Enter via the Profile &amp; Health row in Settings.

**Profile** — birthday, fitness level (training background), biological sex,
temperature unit, distance &amp; pace units.

**Biometrics** — Max HR (80–230 clamped), Resting HR (30–110), Lactate
Threshold HR (80–220), Body Weight (25–250 kg), VO2max override (10–100).
"Use HealthKit VO2max" toggle pulls from Apple Health when no manual override
is set. **Home Address** (free-text) — used by the AI's "lead me home"
routing when you ask things like "navigate me back home" / "route to my
house". Apple's geocoder accepts loose phrasings ("123 Main St Knoxville",
"the house on Pine Lane"). Stored device-local + iCloud (same as the
rest of your settings); never auto-populated.

**Sleep** — expected bedtime, typical sleep hours, "Use Apple Health Sleep
Data" (enable/disable sleep in recovery scoring), "HRV-Enhanced Watch Stages"
(refines Apple Watch sleep stages using chest strap HRV; catches deep sleep
the Watch misclassifies as core, REM twitches misidentified as awake, etc.
Applies retroactively. Without a Watch, HRV classification always runs.),
"Lower Score Without Sleep" (−10 penalty when sleep integration is enabled
but no HealthKit data is available), Combine Segments (Split Sleep) merge
window (default 4.5 hrs, 1–12 hrs in 0.5h steps), and session merge mode.

**Training** — Training Load Integration toggle; Training Break start/end
dates + reason (hides training metrics during sick days, vacation, surgery
recovery).

**Wearables** — Foot Pod pairing; Apple Health Export (master toggle + Export
SDNN / Heart Rate / Resting Heart Rate / Sleep Data sub-toggles); "Delete
Emuqu sleep samples from Apple Health." Sleep export writes one
sample per stage interval (deep, core, REM, awake) plus an overall in-bed
sample; retroactive on toggle-on.

**Baselines** (read-only, surfaced in the Biometrics footer): personal
baseline and population baseline values.

### Appearance
- **Background Theme**: Light / Dim / Dark — choose your preferred look with a color preview for each option
- **Color Theme**: Blue (default) / Teal / Indigo / Purple / Rose / Orange — sets the primary accent color throughout the app. Each theme has distinct light and dark mode variants.
- **Language**: System Default or choose from 17 languages — English, Danish, German, Spanish, Finnish, French, Icelandic, Italian, Japanese, Korean, Norwegian Bokmål, Dutch, Portuguese (Brazil), Russian, Swedish, Simplified Chinese, and Arabic. Switching takes effect immediately without restarting. On iOS 18.0+, dynamically generated text (analysis summaries, coaching messages) is translated on-device using Apple's Translation framework. Language packs download automatically when needed.

### Custom Tags
- List of your custom tags with color indicators
- Swipe left to delete custom tags
- **"Add Custom Tag"** button opens creation sheet with name, 12-color grid, and live preview

### Flo (AI Assistant)

**Master toggle** (top of page): **Enable Flo**. When off, the Flo tab disappears from the bottom bar and the chat ViewModel + provider registry skip work at app launch. Off = literally no AI surface in the app.

**Connected Models** section:
- Each row shows a provider (Claude, ChatGPT, Gemini, Grok, DeepSeek) and whether a key is set ("Connected · key •••••wxyz" or "Not set up — tap to add a key").
- Tap to open a per-provider editor:
  - Paste your API key (use the right format — `sk-ant-...` for Claude, `sk-...` for OpenAI, `AIza...` for Gemini, etc.)
  - **Save key** / **Replace key** / **Remove key** buttons
  - Link to the vendor's privacy policy
  - Footer reminder that the key is sent only to that vendor when you select it

**On-Device** section:
- Apple Intelligence row showing availability ("Available" or "Unavailable on this device or iOS version").

**Routing** section (2026-05-05):
- Segmented picker: **Quick** / **Auto** / **Deep** / **Manual**
- A blurb beneath the picker describes the chosen mode:
  - *Quick — Fastest, free, private. Apple Intelligence on-device for every turn. May refuse complex multi-week analysis.*
  - *Auto — Session-sticky. Picks Apple for lookups + simple coaching, your paid provider for real reasoning. Tier persists once chosen.*
  - *Deep — Best quality. Every turn goes to your strongest configured cloud model. Slower (1–3s) and costlier.*
  - *Manual — Every turn goes to whatever you picked in the model picker. Full control.*
- Footer (always visible): *"Quick pins Apple Intelligence for every turn. Auto picks per session: Apple for lookups + simple coaching, your strongest paid model when reasoning is needed; tier persists once chosen so the conversation doesn't drift. Deep pins your strongest paid model for every turn. Manual sends every turn to whatever you picked above."*
- Contextual hint (only shown when you're in Auto / Deep / Quick AND no cloud provider key is set): *"No paid provider configured. Auto and Deep modes will run on Apple Intelligence — same as Quick. Add an API key above to unlock distinct tiers."*

**What the AI Remembers** section:
- List of stored facts (cross-session memory). Each shows the text and the date it was added.
- Swipe a fact to delete; tap **Forget everything** to wipe all.
- Type a fact in the input row and tap + to add manually (e.g., "I'm prepping for a marathon").
- **Auto-remember things** toggle — when on, the assistant runs a background extraction pass after every response and adds new facts automatically. Free on Apple Intelligence; ~fraction of a cent per turn on connected models. **Off by default.**

**Disclosure** section: standard reminder that AI responses are coaching, not medical advice; that connected models receive your data per their privacy policy; that Emuqu does not control or moderate responses.

API keys are stored in the iOS Keychain on this device only — they are never synced to iCloud and are sent only to the corresponding provider when you actively chat with it.

### iCloud & Data
- **iCloud Sync**: Toggle automatic CloudKit backup (on by default)
- **Sync Status**: Current state (idle / syncing / error) and last sync time
- **Import RR Data**: Import RR interval data from other apps and devices. Supported formats:
  - **CSV** — Comma-separated RR intervals (auto-detects milliseconds vs seconds)
  - **JSON** — Array of RR interval values
  - **TXT** — Plain text, one interval per line
  - **Kubios** — Export files from Kubios HRV software
  - **EliteHRV** — Summary CSV exports with pre-computed metrics (batch import of multiple sessions)
  - Minimum 60 RR intervals required; values must be in the 200-2500ms physiological range
- **Export Data**: Opens export options view with three formats:
  - **Export RR Intervals (CSV)** — Raw RR data with timestamps
  - **Export Summary (CSV)** — Session summaries with date, type, score, RMSSD, tags, notes
  - **Export All Sessions (JSON)** — Complete session data including analysis results
- **Recover RR from Strap**: Downloads missed data from your Polar device (only when connected)
- **Recover Lost Sessions**: Find sessions from backup that aren't in the archive
- **Trash**: View and restore deleted sessions (kept for 90 days)

### Troubleshooting
- **Recent Errors**: Shows recent error log with count badge
- **Export Diagnostic Log**: Share the full debug log for support
- **Reanalyze All Sessions**: Re-runs the current analysis algorithm on all historical sessions. Useful after algorithm updates to get consistent scoring across your entire history.
- **Clear Actions**: Clear error log, clear crash report
- **Debug Mode Toggle**: When enabled, reveals advanced debug tools (archive diagnostics, repair, raw log viewer) inline. Always visible in DEBUG builds, toggle-gated in Release.

### Help & Support
- **Help Center**: Opens the searchable help article library (see [Help Center](#help-center) section below)
- **Metric Guide**: Age-personalized metric education covering time domain (RMSSD, SDNN, pNN50), frequency domain (LF, HF, LF/HF), nonlinear (SD1/SD2, DFA alpha-1), and composite metrics (Stress Index, Readiness)
- **Troubleshooting**: Error log viewer, crash reports, diagnostic log export, persistent logging toggle, reanalyze sessions (all or date range), debug mode toggle

### Purchase
- **Purchase Status**: Shows whether you own the app (checkmark) or links to the purchase screen
- **Paywall**: One-time lifetime purchase, **$9.99**, after a **30-day free trial**. The paywall shows feature highlights, pricing, and a "Restore Purchase" option for previous buyers. No subscriptions, no recurring charge.
- **Free trial**: Every new user can try everything free for 30 days. The trial starts when you tap **Start 30-Day Free Trial** on the paywall after onboarding, and it never charges you. Thirty days covers the 28 nights the recovery score needs, so you see a settled score before deciding. The daily reminder only appears in the last week. Deleting and reinstalling the app resumes the same trial rather than starting a new one.
- **Beta testers**: Anyone who ran a TestFlight build keeps permanent free access, on every device signed into that Apple ID, including after the app goes on sale.

### About
- **Version**: Current app version
- **Terms of Use**: Legal terms
- **Privacy Policy**: Privacy practices
- **Health Disclaimer**: Medical disclaimer

---

## Trash View

Manage deleted sessions.

### When Empty
- "Trash is Empty" message
- "Deleted sessions will appear here for recovery"

### With Deleted Sessions
- List showing each deleted session:
  - Date and time
  - Beat count
  - **Restore button** (green arrow): Recovers and re-analyzes the session
  - **Permanent delete button** (red X): Removes from trash
- Footer: "Deleted sessions are kept until permanently removed or until backups are purged (90 days)"
- **"Permanently Delete All"** button with confirmation dialog

---

## Lost Sessions View

Recover sessions that have raw backups but aren't in the main archive.

### Features
- List of lost sessions with date, beat count, duration estimate
- **"Recover All"** button to batch recover
- **Edit mode** with multi-select for batch deletion
- **Swipe to delete** individual sessions
- Confirmation dialog before deletion

---

## HRV Metrics Explained

### Time Domain Metrics
| Metric | Description | Good Values |
|--------|-------------|-------------|
| **RMSSD** | Root Mean Square of Successive Differences. Primary HRV metric indicating parasympathetic activity. Higher = better recovery. | 40-100+ ms (age-dependent) |
| **SDNN** | Standard Deviation of NN intervals. Overall variability measure. | 50-100+ ms |
| **pNN50** | Percentage of successive intervals differing >50ms. | >20% |
| **Mean HR** | Average heart rate during analysis window. | Varies by fitness |
| **Min/Max HR** | Lowest and highest heart rate during recording. | -- |

### Frequency Domain Metrics
| Metric | Description |
|--------|-------------|
| **LF Power** | Low Frequency power (0.04-0.15 Hz). Mix of sympathetic and parasympathetic activity. |
| **HF Power** | High Frequency power (0.15-0.4 Hz). Primarily parasympathetic (vagal) activity. |
| **LF/HF Ratio** | Balance between sympathetic and parasympathetic. Lower generally indicates better recovery. |

### Nonlinear Metrics
| Metric | Description |
|--------|-------------|
| **SD1** | Short-term HRV from Poincaré plot. Reflects beat-to-beat variability. |
| **SD2** | Long-term HRV from Poincaré plot. Reflects overall variability. |
| **DFA α1** | Detrended Fluctuation Analysis. Values 0.75-1.0 suggest healthy complexity. |

### Composite Metrics
| Metric | Description |
|--------|-------------|
| **Stress Index** | Baevsky's stress index. Lower values indicate less physiological stress. |
| **Readiness Score** | Training readiness on a 0-10 scale. Measures capacity to absorb additional training load based on fitness-fatigue dynamics (CTL/ATL capacity ratio, today's strain, recent-load-vs-usual-range). Independent of the recovery score. |
| **Recovery Score** | Evidence-based 0-100 score from HRV (60%) + Sleep (25%) + Vitals (15%) with ln(RMSSD) z-score normalization against your personal 60-day baseline. Comeback mode shifts to HRV 80% / Sleep 20% / Vitals 0% for 21 days post illness/injury. Three-tier system adapts to available data; training load is not in the score (lives on the parallel Load & Trajectory page). |
| **Comeback mode** | 21-day recovery-weighting toggle for users returning from illness or injury. Settings → Training → "I'm coming back from illness or injury." Auto-expires after 21 days. |

---

## Tips for Best Results

### General
1. **Consistency**: Take readings at the same time each day
2. **Morning readings**: Best done immediately after waking, before getting up
3. **Stay still**: Minimize movement during recording
4. **Relax**: Breathe normally, don't stress about the measurement

### Device Setup

**Polar H10 (Chest Strap):**
1. **Electrode contact**: Moisten the electrode pads before putting on the strap
2. **Strap fit**: Snug but comfortable, just below chest muscles
3. **Battery**: Keep H10 charged (app shows battery level when connected)
4. **Range**: Keep phone within Bluetooth range (a few meters)

**Polar Verity Sense (Optical Sensor):**
1. **Arm band fit**: Wear snugly on your forearm or upper arm
2. **Skin contact**: Ensure the optical sensor sits flat against skin
3. **Power**: Press the button to turn on before connecting

### Extended Recording
1. **Before bed**: Start recording after you're already in bed
2. **Phone placement**: Keep within Bluetooth range but doesn't need to be right next to you
3. **App open**: The app uses silent audio to stay active — the screen locks normally
4. **Morning**: Tap "Get Reading" when you're ready to analyze
5. **Split sleep**: If you wake in the middle of the night, tap Pause instead of stopping. Your data is saved immediately. Resume when you go back to sleep — both segments' HRV data is combined for a single analysis that finds the best recovery window across the full night. Even if you stop and start a new session instead of pausing, the app detects same-night sessions and combines them automatically. Adjust the merge window in Settings → Profile &amp; Health → Sleep → Combine Segments (Split Sleep).
6. **Partial nights**: If you stop the recording mid-night and go back to sleep, the app will update sleep data from HealthKit when you view the session later
7. **Going back to sleep**: If you accept your morning reading but go back to sleep (without your strap), the dashboard automatically detects the additional sleep from your Apple Watch's heart rate data and adds it to your total. Just open the app when you're done sleeping — no action needed.

### Building Your Baseline
- Record for 2+ weeks to establish your personal baseline
- Morning readings are most consistent for baseline calculation
- The app learns your normal patterns over time

---

## Troubleshooting

### Connection Issues
- **H10 won't connect**: Moisten electrodes, check battery, move phone closer. H10 requires skin contact to power on.
- **Verity Sense won't connect**: Make sure it's powered on (press button)
- **Disconnects during recording**: Check strap/band fit, ensure electrodes are moist (H10)
- **No devices found**: H10 must be worn; Verity Sense must be turned on
- **Removing a device**: Long press or swipe left on a known device to remove it

### Poor Signal Quality
- High artifact percentage indicates poor signal
- Solutions: Adjust strap position, add moisture, check strap condition

### Missing Overnight Data
- Ensure app stayed open overnight (check battery settings)
- If app was killed, use "Recover RR from Strap" option in Settings > Data
- Check "Recover Lost Sessions" for backup recovery

### Sessions Missing from History
- Check "Recover Lost Sessions" in Settings > Data
- Check "Trash" for accidentally deleted sessions
- Sessions in trash are kept for 90 days

### HealthKit Data Not Showing
- Grant HealthKit permissions when prompted
- Check Settings > Privacy > Health > Emuqu
- Sleep stages from HealthKit require Apple Watch or compatible sleep tracker. Without a Watch, the app classifies sleep stages directly from chest strap HRV data during overnight recordings.

---

## Privacy & Data

- All HRV data is stored locally on your device
- Optional iCloud sync backs up session data to your private CloudKit container — no third-party servers involved
- Raw RR interval backups are stored in the App Group container (survives app reinstalls)
- HealthKit data access requires explicit permission
- Export options available for backup and data portability
