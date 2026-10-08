# Independent validation of Emuqu's beat-interval methods against PhysioNet recordings

**Code under test:** Emuqu commit `e028039` (all Swift files cited below are read at that commit).
**Validation code:** `Tools/validation/` (Python 3 ports plus scripts). Run with `python3 -I`; see "Reproducing" at the end.
**Data:** PhysioNet open-data mirror (`physionet-open.s3.amazonaws.com`). Versions used: slpdb 1.0.0, capslpdb 1.0.0, mitdb 1.0.0, nsr2db 1.0.0.
**Date of run:** 2026-10-08.

No Swift toolchain was available, so every method was re-implemented in Python by reading the Swift source line by line. A port's results are reported as the app's only after the port reproduced the app's own unit-test expectations (Section 0). All six port modules passed. One Swift doc comment quotes a stale number; Section 0 explains it.

---

## 0. Port fidelity: the app's unit tests, re-run against the Python ports

| Port module | Swift source @ e028039 |
|---|---|
| `port_dfa.py` | `Analysis/DFAAnalysis.swift`, `Utilities/Statistics.swift` (`linearRegression`) |
| `port_frequency_domain.py` | `Analysis/FrequencyDomainAnalysis.swift` |
| `port_sleep_stage_classifier.py` | `Analysis/HRVSleepStageClassifier.swift`, `HRVSleepStageClassifier+Watch.swift` (smoothing and intervals only), `SleepBoundaryResolver.swift` (`RRWindowSweep`), `Utilities/Constants+SleepAndDisplay.swift` |
| `port_artifact_detection.py` | `Analysis/ArtifactDetection.swift` |
| `port_live_dfa_clean.py` | `Analysis/LiveDFAAnalyzer.swift` (`cleanRRForDFA` and its thresholds) |
| `port_time_domain.py` | `Analysis/TimeDomainAnalysis.swift` (`computeTimeDomain` RMSSD/SDNN/pNN50 path, ectopic keep-mask, recording breaks) |

| Swift test suite (EmuquTests @ e028039) | Cases reproduced | Cases matched |
|---|---:|---:|
| DFAAnalysisTests | 15 | 15 |
| DFAReferenceValidationTests | 9 | 9 |
| FrequencyDomainTests | 18 | 18 |
| HRVSleepStageClassifierTests | 28 | 28 |
| ArtifactDetectionTests | 8 | 8 |
| LiveDFAAnalyzerTests | 19 | 19 |
| TimeDomainTests | 10 | 10 |
| HRVReferenceValidationTests | 7 | 7 |

`test_ports.py` re-implements every test case listed above. The counts include three extra checks that are not Swift tests: the quoted DFA values, the scipy Welch cross-check and the stale nsr005 comment value, each marked in the output. `ArtifactDetectionTests.testCleanBeatsDetection` uses unseeded `Int.random`, so it was run over 200 Python seeds; the worst case was still 100 % clean. The full per-case output is in `test_ports_output.txt`. Where a test uses a seeded generator, the generator is reproduced bit for bit: `SplitMix64`, Swift's `Double.random(in:using:)` with Lemire's `next(upperBound:)`, and the classifier test's LCG. As a result the checks go beyond the assertion tolerances:

- DFA α1 on the three reference processes is **0.581 / 1.088 / 1.526**. These are exactly the values the Swift doc comment in `DFAReferenceValidationTests` records as measured.
- `testBuildFeatureWindowsRMSSDParityExact` gives 64.25396041156863 and `testRMSSDParityExact` gives 35.276684147527874. Both are the expected doubles.
- On the 20 nsr2db fixture records (6,000 intervals), mean RR and SDNN match the stored references to ≤ 4.9 × 10⁻⁷ ms.
- As an extra check, the Welch PSD port equals `scipy.signal.welch` (Hann, 256/128, linear detrend) to within 10⁻⁶ relative.

**Mismatch found, and why it is not a port error.** A doc comment in `HRVReferenceValidationTests` says nsr005's pipeline RMSSD is "16.03 against 28.98". The port gives 15.96 against 28.98. The port reproduces 16.03 exactly under the rule in force before commit `5c4a23d` (2026-10-04): drop gated beats, then difference the collapsed array. At `e028039` the rule takes differences only between beats that are adjacent in the original series. So the comment is stale and the port follows the code. The test's actual assertions pass.

**Not reproduced (outside the ported scope):**
- `SleepStageAugmentationTests`: the Apple Watch augmentation path, deliberately not ported.
- The two stateful `@MainActor` tests in `LiveDFAAnalyzerTests` (window-fill gating) and `LiveDFAAnalyzerStreamTests`: the streaming analyzer object is not ported, only `cleanRRForDFA` plus `DFAAnalyzer.compute`.
- HR-statistics tests in `TimeDomainTests` (`testMeanRRAndHR` and the two stored-HR tests).
- `RMSSDEstimatorTests` (`rmssd(fromRRs:isValid:)` / peak scan).
- Pipeline and integration suites.

None of these code paths is used in the results below.

**Known numeric differences from the device build:**
- Accelerate's `vDSP_meanvD`/`vDSP_dotprD` may sum in a different order from numpy. This affects only the last bits.
- `vDSP_DFT` is replaced by `numpy.fft.fft`, with the same unscaled forward transform.

---

