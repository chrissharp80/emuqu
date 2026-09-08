# Security Policy

Emuqu is a solo-developer iOS app that handles personal HRV and sleep
data. This document covers the project's security posture, the conscious
trade-offs made for a solo workflow, and how to report a vulnerability.

## Reporting a Vulnerability

Please report suspected security vulnerabilities privately by emailing the
maintainer at the address listed in the App Store privacy disclosure.

Please include:

- Affected app version / commit SHA
- Impact summary (confidentiality, integrity, availability)
- Steps to reproduce
- Any proof-of-concept details

## Response Targets (best-effort, solo maintainer)

- Initial acknowledgement: within 5 business days
- Triage update: within 14 business days
- Remediation timeline: provided after triage based on severity

Do not publicly disclose the issue until a fix is released or coordinated
disclosure is agreed.

---

## Security Posture

### Keychain (API keys, encryption key)

API keys for connected AI providers (Anthropic, OpenAI, Gemini, Grok,
DeepSeek) and the AES-GCM-256 key used by `EncryptionManager` are stored in
the iOS Keychain with:

- `kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly` — readable only after
  first post-boot unlock; never escrowed off-device.
- `kSecAttrSynchronizable` not set — never iCloud-synced.
- No keychain access group — items are scoped to this app only.

### Keys in transit

- All AI provider requests use HTTPS with the system trust store. Headers
  carry the API key (`Authorization`, `x-api-key`, `x-goog-api-key`); no key
  ever appears in a URL query string.
- No certificate pinning. Rationale: BYOK model means the user has already
  established trust with their chosen provider. Pinning multiple third-party
  endpoints adds maintenance cost (rotation breakage) without changing the
  user's existing trust assumptions.

### App Transport Security

No `NSAppTransportSecurity` exception in `Info.plist`. Default ATS applies to
all outbound requests.

### Entitlements

Only what's needed: HealthKit + background-delivery, App Group, iCloud
container, CloudKit. No `keychain-access-groups`, `associated-domains`,
`network-extensions`, or app-sandbox-disable.

### Logging

`DebugLog` writes to an in-memory ring buffer (5,000 entries max). Beat counts
and timestamps are logged; raw RR values, API keys, and chat content are not.
Persistent debug-log file writes use `NSFileProtectionComplete`.

### Privacy manifest (`PrivacyInfo.xcprivacy`)

Declared collected data types (all marked `NotLinkedToUser`, `NotTracking`,
purpose `AppFunctionality`):

| Category | Why it's collected |
|---|---|
| `Health` | HRV, RMSSD, SDNN, pNN50, DFA α1, LF/HF, and derived recovery metrics used to compute the score shown to the user. Nothing is written to the App Group container for a widget any more: both the home-screen widget and the `WidgetDataPublisher` that fed it are gone (`DataPurgeService` removes any file an older build left behind). |
| `Fitness` | HealthKit sleep stages merged with the recording window for sleep-aware scoring. |
| `DeviceID` | Polar device identifier persisted for auto-reconnect; never transmitted off-device except to the paired sensor. |
| `PreciseLocation` | GPS samples during workout recording (route, pace, distance) and during Get Me Back / breadcrumb mode. Road context for the AI coach comes from Apple's `CLGeocoder` and `MKLocalSearch` (Apple services) and from OpenStreetMap Nominatim, which receives coordinates rounded to roughly 100 m (`OSMNominatimService`). The resulting street name is part of the assistant's context, so it reaches whichever provider the user chose: on-device Apple Intelligence by default, or the user's own cloud key. |
| `AudioData` | Microphone input during AI Assistant voice mode. Transcribed on-device by `SFSpeechRecognizer` (`requiresOnDeviceRecognition = true` whenever the device + locale support it); audio never persists beyond the recognition window. |
| `OtherUserContent` | AI Assistant chat transcripts and user-facts memory persisted via `ConversationStore` + `UserFactsStore`. When the user explicitly enables a cloud provider (Anthropic / OpenAI / Gemini / xAI / DeepSeek) AND grants per-provider consent in `ProviderConsentSheet`, the active conversation thread is sent to that provider for the duration of the request. Apple Intelligence (the default) runs on-device. |

