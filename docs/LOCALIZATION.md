# Localization workflow

Emuqu ships with **17 languages** in `Emuqu/Localizable.xcstrings`
(Arabic, Danish, German, Spanish, Finnish, French, Icelandic, Italian,
Japanese, Korean, Norwegian Bokmål, Dutch, Portuguese (Brazil), Russian,
Swedish, Simplified Chinese, plus English as the source).

**Every non-English locale is at 100 % coverage, and CI enforces it.** The
floor lives in `.ci/min_localization_coverage.txt` and
`scripts/check_localization_coverage.sh` fails the build below it, so a new
untranslated string breaks CI rather than silently falling back to English.

This page deliberately does not pin the source-string count. It moves with
every string added, and a number written here goes stale the same day. Read the
current figure from the catalog instead:

```bash
python3 -c "import json; print(len(json.load(open('Emuqu/Localizable.xcstrings'))['strings']), 'source strings')"
```

This doc explains how the catalog is maintained and how to add a new string.

**Permission prompts have their own catalogs.** The purpose strings iOS and
watchOS show when asking for Bluetooth, Apple Health, location and the rest
live in `Emuqu/InfoPlist.xcstrings` and `EmuquWatch Watch App/InfoPlist.xcstrings`,
keyed by the Info.plist key. The English text stays in each target's
`Info.plist`; change it there and update every translation in the matching
catalog in the same commit. `make localization-guard` holds both catalogs to
the same 100 % floor.

**The Help Center has its own table.** The articles in `HelpContent*.swift`
are plain English; `HelpLocalization` translates each string at display time
from `Emuqu/Help.xcstrings`, keyed by the exact English. Edit an article and
`HelpLocalizationTests` fails until the table has the new text in every
language and no longer holds the old. To list the keys the Help Center looks
up, run that test with `TEST_RUNNER_HELP_KEYS_OUT=/path/keys.json`.

## The 2026-05-06 string rewrite (and what needs re-translation)

A pass on 2026-05-06 rewrote eleven user-facing strings to
remove diagnostic language and to localize four
final-onboarding strings that previously rendered as English in
every locale. **Each rewritten string is a NEW catalog key** —
Xcode's catalog extractor sees the new English text on the next build
and adds it to `Localizable.xcstrings` with `state: "new"` for every
non-English language. The old keys become orphans (no source
reference) and Xcode leaves them in place; clean them up via
`Localizable.xcstrings → Edit → Delete Stale` when convenient.