## 1. RR-only sleep staging (`HRVSleepStageClassifier.classify`) vs polysomnography

### Method

**Data.**
- *slpdb* (primary): 18 records from 16 subjects. RR intervals come from the `.ecg` beat annotations. Only intervals between two consecutive normal beats (N, L, R, e, j) are kept, as app-style `(t_ms, rr_ms)` points with `t_ms` set to the first beat's time. An interval touching a non-normal beat is omitted, which the app sees as a short gap. Reference stages are the first token of the `.st` aux notes for 30-s epochs. A sensitivity analysis uses all consecutive beats instead ("all-beat RR"), the way a chest strap would deliver them.
- *CAP* (secondary): the 16 healthy controls n1–n16. n16 has no ECG channel and was excluded, leaving 15. R peaks were detected on the EDF ECG channel (sampled at 100–512 Hz depending on the record) with wfdb-python 4.3.1 `XQRS`. Detection ran at 250 Hz in 5-min chunks, and each peak was refined to the largest band-passed sample within ±50 ms at native rate. Every detected beat was used. Reference stages come from the RemLogic hypnograms.

**Running the classifier.**
- The ported classifier runs once per record on its RR-only path. It does not use Watch data.
- `sleepStartMs` is the start of the first scored 30-s epoch and `sleepEndMs` is the end of the last. This is the "whole scored recording", from lights-out to the end of the recording. It mimics the app's fallback of using recording boundaries.
- A second variant restricts the input to the PSG sleep period, from the first to the last non-wake epoch. This mimics the app receiving correct onset and wake times.

**Stage mapping and scoring.**
- Reference stages map to four classes: W→Wake, 1+2→Core, 3+4→Deep, R→REM. MT and unscored epochs are excluded.
- Each 5-min classifier window spans exactly ten 30-s reference epochs. Its reference label is the majority of those ten. Ties go to the tied class that occurs first. A window needs ≥ 5 scorable epochs to be scored.
- At 30-s resolution, every scorable epoch inherits its window's app label.
- Windows the classifier drops for too few beats are not scored. Coverage is shown per record.

**Statistics.** Accuracy, Cohen's κ, the confusion matrix and per-class sensitivity and precision are computed pooled over all epochs. Per-record values are also given. Stage minutes are those the app reports, the per-interval truncated minutes from `summarise`. They are compared with PSG minutes (30-s epochs × 0.5) by Bland–Altman, with bias ± 1.96 SD and n = records.

### Results

**Table 1a. Agreement with PSG, pooled.**

| Dataset / variant | Records classified | 5-min epochs | Accuracy | Cohen's κ | 30-s epochs | Accuracy | Cohen's κ | Majority-class accuracy (5-min) |
|---|---:|---:|---:|---:|---:|---:|---:|---:|
| slpdb, NN RR, whole scored recording (primary) | 18/18 | 1018 | 38.8 % | 0.072 | 10171 | 37.5 % | 0.069 | 58.8 % |
| slpdb, NN RR, PSG sleep period only | 18/18 | 973 | 41.9 % | 0.087 | 9713 | 40.4 % | 0.081 | 61.5 % |
| slpdb, all-beat RR, whole recording | 18/18 | 1018 | 38.9 % | 0.075 | 10171 | 37.3 % | 0.068 | 58.8 % |
| slpdb, all-beat RR, PSG sleep period only | 18/18 | 973 | 40.8 % | 0.083 | 9713 | 39.0 % | 0.072 | 61.5 % |
| CAP n1–n16 (ECG available), detected beats, whole recording | 15/15 | 1505 | 41.7 % | 0.146 | 14920 | 42.1 % | 0.153 | 43.3 % |
| CAP n1–n16 (ECG available), detected beats, PSG sleep period only | 15/15 | 1435 | 42.4 % | 0.142 | 14228 | 42.6 % | 0.145 | 45.6 % |

Per-record 5-min κ (mean ± SD): slpdb 0.037 ± 0.155; CAP 0.144 ± 0.112.

**Table 1b. slpdb primary analysis, pooled, 5-min epochs** (rows = PSG reference, columns = app; counts)

| Reference \ App | Wake | Core | Deep | REM | Total |
|---|---:|---:|---:|---:|---:|
| Wake | 41 | 147 | 45 | 50 | 283 |
| Core (N1+N2) | 8 | 300 | 228 | 63 | 599 |
| Deep (N3/S3+S4) | 0 | 28 | 35 | 2 | 65 |
| REM | 4 | 39 | 9 | 19 | 71 |
| Total | 53 | 514 | 317 | 134 | 1018 |

**Table 1c. slpdb primary analysis, pooled, 30-s epochs (5-min app label upsampled)** (rows = PSG reference, columns = app; counts)

| Reference \ App | Wake | Core | Deep | REM | Total |
|---|---:|---:|---:|---:|---:|
| Wake | 399 | 1623 | 565 | 518 | 3105 |
| Core (N1+N2) | 100 | 2848 | 2170 | 584 | 5702 |
| Deep (N3/S3+S4) | 4 | 282 | 353 | 25 | 664 |
| REM | 31 | 374 | 84 | 211 | 700 |
| Total | 534 | 5127 | 3172 | 1338 | 10171 |

**Table 1d. Per-class sensitivity and precision.**