Declared API-access reason codes:

| API category | Reason code | Use |
|---|---|---|
| `UserDefaults` | `CA92.1` | Persisting user preferences, onboarding completion, recording state. |
| `FileTimestamp` | `C617.1` and `DDA9.1` | Reading/writing session file timestamps in the App Group container. |

The following capabilities are declared in `Info.plist` usage strings and
governed at the permission layer; they are not required privacy-manifest
categories per Apple's current reference list, but are summarized here for
completeness:

- **Bluetooth** (`NSBluetoothAlwaysUsageDescription`) — Polar H10 / Verity
  Sense pairing, streaming, and internal-recording fetch.
- **Microphone** (`NSMicrophoneUsageDescription`) — voice input to the AI
  Assistant and voice coach.
- **Speech recognition** (`NSSpeechRecognitionUsageDescription`) —
  `SFSpeechRecognizer` is on-device (`requiresOnDeviceRecognition = true`);
  transcripts never leave the phone.
- **Motion** (`NSMotionUsageDescription`) — CMPedometer + CMAltimeter for
  live workout cadence/elevation; the altimeter buffer is only processed
  at session finalize.
- **Location when-in-use** (`NSLocationWhenInUseUsageDescription`) — GPS is
  collected only while a workout session is active. Background location
  *updates* are enabled during an active session (via
  `allowsBackgroundLocationUpdates = true`) so the session continues after
  screen-lock — iOS shows the standard blue background-location indicator.
  No location is recorded between sessions.

### Third-party network egress beyond AI providers