| File | Old key (now orphaned) | New key (needs translation) |
|------|------------------------|------------------------------|
| `Verification.swift` | "High number of ectopic beats detected. This may indicate arrhythmia or sensor issues." | "Many irregular beats detected — most often from poor strap contact or sensor noise. Re-wet the electrodes, snug the strap, and try again." |
| `MorningResultsPopovers.swift` | "Typical range: 1.0-2.0. Higher values indicate more complexity (healthy). Very low (<0.5) may indicate pathology." | "Typical range: 1.0–2.0. Higher values reflect more complex (resilient) heart-rate dynamics. Values below 0.5 are unusually low and uncommon in healthy resting recordings — most often a sensor-quality artifact." |
| `DeepDiveReportRenderer+Pages.swift` (pNN50) | "...below 5% may indicate sympathetic dominance or autonomic rigidity." | "...below 5% suggest reduced beat-to-beat variability, often seen with heavy training load, poor sleep, or stress." |
| `DeepDiveReportRenderer+Pages.swift` (sample-entropy) | "(may indicate autonomic rigidity, heavy accumulated training load, or illness)" | "commonly seen with heavy accumulated training load, stress, or illness" |
| `DeepDiveReportRenderer+Pages.swift` (respiration) | "may indicate anxiety, pain, fever, or respiratory compromise." | "are unusual and typically reflect arousal, illness, or physical exertion within the last few minutes — context-sensitive." |
| `DeepDiveReportRenderer+Pages.swift` (vitals intro) | "...altitude effects, and respiratory compromise." | "...altitude effects, and elevated breathing rate." |
| `DeepDiveReportRenderer+Pages.swift` (ATL) | "...not an injury prediction." | "...Emuqu does not interpret this ratio as a clinical risk score." |
| `HRVDetailV2View.swift` (peak capacity) | "falls early when you're heading toward overtraining or illness." | "falls early when accumulated load or illness is dragging on the autonomic system." |
| `OnboardingView.swift` (You're in.) | (was `verbatim`) | "You're in." |
| `OnboardingView.swift` (calibration explainer) | (was `verbatim`) | "Take your first reading when you're ready. We'll spend two weeks calibrating your baseline before scoring kicks in." |
| `OnboardingView.swift` (CTA) | (was `verbatim`) | "Take a reading" / "Skip — show me around" |

Those keys have since been translated in all sixteen languages.

## Source of truth

- **English** is the source language. Every user-facing string is authored in
  English, wrapped in `String(localized:bundle:)` or `Text(_:bundle:)`.
- All other languages are translations. They live alongside the source entry
  inside `Localizable.xcstrings` (Xcode's String Catalog format, JSON under
  the hood).
- `LanguageManager.shared.bundle` is the runtime bundle used at the call
  site. Every localized call should pass it explicitly so the app honours the
  in-app language picker (Settings → Language), which overrides the device
  locale via `AppleLanguages` UserDefaults.

## Adding a new user-facing string

Do **not** write hardcoded `Text("...")` in production code. Use one of:

```swift
// Text literal
Text("Recovery Score", bundle: languageManager.bundle)

// String value (from computed property, navigationTitle, Picker label, etc.)
String(localized: "Recovery Score", bundle: languageManager.bundle)

// Label
Label(
    String(localized: "Biometrics", bundle: languageManager.bundle),
    systemImage: "heart.circle"
)
```

Build the app once — Xcode's catalog extractor picks up the new key and adds
it to `Localizable.xcstrings` with `state: "new"` for every non-English
language. That's the signal to the translator (or MT pass) that a new string
is awaiting translation.

### Strings with interpolation

`String(localized:)` supports positional arguments the same way `String`
does — just interpolate normally:

```swift
Text("Updated sleep data for \(count) sessions.", bundle: languageManager.bundle)
```

Xcode extracts the template `"Updated sleep data for %lld sessions."` and
stores the interpolation as a positional argument in the catalog so
translators can re-order if the target grammar demands it.

## Filling in translations

**Option 1: Xcode** — open `Localizable.xcstrings`, select a language in the
sidebar, and type translations into the right-hand column. Xcode handles the
"new" → "translated" state transition and saves the file as you type.

**Option 2: Machine translation as a starting point** — Apple's
`NSTranslation` / the `Translation` framework on iOS 18+ works offline and
produces serviceable drafts. The app already uses it for *dynamic* narrative
strings via `NarrativeTranslator`; static strings should still go through
Xcode's catalog so they're reviewable. Machine translation needs a human
review pass before shipping for any language nobody on the project reads.

**Option 3: Commercial translators** — export a CSV/XLIFF from the catalog
(`File ▸ Export Localizations`), hand it to a vendor, re-import the returned
XLIFF. Xcode will merge without clobbering anything you've changed in the
meantime.

## Coverage and health

CI **does** gate on translation completeness. `ci.yml` runs
`scripts/check_localization_coverage.sh` against the floor in
`.ci/min_localization_coverage.txt`, alongside
`check_localization_bundle.sh`, which fails any `String(localized:)` /
`Text(...)` lookup that is not bundle-qualified, and
`check_localization_orphans.sh`. An earlier version of this page said the
opposite — that partial coverage with English fallback was preferred to a
failing build. That stopped being true when the coverage gate landed; the
statement is corrected here 2026-08-26. To check current coverage locally:

```bash
python3 - <<'PY'
import json
with open('Emuqu/Localizable.xcstrings') as f:
    data = json.load(f)
total = len(data['strings'])
langs = sorted({lang for e in data['strings'].values() for lang in e.get('localizations', {})})
for lang in langs:
    c = sum(1 for e in data['strings'].values() if lang in e.get('localizations', {}))
    print(f'{lang:8s}: {c}/{total}  ({100*c//total}%)')
PY
```

## Accessibility labels

`.accessibilityLabel`, `.accessibilityHint`, and `.accessibilityValue` are
user-facing too. Pass `Text(...bundle:)` or `String(localized:bundle:)` so
VoiceOver speaks the right language:

```swift
Toggle(String(localized: "iCloud Sync", bundle: languageManager.bundle),
       isOn: $settingsManager.settings.iCloudSyncEnabled)
    .accessibilityHint(Text("Back up and sync recordings across your devices via iCloud.", bundle: languageManager.bundle))
```

## Things that should NOT be localized

- Proprietary product names (Emuqu, Apple Health, Polar, Stryd,
  AirPods) stay in their original form everywhere.
- Unit abbreviations that are conventionally fixed (bpm, ms, km, mi, ft, %).
  Chart-axis labels can localize "min/km" / "min/mi" because the *word* does
  vary — "minutes per kilometre" in German is "Minuten pro Kilometer", but
  the column header is typically left in the abbreviation.
- Debug-mode UI (behind the `debugModeEnabled` toggle in Troubleshooting).
  This is a developer surface; English-only is fine.

## History

- **2026-04 sweep** — routed every consumer-facing Settings string
  (Profile, Biometrics, Sleep, Training, Wearables, Appearance, Language,
  Custom Tags, iCloud & Data, Troubleshooting, main Settings list) through
  `String(localized:bundle:)` so every label is now extractable.
- **2026-05-06 recount + rewrites** — recounted the catalog at
  **1,874 source strings** (up from 1,358 in the prior count) and **872
  / 1,874 (≈ 46 %)** translated per non-English language. Eleven
  user-facing strings rewritten for diagnostic-language compliance plus four onboarding `verbatim` strings routed
  through the bundle. All eleven have been re-translated — see the
  table above.
- **Hardcoded literals:** the `Text("…")` literals that once bypassed the
  in-app language picker have been routed through `bundle:`; the
  localization-bundle guard keeps new ones out.