| Dataset / variant | Resolution | Wake sens. | Wake prec. | Core (N1+N2) sens. | Core (N1+N2) prec. | Deep (N3/S3+S4) sens. | Deep (N3/S3+S4) prec. | REM sens. | REM prec. |
|---|---|---:|---:|---:|---:|---:|---:|---:|---:|
| slpdb, NN RR, whole scored recording (primary) | 5 min | 14.5 % | 77.4 % | 50.1 % | 58.4 % | 53.8 % | 11.0 % | 26.8 % | 14.2 % |
| slpdb, NN RR, whole scored recording (primary) | 30 s | 12.9 % | 74.7 % | 49.9 % | 55.5 % | 53.2 % | 11.1 % | 30.1 % | 15.8 % |
| slpdb, NN RR, PSG sleep period only | 5 min | 15.1 % | 69.2 % | 53.8 % | 63.1 % | 43.5 % | 9.5 % | 31.1 % | 18.0 % |
| slpdb, NN RR, PSG sleep period only | 30 s | 13.5 % | 68.3 % | 53.6 % | 60.1 % | 41.9 % | 9.8 % | 33.0 % | 18.1 % |
| CAP n1–n16 (ECG available), detected beats, whole recording | 5 min | 4.3 % | 11.3 % | 45.5 % | 45.1 % | 48.0 % | 40.1 % | 43.2 % | 42.1 % |
| CAP n1–n16 (ECG available), detected beats, whole recording | 30 s | 4.6 % | 12.8 % | 45.9 % | 45.6 % | 49.0 % | 40.6 % | 43.8 % | 41.9 % |
| CAP n1–n16 (ECG available), detected beats, PSG sleep period only | 5 min | 6.8 % | 7.1 % | 45.2 % | 47.2 % | 46.2 % | 40.5 % | 40.9 % | 43.3 % |
| CAP n1–n16 (ECG available), detected beats, PSG sleep period only | 30 s | 7.2 % | 7.9 % | 45.5 % | 47.3 % | 46.6 % | 40.8 % | 40.9 % | 43.2 % |

**Table 1e. Stage minutes, app vs PSG (Bland–Altman; n = records).**

| Dataset / variant | Quantity | n records | Mean PSG (min) | Mean app (min) | Bias app − PSG (min) | 95 % limits of agreement (min) |
|---|---|---:|---:|---:|---:|---|
| slpdb, NN RR, whole scored recording (primary) | Total sleep time | 18 | 196.3 | 268.1 | 71.8 | -31.1 to 174.7 |
| slpdb, NN RR, whole scored recording (primary) | Deep minutes | 18 | 18.4 | 88.2 | 69.7 | 3.8 to 135.7 |
| slpdb, NN RR, whole scored recording (primary) | REM minutes | 18 | 19.4 | 37.2 | 17.8 | -36.5 to 72.0 |
| slpdb, NN RR, PSG sleep period only | Total sleep time | 18 | 196.3 | 255.5 | 59.2 | -30.3 to 148.7 |
| slpdb, NN RR, PSG sleep period only | Deep minutes | 18 | 18.4 | 78.6 | 60.2 | 0.4 to 119.9 |
| slpdb, NN RR, PSG sleep period only | REM minutes | 18 | 19.4 | 35.4 | 15.9 | -37.7 to 69.6 |
| CAP n1–n16 (ECG available), detected beats, whole recording | Total sleep time | 15 | 448.6 | 483.4 | 34.8 | -48.2 to 117.8 |
| CAP n1–n16 (ECG available), detected beats, whole recording | Deep minutes | 15 | 120.1 | 146.1 | 26.0 | -51.7 to 103.7 |
| CAP n1–n16 (ECG available), detected beats, whole recording | REM minutes | 15 | 112.6 | 118.5 | 5.9 | -86.0 to 97.9 |
| CAP n1–n16 (ECG available), detected beats, PSG sleep period only | Total sleep time | 15 | 448.6 | 454.6 | 6.0 | -62.1 to 74.0 |
| CAP n1–n16 (ECG available), detected beats, PSG sleep period only | Deep minutes | 15 | 120.1 | 138.1 | 18.0 | -71.4 to 107.3 |
| CAP n1–n16 (ECG available), detected beats, PSG sleep period only | REM minutes | 15 | 112.6 | 107.5 | -5.1 | -92.8 to 82.6 |

**Table 1f. slpdb per record (primary analysis).**