- **Elevation enrichment during workouts.** If a workout is imported or
  recorded without a barometer signal (or the user taps "Look up real
  elevation" on the post-workout summary), the app queries two public
  elevation services with `(latitude, longitude)` pairs at ~6-decimal
  precision (≈11 cm): `api.opentopodata.org` (SRTM / NED / ASTER) and
  `api.open-meteo.com/v1/elevation`. Endpoints used only for elevation
  look-ups; no HRV, HR, sleep, or user-profile data is sent. The query is
  driven by user action, not by background telemetry.

  This is declared in `PrivacyInfo.xcprivacy` as
  `NSPrivacyCollectedDataTypePreciseLocation` with purpose
  `AppFunctionality`. Opting out today means skipping the "Look up real
  elevation" button; a gated opt-in preference is tracked as follow-up.

### Data sent to third-party AI providers

When the user configures a non-Apple provider (Anthropic, OpenAI, Gemini,
Grok, DeepSeek) and sends a message, the app builds an assistant context that
includes aggregated health metrics for personalization:

- Sleep aggregates: total/deep/REM/awake minutes, efficiency, fragmentation.
- HR aggregates: mean HR, max HR, resting HR.
- HRV aggregates: RMSSD, SDNN, pNN50, DFA α1, LF/HF, recovery score.
- Vitals: respiration rate, SpO2, wrist temperature (if available).
- Training load summary: ATL, CTL, TSB, hrTSS for recent sessions.
- User profile: age, sex, fitness level, primary sport.
- Recent workout history: sport, distance, duration, pace, HR.

**Raw beat-to-beat RR intervals and beat timestamps are never sent to
third-party AI providers.** (They *are* uploaded to the user's own private
iCloud CloudKit container as part of each session backup — CloudKit handles
encryption in transit; at-rest encryption follows Apple's iCloud posture
detailed below.) The provider retains data per its own privacy policy; the
user chooses which provider to configure and can remove a key at any time in
Settings → AI Assistant. Apple Intelligence (the default) runs on-device and
sends no data off the phone.

**Apple Tool dispatcher.** Apple Intelligence is now
wired to the full tool catalog via
[`AppleToolDispatcher`](../Emuqu/Sources/Assistant/Providers/AppleToolDispatcher.swift)
— a `@MainActor` singleton that bridges `LanguageModelSession(tools:)`
calls back through `CompactToolRouter` and `FactResolverRegistry`. The
dispatcher stays on-device by construction: it forwards tool calls to
the same registry that resolves them locally for cloud providers, and
the same `MedicalQueryGuard` perimeter applies. Every tool call,
whether it came from Apple's session or a cloud provider's tool_use
block, is resolved by reading from `SessionArchive` / `SettingsManager`
on the device — no network involved at the dispatch layer.

**Cache-hit telemetry.**
[`LLMCacheTelemetry`](../Emuqu/Sources/Assistant/Facts/LLMCacheTelemetry.swift)
records prompt-cache hit ratios per provider in memory only. The
sample buffer is never persisted, never sent off-device, and is
exposed read-only via the Settings → Troubleshooting → AI cache
health card with a reset button. Each provider's cached-token signal
is normalised from its own field (Anthropic `cache_read_input_tokens`,
OpenAI `prompt_tokens_details.cached_tokens`, DeepSeek
`prompt_cache_hit_tokens`, Gemini `cachedContentTokenCount`) into a
single record call from the streamer.

#### Privacy Manifest + App Store Connect alignment

Apple's `PrivacyInfo.xcprivacy` schema does not have a per-third-party-recipient
field, so cross-binary data sharing is declared by **three layers** and they
must stay aligned:

1. **In-app consent** — `Emuqu/Sources/Assistant/ProviderConsentTracker.swift`
   presents `ProviderConsentSheet` before the first send to any cloud provider,
   per provider, with schema versioning so a disclosure change re-prompts.
2. **`PrivacyInfo.xcprivacy`** — declares the *types* of data the app
   collects: `HealthData`, `SleepAnalysis`, `DeviceID`, `PreciseLocation`,
   `AudioData`, `OtherUserContent`, all with
   `NSPrivacyCollectedDataTypeTracking = false` and purpose
   `AppFunctionality`.

   **Linked status, decided 2026-09-04.** Apple's definition makes data
   linked when it *can* be associated with an identity via an account,
   device, or other details, unless it is de-identified before collection.
   Hosted-AI requests carry health, fitness and chat content and are
   authenticated to the user's own account with each provider, and this
   document states below that providers may retain that data under their own
   policies. The CloudKit live backup writes a device identifier. So
   `Health`, `Fitness`, `OtherUserContent` and `DeviceID` are declared
   `Linked = true`. `PreciseLocation` (approximate coordinates to
   unauthenticated map and weather services) and `AudioData` (on-device
   dictation) stay `Linked = false`. Over-declaring is the safe direction:
   a "linked" label discloses more, never less.

   The App Store Connect questionnaire must give the same answers; that is
   the one source this repository cannot check.
3. **App Store Connect → App Privacy questionnaire** — must declare each
   third-party AI provider as a data recipient for `Health`, `Sleep`,
   `Audio`, and `Other User Content` data types. Update this whenever a
   new provider is added in `Sources/Assistant/Providers/`.

If you add a provider, change all three.

`MedicalQueryGuard` runs **before** any provider call, so a health-symptom
query is answered locally and never sent. Since 2026-08-30 the refused turn is
also marked `localOnly` and withheld from every later outbound history and from
summarisation — before that, the guard blocked the immediate request
while the next ordinary message carried the same text to the provider, so the
promise held for one turn and not for the conversation.

---

## Design Decisions on Data-at-Rest Encryption

Two specific questions came up during a 2026-04 audit. Both were investigated
and the conscious decision was to rely on Apple's defaults rather than add an
app-level encryption layer.

### iCloud (CloudKit private database) — app-encrypted with a portable key

**Decision (2026-08-31, superseding the 2026-04 decision below):** everything
uploaded to CloudKit — session payloads and live RR backups — is encrypted by
the app before it leaves the device, using `CloudPayloadCodec`.

**Why this changed.** App Review Guideline 5.1.3(ii) states that apps "may not
store personal health information in iCloud", with no HealthKit-origin
qualification. The previous decision uploaded JSON-encoded, ZLIB-compressed
session data containing RR intervals, plus `recoveryScore` and `meanRMSSD` as
plaintext `CKRecord` fields. Compression is not confidentiality. The two
plaintext fields were also never read back — the pull path re-derives both from
the payload — so they were health data published to iCloud for no functional
gain, and they are gone.

**The objection the old decision raised, and how it is answered.** The 2026-04
rationale rejected app-level encryption because "when a user wipes / replaces a
device, the Keychain key is lost, and the iCloud blob becomes undecryptable.
This defeats the whole point of iCloud sync." That objection was correct, and a
first attempt at this fix walked straight into it by reusing
`EncryptionManager`'s archive key, which is stored `ThisDeviceOnly` and
non-synchronizable.

`CloudPayloadCodec` uses a **separate** key, stored with
`kSecAttrSynchronizable`, so it travels through the iCloud Keychain to every
device on the same Apple ID — which is exactly the set of devices entitled to
read these backups. iCloud Keychain is itself end-to-end encrypted, so this
does not hand Apple the key. The archive key stays `ThisDeviceOnly`: local
files never leave the device, and weakening their protection to solve a sync
problem would be backwards.

`CloudPayloadCodec.isPortable` reports whether a portable key exists, so a
device with iCloud Keychain disabled can be told it has no cross-device backup
rather than silently writing one only it can read.

**Framing.** Payloads carry a magic prefix (`EMQC`) and a version byte. A
record written before this shipped has no prefix and is returned unchanged.
That branch is chosen by positively identifying the envelope, never by a failed
decryption — an earlier version inferred the format from the first payload
byte, which collides with a nonce byte, so a wrong-key ciphertext was
indistinguishable from a legacy record and was silently mis-decoded.

**Fail closed.** If no portable key is available the upload throws rather than
falling back to plaintext. A skipped backup can be retried; an uploaded one
cannot be recalled.

`EncryptionManager` (AES-GCM-256, versioned keys) continues to protect on-disk
session files. It is no longer used for anything bound for iCloud.

Enabling **Advanced Data Protection for iCloud** (iOS Settings → [Your name] →
iCloud) adds Apple-level end-to-end encryption on top of this. It is
complementary, not a substitute — the app's own encryption does not depend on
the user having enabled it.

### Local file protection — relying on container defaults

**Decision:** Session JSON files in the App Group container are written with
the platform default (`NSFileProtectionCompleteUntilFirstUserAuthentication`).
The app does **not** explicitly request `NSFileProtectionComplete` or
`NSFileProtectionCompleteUnlessOpen`.

**Rationale:**

- Overnight recording writes session data while the device is locked (user
  asleep). `NSFileProtectionComplete` would make those files unreadable
  during locked periods, breaking incremental writes.
- `NSFileProtectionCompleteUnlessOpen` (the level Apple uses for HealthKit's
  actual health data) closes files 10 minutes after device lock. App restarts
  mid-night would fail to re-open the recording file.
- `CompleteUntilFirstUserAuthentication` is what Apple uses for HealthKit
  *management* data. It encrypts at rest with a hardware-backed key, requires
  a successful unlock since boot to derive the file key, and remains readable
  for the rest of the boot session. This is the level most consumer health
  apps use for recording state.

The residual risk is device-theft after first unlock combined with a
jailbreak / forensic image. For personal HRV data this is an accepted
trade-off against breaking overnight recording.

### Persistent debug log — `NSFileProtectionComplete`

The `DebugLog` flush file in the App Group container **is** marked
`NSFileProtectionComplete`. It can contain diagnostic context that is
interesting for debugging but not strictly needed during overnight recording.

---

## Export compliance (`ITSAppUsesNonExemptEncryption`)

Recorded here because it is asked once a year at best, and re-deriving it under
submission pressure is how the wrong answer gets given.

### What the app actually does

| Where | What | Key |
| --- | --- | --- |
| `Emuqu/Sources/Storage/CloudPayloadCodec.swift` | `AES.GCM.seal` on every CloudKit payload before upload | `SymmetricKey(size: .bits256)` |
| `Emuqu/Sources/Storage/EncryptionManager.swift` | `AES.GCM` on the local archive | `SymmetricKey(size: .bits256)` |
| `Emuqu/Sources/Assistant/Facts/` | SHA-256 hashing for cache keys | n/a — a digest, not a cipher |

All of it is CryptoKit; the app implements no cipher of its own. The purpose is
**data confidentiality** — keeping health data unreadable to anyone holding the
CloudKit record or the file — not authentication or integrity checking.

### The declaration

`Emuqu/Info.plist` sets `ITSAppUsesNonExemptEncryption` to `false`.

The exemptions that flag stands on are: encryption limited to authentication,
digital signatures, copy protection, HTTPS/TLS, or encryption confined to what
the operating system provides. This app's use is confidentiality of user data
via a system framework, which is the least clear-cut of those — it is not
authentication, and whether "calls CryptoKit" counts as "confined to the OS" is
a reading, not a settled fact.

**This is a legal determination, not an engineering one.** It has not been
reviewed by counsel. It is recorded rather than resolved.

### If it is ever challenged

Symptoms: App Store Connect blocks the build pending export compliance, or a
reviewer asks for a self-classification report.

1. Change `ITSAppUsesNonExemptEncryption` to `true` in `Emuqu/Info.plist`.
2. In App Store Connect, answer the export questions with the table above:
   AES-256-GCM, CryptoKit only, no proprietary cipher, confidentiality of the
   user's own health data on their own devices.
3. Most apps in this position qualify as mass-market under ECCN 5D992.c and
   file an annual self-classification report with BIS and the ENC encryption
   request coordinator. Confirm current requirements — they change.
4. Nothing in the app needs to change. The declaration describes the code; the
   code is already accurate.

There is no code path to fix here, which is the point of writing it down: a
future submission failure should cost an afternoon of paperwork, not a
re-investigation of what the app encrypts.

## Solo-Workflow Trade-offs

This project does not use:

- **Automated secret scanning (gitleaks / trufflehog) in CI.** Rationale: API
  keys are in Keychain at runtime, never in source. TestFlight signing
  secrets live only in GitHub Actions Secrets, never in source. The
  `.gitignore` covers `.env*`, `*.p12`, `*.pem`, `*.mobileprovision`. The
  remaining risk (an accidental paste of a real key into a commit) is
  mitigated by single-developer review of every diff before push.
- **Dependency updates are pulled, not pushed.** Dependabot *version* PRs are
  disabled (`open-pull-requests-limit: 0`) because CI is manual-only and the
  PRs accumulated unvalidated — see [`docs/CI_POSTURE.md`](../docs/CI_POSTURE.md).
  Dependabot **security** updates and repository alerts remain enabled, which is
  the part worth an interruption. A deliberate sweep means raising the limit,
  running `make ci` against each bump, then setting it back.

### Software bill of materials

`sbom.spdx.json` is an SPDX 2.3 document covering all 12 resolved Swift
packages, generated from `Package.resolved` by `scripts/generate_sbom.py`. Each
entry carries its version, its resolved commit SHA as a checksum, a Package URL
for vulnerability matching, and a declared licence.

It is **deterministic** — the same lockfile always produces a byte-identical
document, so it can be committed without generating diff noise — and
`make sbom-check` fails the build if the committed copy has gone stale behind a
dependency change. That is the difference between having an SBOM and having a
current one.

Two things it deliberately does not claim: it is not signed, and there is no
build provenance attestation. Both need a release pipeline that runs, which is
the open item in `docs/CI_POSTURE.md`.

These are accepted trade-offs for a single-maintainer project. If the project
ever grows beyond solo, this section should be revisited.

---

## Data Deletion Requests (GDPR / CCPA)

This runbook covers a user-initiated request to delete every piece of their
data the app touches.

### What the user can do themselves

1. **Settings → Advanced Data Controls → Delete All My Data.** Triggers a
   typed-confirmation gate ("Delete All My Data"), then runs the
   `DataPurgeService` flow:
   - Wipes the local archive (every recorded session, every backup, every
     orphaned file in the App Group container).
   - Clears the Keychain entries the app owns (AI provider API keys, the
     legacy AES-GCM key).
   - Drops the conversation history and the user-facts store.
   - Clears every relevant `UserDefaults` key.
2. **Settings → Wearables → Delete Emuqu sleep from Apple Health.**
   Removes every sleep sample the app ever wrote to HealthKit. Watch and
   third-party sources are untouched.

### What the user must do separately

- **Other HealthKit categories** (HRV, heart rate, workouts, etc.) — open
  Apple Health → Sources → Emuqu → Delete All Data from this
  Source. Apple's UI is the only path to erase HealthKit samples this app
  did not write through the sleep cleanup endpoint.
- **iCloud (CloudKit private database).** "Delete All My Data" deletes the
  remote records too. `DataPurgeService` awaits
  `CloudKitSyncManager.deleteAllRemoteData()`, which removes the app's custom
  zones — `HRVSessions` (sessions + live backups) and `UserSettings` — from
  the user's private database, then wipes local state.

  **Partial failure is expected and handled.** The remote delete can fail if
  the device is offline or signed out of iCloud. When it does, the local wipe
  proceeds anyway — the user asked for deletion — and the result carries
  `remoteDeleted: false` so the report tells them to run the purge again with
  connectivity. Re-running is idempotent.

  If a user cannot get a successful remote delete, the fallbacks are unchanged:
  1. iCloud.com → Settings → Manage Storage → Emuqu → Delete Data, OR
  2. Uninstall the app from every device — Apple removes the container
     after the last device's grace period.

  *This section said the opposite until 2026-08-27: that CloudKit records
  "are not auto-removed". That stopped being true on 2026-06-10, when remote
  deletion landed. Support was telling erasure requesters to perform a manual
  step the app had already done, and describing the product's deletion
  capability inaccurately in compliance replies.*

### What the maintainer must do for a compliance request

If a user emails the maintainer asking for confirmation that their data has
been deleted, walk this checklist:

1. Identify the user. Bundle ID + device serial alone don't establish
   identity; ask for the registration / purchase Apple ID and a screenshot
   of the in-app "Delete All My Data" confirmation.
2. Confirm the user ran "Delete All My Data" in-app. Without it, the
   on-device data is still present.
3. If the user wants HealthKit purge confirmation, walk them through Apple
   Health → Sources → Emuqu → Delete All Data from this Source.
4. If the user wants CloudKit purge confirmation, walk them through
   iCloud.com → Manage Storage → Emuqu → Delete Data. The
   maintainer cannot delete CloudKit records on the user's behalf; the
   private database is keyed to the user's iCloud account.
5. Email the user a confirmation note listing the steps performed and
   noting that no other copies exist. Emuqu has no analytics SDK,
   no backend server, and no third-party data processor beyond the AI
   provider the user explicitly configured (whose deletion is governed by
   that provider's policy, not Emuqu).
6. Target turnaround: 30 days from initial request (GDPR Article 12 §3).

### App Store rejection / clinical-claim escalation

If a future build is rejected for a permission, regulatory, or
medical-claim issue, walk this checklist before resubmitting:

1. Re-run `make ci` — the `infoplist-guard` step (added 2026-04-26) catches
   `INFOPLIST_KEY_*UsageDescription` drift in pbxproj that silently
   overrides `Info.plist`. That drift once hit three keys.
2. Re-read every purpose string in `Emuqu/Info.plist` and
   `EmuquWatch Watch App/Info.plist` against actual call sites
   (`grep -rEn "CLLocationManager|CBCentralManager|CBPeripheralManager|CMPedometer|CMAltimeter|requestRecord|SFSpeechRecognizer|HKHealthStore.*requestAuth"`).
3. Re-read the system prompt `MEDICAL BOUNDARY` section in
   `Emuqu/Sources/Assistant/Providers/AIProvider.swift` plus the regex blocklist
   in `Emuqu/Sources/Assistant/MedicalQueryGuard.swift`. The AFib refusal copy
   must be byte-identical between the two so a guard-triggered refusal
   looks the same as a model-generated one.
4. Verify `PrivacyInfo.xcprivacy` exists in BOTH targets.

   *(A step here used to require `aps-environment = production` in
   `Emuqu/Emuqu.entitlements`. Emuqu has never used remote push — every
   notification it sends is a local `UNNotificationRequest` — so the
   entitlement is deliberately absent and the check could only ever fail or be
   skipped. Removed 2026-08-26. If remote push is ever added, restore the step
   along with the entitlement.)*
5. Open a hotfix branch off `main`, bump `CURRENT_PROJECT_VERSION`, push to
   TestFlight after `make ci` passes.

---

## Supported Versions

The `main` branch is the supported release line for security fixes. There is
no LTS branch.