| Record | Subject (age, sex) | PSG epochs scored | App 5-min windows | 5-min accuracy | 5-min κ | TST PSG / app (min) | Deep PSG / app | REM PSG / app |
|---|---|---:|---:|---:|---:|---|---|---|
| slp01a | 44 M | 239 | 24 | 12 % | -0.51 | 116 / 110 | 56 / 35 | 6 / 0 |
| slp01b | 44 M | 360 | 36 | 25 % | 0.04 | 90 / 165 | 0 / 80 | 12 / 20 |
| slp02a | 38 M | 352 | 36 | 39 % | 0.04 | 154 / 170 | 4 / 50 | 38 / 35 |
| slp02b | 38 M | 269 | 27 | 19 % | 0.08 | 81 / 115 | 0 / 80 | 14 / 25 |
| slp03 | 51 M | 720 | 71 | 52 % | 0.24 | 284 / 315 | 39 / 125 | 37 / 10 |
| slp04 | 40 M | 720 | 72 | 40 % | -0.02 | 279 / 345 | 16 / 95 | 12 / 60 |
| slp14 | 37 M | 713 | 72 | 39 % | 0.11 | 196 / 357 | 21 / 92 | 18 / 50 |
| slp16 | 35 M | 694 | 70 | 29 % | 0.06 | 189 / 332 | 12 / 105 | 32 / 75 |
| slp32 | 54 M | 640 | 64 | 22 % | 0.00 | 123 / 305 | 30 / 95 | 0 / 40 |
| slp37 | 39 M | 698 | 70 | 51 % | -0.01 | 312 / 344 | 0 / 90 | 6 / 55 |
| slp41 | 45 M | 780 | 78 | 45 % | 0.15 | 276 / 365 | 6 / 130 | 45 / 35 |
| slp45 | 42 M | 756 | 76 | 41 % | 0.20 | 318 / 365 | 52 / 135 | 40 / 120 |
| slp48 | 56 M | 759 | 76 | 46 % | -0.02 | 273 / 380 | 1 / 100 | 16 / 20 |
| slp59 | 41 M | 458 | 46 | 35 % | 0.05 | 159 / 224 | 40 / 80 | 18 / 30 |
| slp60 | 49 M | 710 | 71 | 37 % | 0.04 | 212 / 330 | 0 / 105 | 16 / 25 |
| slp61 | 32 M | 720 | 72 | 46 % | 0.14 | 298 / 330 | 52 / 120 | 40 / 25 |
| slp66 | 33 M | 439 | 44 | 43 % | 0.10 | 132 / 204 | 2 / 45 | 0 / 40 |
| slp67x | x M | 154 | 16 | 33 % | -0.02 | 41 / 70 | 0 / 25 | 0 / 5 |

**Table 1g. CAP healthy controls, pooled, 5-min epochs** (rows = PSG reference, columns = app; counts)

| Reference \ App | Wake | Core | Deep | REM | Total |
|---|---:|---:|---:|---:|---:|
| Wake | 6 | 74 | 31 | 29 | 140 |
| Core (N1+N2) | 9 | 296 | 199 | 147 | 651 |
| Deep (N3/S3+S4) | 3 | 158 | 176 | 30 | 367 |
| REM | 35 | 129 | 33 | 150 | 347 |
| Total | 53 | 657 | 439 | 356 | 1505 |

**Table 1h. CAP healthy controls per record.**

| Record | Subject (age, sex) | PSG epochs scored | App 5-min windows | 5-min accuracy | 5-min κ | TST PSG / app (min) | Deep PSG / app | REM PSG / app |
|---|---|---:|---:|---:|---:|---|---|---|
| n1 |  | 1140 | 115 | 45 % | 0.17 | 550 / 568 | 160 / 160 | 120 / 175 |
| n2 |  | 999 | 100 | 50 % | 0.26 | 428 / 495 | 98 / 155 | 76 / 120 |
| n3 |  | 999 | 101 | 36 % | 0.05 | 432 / 485 | 140 / 110 | 94 / 95 |
| n4 |  | 979 | 102 | 34 % | 0.02 | 378 / 500 | 70 / 130 | 99 / 75 |
| n5 |  | 1007 | 101 | 44 % | 0.18 | 498 / 489 | 152 / 174 | 116 / 185 |
| n6 |  | 1030 | 104 | 32 % | -0.11 | 486 / 510 | 103 / 105 | 132 / 80 |
| n7 |  | 974 | 99 | 51 % | 0.25 | 454 / 477 | 122 / 107 | 124 / 120 |
| n8 |  | 992 | 101 | 38 % | 0.13 | 433 / 500 | 112 / 150 | 98 / 190 |
| n9 |  | 1020 | 103 | 45 % | 0.15 | 451 / 494 | 88 / 144 | 113 / 80 |
| n10 |  | 852 | 86 | 34 % | 0.05 | 393 / 395 | 154 / 155 | 108 / 55 |
| n11 |  | 1051 | 106 | 43 % | 0.18 | 498 / 521 | 172 / 141 | 190 / 160 |
| n12 |  | 984 | 99 | 44 % | 0.22 | 476 / 450 | 114 / 185 | 148 / 110 |
| n13 |  | 952 | 97 | 47 % | 0.26 | 379 / 465 | 70 / 155 | 90 / 105 |
| n14 |  | 965 | 97 | 49 % | 0.30 | 404 / 464 | 138 / 135 | 82 / 140 |
| n15 |  | 976 | 98 | 34 % | 0.05 | 468 / 438 | 109 / 185 | 99 / 88 |

### Interpretation

**slpdb: no agreement beyond chance.** On slpdb the RR-only classifier does not agree with polysomnography beyond chance:
- Pooled 5-min κ = 0.072 over 1,018 epochs from 18 records. Per-record κ is 0.04 ± 0.16.
- Accuracy is 38.8 %, below the 58.8 % that labelling every epoch "Core" would score.

**CAP healthy controls: slight agreement.**
- Pooled κ = 0.146 over 1,505 epochs from 15 records.
- Accuracy is 41.7 %, against 43.3 % for the majority class.

**These conclusions are robust to the analysis choices.**
- The 30-s analysis gives the same picture.
- κ changes by ≤ 0.02 when all beats are used instead of normal-to-normal intervals. Ectopic beats therefore do not explain the result.
- κ also changes by ≤ 0.02 when the classifier is given the true PSG sleep period. Boundary choice does not explain it either.

**The errors follow from the design.**
1. **Deep sleep is assigned by within-night rank.** The thresholds apply to within-night ranks plus a time-of-night prior, so every night gets a deep share regardless of how much N3 it contains.
   - On slpdb the app labelled 31 % of windows Deep, against 6.4 % on PSG. Deep precision was 11 %.
   - Nights with no PSG deep sleep at all still received 80–105 deep minutes: slp01b, slp02b, slp37 and slp60.
   - Deep minutes are over-reported by +70 min on slpdb (LoA 4 to 136) and +26 min on CAP (LoA −52 to 104).
2. **Wake is almost never called.** The awake score rarely exceeds its 0.80 threshold. Wake sensitivity was 13–15 % on slpdb and 4–7 % on CAP.
   - Total sleep time is therefore over-reported whenever the input contains wake: +72 min on slpdb whole recordings and +35 min on CAP.
   - The bias falls to +6 min on CAP once the input is limited to the true sleep period, which is the boundaries' job, not the classifier's.
3. **REM is weakly identified.** REM sensitivity / precision was 27 % / 14 % on slpdb and 43 % / 42 % on CAP. REM-minute limits of agreement span roughly ±55 min (slpdb) and ±90 min (CAP).

**Implications for the white paper.**
- The register's status for `hrv-sleep-staging` is "awaiting-validation", with accuracy "unmeasured". It is now measured, and on these data it is near chance.
- The per-stage minutes should not be presented as measurements of deep or REM sleep.
- For comparison, quote the κ that the cardiac-staging studies cited in white paper 1 report for their own methods. We did not re-verify those figures here.

### Limitations specific to this analysis

- **slpdb population.** Subjects were referred for evaluation of obstructive sleep apnea and are almost all male, aged 32–56. Apneic events and arousals modulate heart rate, so slpdb is a hard test of cardiac staging. Several records are short: slp01a is 2 h, slp67x 1.3 h, and slp01a/b and slp02a/b are halves of one night each.
- **R&K scoring.** slpdb and CAP were scored with Rechtschaffen & Kales rules (S3+S4) rather than AASM N3. They were not re-scored.
- **CAP beats are detected, not annotated.** The detector's accuracy on these records was not measured, because there are no reference beat annotations. 0.02–3.7 % of detected RR fell outside 300–2000 ms. Several CAP ECGs are sampled at 100–128 Hz, which quantises RR to 8–10 ms.
- **Ports, not the app binary.** The app was not run. The comparison assumes the port is faithful (Section 0). It also assumes the app would receive the same RR series. The app's real input is a Polar-class strap and its own boundary resolution.
- **The Watch augmentation path, which production uses when Watch stages exist, was not evaluated.**

---

## 2. Artifact and ectopic detection vs MIT-BIH Arrhythmia Database beat labels

### Method

**Data.** mitdb 1.0.0. The paced records 102, 104, 107 and 217 are excluded (AAMI convention). That leaves 44 records, 100,733 annotated beats, 10,593 ectopic.

**RR series.** The series is built like a strap's: every consecutive pair of annotated beats, with no beat removed.

**Beat labels.**
- Normal = N, L, R, e, j.
- Ectopic = A, a, J, S, V, E, F (B, r and n also count as ectopic but do not occur in these records).
- Q, ? and paced beats are "unknown". Intervals touching them are not scored, but they stay in the series.

**Methods tested.** The ported methods run on each record's whole series:
- `ArtifactDetector.detectArtifacts`;
- the `cleanRRForDFA` artifact mask, with its trailing-median state carried across the record;
- the full exclusion applied before overnight RMSSD, which is `ArtifactDetector` flags plus `computeTimeDomain`'s local ectopic gate applied within each 5-min segment.

**Scoring rules.** An ectopic beat at k shortens the interval ending at k and lengthens the one starting at k, so two rules are reported:
- **Interval rule (primary).** An interval is a true positive if either endpoint is ectopic and a true negative if both endpoints are normal. It counts as predicted positive if the method flags it.
- **Beat rule.** An ectopic beat counts as detected if either adjacent interval is flagged. A normal beat whose two adjacent intervals are both normal→normal is a false positive if either is flagged. Normal beats next to an ectopic beat are not scored.

**RMSSD comparison.** Each record is split into consecutive 5-min segments.
- The app value is `computeTimeDomain` over the segment, using whole-record `ArtifactDetector` flags, as the overnight pipeline does.
- The reference is the RMSSD of differences between consecutive normal→normal intervals, i.e. runs of three consecutive normal beats, within the segment. A segment needs ≥ 30 reference differences.
- "No correction" is RMSSD over all successive differences.
- Bland–Altman statistics are reported in ms and also on the log scale as ratio bias and ratio LoA, because the error is strongly heteroscedastic.
- Rhythm at the segment midpoint comes from the `+` rhythm annotations. AF and flutter segments are reported separately.

### Results

**Table 2a. Flagging ectopic beats (pooled over records).**

| Method (port) | Scoring rule | Sensitivity | Specificity | PPV | TP | FN | FP | TN |
|---|---|---:|---:|---:|---:|---:|---:|---:|
| ArtifactDetector.detectArtifacts (whole series) | interval | 57.5 % | 94.9 % | 71.3 % | 10447 | 7725 | 4201 | 78289 |
| ArtifactDetector.detectArtifacts (whole series) | beat | 67.5 % | 92.6 % | 55.3 % | 7147 | 3441 | 5783 | 72340 |
| LiveDFAAnalyzer.cleanRRForDFA mask | interval | 54.9 % | 86.8 % | 47.8 % | 9969 | 8203 | 10901 | 71589 |
| LiveDFAAnalyzer.cleanRRForDFA mask | beat | 71.6 % | 85.4 % | 39.9 % | 7576 | 3012 | 11432 | 66691 |
| Overnight RMSSD exclusion (ArtifactDetector + 5-min ectopic gate) | interval | 59.8 % | 94.3 % | 69.7 % | 10873 | 7299 | 4727 | 77763 |
| Overnight RMSSD exclusion (ArtifactDetector + 5-min ectopic gate) | beat | 69.4 % | 91.8 % | 53.3 % | 7353 | 3235 | 6435 | 71688 |

**Table 2b. Beat-rule sensitivity by ectopic beat type.**

| Ectopic annotation | Beats | ArtifactDetector.detectArtifacts | LiveDFAAnalyzer.cleanRRForDFA mask | Overnight RMSSD exclusion |
|---|---:|---:|---:|---:|
| A | 2544 | 40.2 % | 51.6 % | 41.2 % |
| E | 106 | 10.4 % | 11.3 % | 10.4 % |
| F | 802 | 25.2 % | 24.9 % | 26.3 % |
| J | 83 | 30.1 % | 15.7 % | 30.1 % |
| S | 2 | 50.0 % | 50.0 % | 50.0 % |
| V | 6901 | 83.2 % | 85.4 % | 85.6 % |
| a | 150 | 98.0 % | 96.0 % | 99.3 % |

**Table 2c. 5-min RMSSD, app pipeline vs normal-to-normal reference (bias = app − reference).**

| Segments | n segments (records) | Median ref RMSSD (ms) | App bias (ms) | App 95 % LoA (ms) | App ratio bias [95 % LoA] | App median abs. error (ms) | App within ±10 % | No-correction bias (ms) | No-correction ratio bias [95 % LoA] | No-correction within ±10 % |
|---|---:|---:|---:|---|---|---:|---:|---:|---|---:|
| All segments | 255 (43) | 35.8 | -21.6 | -202.3 to 159.0 | 0.93 [0.33, 2.62] | 4.7 | 51 % | 111.8 | 2.16 [0.40, 11.57] | 33 % |
| Excluding AF/flutter segments | 226 (40) | 32.4 | -8.6 | -178.2 to 161.1 | 1.03 [0.43, 2.51] | 3.2 | 58 % | 119.9 | 2.32 [0.41, 13.10] | 34 % |
| … with no ectopic beat | 71 (17) | 32.5 | -5.8 | -36.3 to 24.6 | 0.93 [0.64, 1.35] | 0.0 | 83 % | 0.0 | 1.00 [1.00, 1.00] | 100 % |
| … with ≥ 1 ectopic beat | 155 (37) | 32.1 | -9.8 | -213.8 to 194.1 | 1.09 [0.39, 3.04] | 5.8 | 46 % | 174.9 | 3.41 [0.69, 16.86] | 3 % |
| … with ≥ 5 % ectopic beats | 81 (22) | 34.5 | -11.6 | -288.3 to 265.1 | 1.23 [0.35, 4.24] | 9.7 | 33 % | 297.3 | 5.26 [1.08, 25.63] | 1 % |

### Interpretation

**Ectopic-beat detection.**
- `ArtifactDetector` flags 57.5 % of the intervals an ectopic beat distorts, with 94.9 % specificity and 71 % PPV. By the beat rule it catches 67.5 % of ectopic beats.
- Detection depends strongly on prematurity. It catches 83 % of ventricular premature beats (V) and 98 % of aberrated APCs (a), but only 40 % of atrial premature beats (A), 25 % of fusion beats (F) and 10 % of ventricular escape beats (E).
- This is expected of a 20 % deviation rule against a 51-beat rolling median. A supraventricular beat less than 20 % premature is, by construction, not an artifact to this rule. In bigeminy or trigeminy the ectopic intervals pull the rolling median toward themselves.
- The 5-min ectopic gate used for reported RMSSD adds about 2 points of interval sensitivity.
- `cleanRRForDFA` (5-beat trailing median) has similar sensitivity but lower specificity, 86.8 %. On these resting recordings it also flags sinus variability.

**RMSSD.** Without correction, ectopy inflates 5-min RMSSD by a median of 32 ms (ratio bias 2.2). The app's pipeline brings the median absolute error to 4.7 ms over all segments and 3.2 ms outside AF/flutter. However, its limits of agreement stay wide (ratio 0.43–2.51 outside AF), for two reasons:
- **Missed ectopy.** Ectopic beats that escape detection leave large outliers. With ≥ 5 % ectopic beats only 33 % of segments are within ±10 % of the reference.
- **Over-removal.** In segments with no ectopic beat at all, the gate removes genuine sinus variability in a minority of segments. Bias is −5.8 ms with ratio LoA 0.64–1.35, and 83 % of segments are within ±10 %, where no correction would give 100 %.

**Bottom line.** The app's handling is much better than none on ectopic-laden data. It is not equivalent to excluding annotated non-normal beats.

### Limitations specific to this analysis

- mitdb is a selected arrhythmia population. It contains 30-min excerpts from 47 subjects, chosen to include rare and complex arrhythmias, so ectopic burden is far higher than in a typical user's night.
- The annotations mark beat morphology and origin, not signal artifacts. Missed or extra detections from a strap are therefore not tested here (Section 3 covers them synthetically).
- `cleanRRForDFA` is designed for exercise. Here it runs on resting Holter data across the whole record rather than per 120-s window, so its first three beats per window are judged differently than in the app.

---

## 3. Effect of artifact handling on DFA α1 (injected artifacts)

### Method

This experiment follows the design of Rogers et al. (2021): inject known artifacts into clean data at fixed rates, then compare α1 with and without correction.

**Clean windows.** Clean windows come from nsr2db 1.0.0 beat annotations. The annotations are at 128 Hz, which quantises RR to 7.8 ms. A window is non-overlapping and lasts 120 s, as `LiveDFAAnalyzer.windowSec` does. It qualifies when:
- every beat is annotated N;
- every RR is 300–2000 ms;
- the span is ≥ 118 s;
- `cleanRRForDFA` corrects nothing, so the clean reference is not itself altered by the corrector.

Up to 20 windows per record were taken, evenly spaced across the candidates: 1080 windows from 54 records (mean 153 intervals per window; clean-window α1 1.20 ± 0.28).

**Artifacts.** Artifacts were inserted at 1, 3, 6 and 10 % of the window's intervals, at random non-adjacent positions, with 3 seeded repetitions. Two types were used:
- *Ectopic*: a premature beat (interval −30 %) with full compensatory pause. Each event alters two intervals.
- *Missed beat*: two intervals merged into one.

**Comparisons.** α1 is computed by the ported `DFAAnalyzer.compute` (boxes 4–16).
- "No correction" runs DFA on the corrupted window.
- "App" runs `cleanRRForDFA` and then DFA, as `LiveDFAAnalyzer` and `WorkoutAlpha1Reanalyzer` do.
- The app also withholds α1 when the corrected fraction exceeds 6 %, so bias is reported separately for the windows the app would publish.

Error = α1(condition) − α1(clean window).

### Results

**Table 3a. α1 error by artifact type and rate.**

| Artifact type | Rate (events / intervals) | Trials | α1 bias, no correction [95 % LoA] | α1 bias, app cleanRRForDFA [95 % LoA] | MAE no corr. / app | Mean corrected fraction | Windows the app would publish (≤ 6 %) | α1 bias in published windows |
|---|---:|---:|---|---|---|---:|---:|---:|
| ectopic | 1 % | 3240 | -0.549 [-0.961, -0.137] | -0.005 [-0.145, +0.134] | 0.549 / 0.021 | 1.9 % | 100 % | -0.005 (n=3238) |
| ectopic | 3 % | 3240 | -0.771 [-1.198, -0.344] | -0.020 [-0.292, +0.252] | 0.771 / 0.061 | 5.9 % | 56 % | -0.051 (n=1817) |
| ectopic | 6 % | 3240 | -0.874 [-1.328, -0.421] | -0.030 [-0.397, +0.337] | 0.874 / 0.109 | 11.9 % | 0 % | n/a |
| ectopic | 10 % | 3240 | -0.936 [-1.412, -0.461] | -0.067 [-0.559, +0.424] | 0.936 / 0.175 | 19.7 % | 0 % | n/a |
| missed | 1 % | 3240 | -0.433 [-1.194, +0.327] | -0.008 [-0.225, +0.209] | 0.505 / 0.054 | 1.0 % | 100 % | -0.008 (n=3239) |
| missed | 3 % | 3240 | -0.590 [-1.152, -0.028] | -0.023 [-0.371, +0.324] | 0.598 / 0.097 | 3.1 % | 100 % | -0.023 (n=3230) |
| missed | 6 % | 3240 | -0.633 [-1.179, -0.086] | -0.054 [-0.527, +0.419] | 0.636 / 0.138 | 6.4 % | 12 % | -0.502 (n=391) |
| missed | 10 % | 3240 | -0.674 [-1.223, -0.125] | -0.088 [-0.675, +0.500] | 0.676 / 0.190 | 11.1 % | 0 % | n/a |

**False corrections on artifact-free windows.** Of 28,001 artifact-free 120-s windows (every beat annotated N, every RR 300–2000 ms), cleanRRForDFA corrected at least one interval in 6,042 (21.6 %). In those windows the median corrected fraction was 3.6 %; 55.8 % exceeded 3 % and 33.9 % exceeded 6 % (α1 withheld), i.e. 7.3 % of all artifact-free windows. Correction changed α1 in those windows by +0.041 (95 % LoA -0.262 to +0.344).

### Interpretation

**Uncorrected artifacts.** In these resting windows (clean α1 ≈ 1.2), artifacts lower α1 sharply even at 1 %: by −0.55 for ectopic beats and −0.43 for missed beats. Uncorrelated jumps push the exponent toward the white-noise value of 0.5.

**With the app's correction.**
- Bias falls to about −0.02 at rates up to 3 % and to −0.07 to −0.09 at 10 %.
- Precision degrades with rate. The 95 % LoA widen from about ±0.14 (1 % ectopic) to about ±0.5–0.6 (10 %).

**The 6 % rejection gate.**
- An ectopic event alters two intervals, so 3 % ectopic beats already reach about 6 % corrected. The app withheld α1 in 44 % of those windows and in all windows at ≥ 6 % ectopy. Missed beats up to 3 % were always published, with bias −0.02 (LoA −0.37 to +0.32).
- **Edge effect.** At 6 % missed beats, the 12 % of windows that passed the gate had a bias of −0.50. In exactly those windows the corrector had touched only about 91 % as many intervals as were corrupted, so uncorrected missed beats remained. A gate on the corrected fraction cannot see artifacts the corrector misses, and near the threshold it preferentially publishes under-corrected windows.

**False corrections.** On artifact-free resting windows the corrector is not neutral:
- 21.6 % had at least one interval "corrected".
- 7.3 % of all artifact-free windows would have α1 withheld.
- Where correction occurred, it moved α1 by +0.04 (LoA −0.26 to +0.34).

This comes from resting sinus arrhythmia exceeding 20 % against a 5-beat trailing median. During exercise, RR variability is smaller and the effect is probably smaller too, but this was not tested.

### Limitations specific to this analysis

- The data are resting and ambulatory 24-h Holter recordings with mean clean α1 ≈ 1.2, not exercise. The app uses α1 live during exercise, where α1 is lower (0.5–1.0) and RR variability is smaller, so both the artifact effect and the corrector's false-positive rate may differ there. Rogers et al. studied exercise data.
- The artifact models are idealised: a fixed 30 % prematurity, full compensation, and merged intervals for missed beats. Real strap errors also include extra (split) beats and noise bursts.
- Requiring the corrector to change nothing in the clean window selects lower-variability windows. 21.6 % of artifact-free windows were excluded this way; see the false-correction figures above.

---

## Overall limitations and honest scope

- **Ports, not the shipped binary.** Fidelity rests on reproducing 114 unit-test cases, several to the last printed digit, plus a line-by-line reading. Behaviour that no unit test covers is trusted to that reading.
- **Annotated or detected ECG beats, not a chest strap.** The results describe the methods given ECG-quality beat timing. They do not cover Polar H10 beat detection, Bluetooth dropouts, or the app's own sleep-boundary resolution.
- **Populations.**
  - slpdb: apnea patients, almost all male, 32–56.
  - CAP: 15 healthy controls of unstated age and sex in this analysis.
  - mitdb: selected arrhythmia excerpts.
  - nsr2db: 24-h ambulatory Holter, resting and daily life.
  - No exercise data were used, so nothing here validates live α1 during exercise or the α1–VT1 relationship.
- **Small n for minute-level agreement.** Minute-level Bland–Altman uses n = 15–18 records. Pooled epoch statistics treat epochs as independent, although they are clustered within records; per-record values are given alongside.
- **Not evaluated.** The Apple Watch augmentation path, window selection and recovery scoring were not evaluated.
- **The analyses were pre-specified in the task brief.** Two variants were added: the sleep-period boundary variant and the all-beat RR variant. All variants run are reported. No result was dropped.

## Notes for the white-paper authors (discrepancies found while validating)

1. **White paper 1, Section 5.** It lists `hrv-sleep-staging` as unmeasured. Section 1 above measures it: κ = 0.07 on slpdb and 0.15 on CAP healthy controls, with deep sleep over-called and wake under-called.
2. **White paper 2, Section 2.** It states that "Uncorrected artifacts push α1 toward the Brownian range (1.5 or more) during exercise". In our resting data, injected artifacts moved α1 toward 0.5, not 1.5. This is consistent with the app's own test comment ("an ectopic beat left in the series drags α1 down"). We did not test exercise data, so the statement needs its own source or should be qualified.
3. **`EmuquTests/HRVReferenceValidationTests.swift` doc comment.** It quotes nsr005 pipeline RMSSD "16.03". That is the pre-`5c4a23d` value. At `e028039` the code gives 15.96. This is a stale comment, not a failing test.
4. **The `dfa-artifact-rejection` thresholds (3 % / 6 %).** They count corrected *intervals*. One ectopic beat alters two intervals, so 3 % ectopic beats already reach the 6 % rejection level (Section 3).

## Reproducing

```
cd Tools/validation
python3 -I fetch_physionet.py <db> 1.0.0 <DATA_ROOT>/<db> RECORDS <files...>   # see header of each script for the files
python3 -I test_ports.py > test_ports_output.txt     # port fidelity (Section 0)
python3 -I cap_extract_rr.py n1 ... n16               # CAP R-peak detection + hypnograms
python3 -I validate_sleep.py slpdb nn full            # also: slpdb nn sp | slpdb all full | slpdb all sp | cap nn full | cap nn sp
python3 -I validate_artifacts.py
python3 -I validate_dfa_injection.py
python3 -I make_results.py                            # rebuilds this file from results/*.json
```

`DATA_ROOT` is set in `validation_common.py`. The data stay outside the repository. Results JSON (per record, per segment) are in `results/`.
