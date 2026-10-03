# Security Policy

Emuqu is a solo-developer iOS app that handles personal HRV and sleep
data. This document covers the project's security posture, the conscious
trade-offs made for a solo workflow, and how to report a vulnerability.

## Reporting a Vulnerability

Please report suspected security vulnerabilities privately by email to
chrissharp80@gmail.com, the same address as Settings → Contact Support.

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

### Keychain

The app owns four kinds of Keychain item. None uses a keychain access group,
so all are scoped to this app.

| Item | Code | Accessibility | Synchronizable |
|---|---|---|---|
| AI provider and web-search API keys | `APIKeyStore` | `kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly` | No — never leaves the device |
| Local archive key (AES-GCM-256) | `EncryptionManager` | `kSecAttrAccessibleAfterFirstUnlock` | No |
| iCloud payload key (AES-GCM-256) | `CloudPayloadCodec` | `kSecAttrAccessibleAfterFirstUnlock` | Yes — iCloud Keychain |
| Trial and purchase record | `EntitlementAnchor` | `kSecAttrAccessibleAfterFirstUnlock` | Yes — iCloud Keychain |

The archive key is deliberately not `ThisDeviceOnly`. The session files it
opens are in the device backup; a this-device-only key is not, so a restore to
a new phone listed every night and could open none. Without the suffix the key
travels with an encrypted or iCloud device backup and a phone-to-phone
transfer, next to the files it opens. Keys stored by older builds as
`ThisDeviceOnly` are updated in place on first use. It is not synchronizable:
it never travels through iCloud Keychain.

The two synchronizable items are synchronizable on purpose: the cloud key has
to reach every device on the Apple ID that may restore a backup, and the trial
record has to survive deleting and reinstalling the app. A synchronizable item
cannot use a `ThisDeviceOnly` class.

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

`DebugLog` keeps an in-memory ring buffer (5,000 entries). Writing it to disk
is always on in debug builds and opt-in in release builds. The on-disk file in
the App Group container is set to
`completeUntilFirstUserAuthentication`, not `complete`: it has to be writable
while the phone is locked during overnight recording and screen-locked
workouts, or every write in that window fails. It is still encrypted at rest.

Lines are passed through `scrubPHI`, which redacts health values and session
IDs, before they are flushed to disk and again on export. An export is written
to a temporary directory with no file protection so the share sheet can open
it. `make log-redaction-guard` fails the build when a log call interpolates a
raw health or identifying value.

### Privacy manifest (`PrivacyInfo.xcprivacy`)

Every declared type has `Tracking = false` and the single purpose
`AppFunctionality`. `NSPrivacyTracking` is false and there are no tracking
domains.

| Collected data type | Linked | Why it's collected |
|---|---|---|
| `Health` | Yes | HRV, RMSSD, SDNN, pNN50, DFA α1, LF/HF and the recovery metrics derived from them. Reaches a hosted AI provider when the user turns one on and consents. |
| `Fitness` | Yes | Workouts, sleep stages and activity from HealthKit, merged into scoring and training load. Reaches a consented hosted provider the same way. |
| `PreciseLocation` | Yes | GPS during workout recording and Get Me Back. Route coordinates rounded to about 11 m go to OpenTopoData or Open-Meteo when the user asks for real elevation. Nearby street names are part of the assistant's context, so they reach a consented hosted provider. |
| `CoarseLocation` | No | Coordinates rounded to about 1 km for Open-Meteo weather, and to about 100 m for OpenStreetMap Nominatim and Overpass road and trail lookups. |
| `AudioData` | No | Microphone input for voice mode. Transcribed on the device when the device and language support it, otherwise by Apple's speech service. Not stored. |
| `OtherUserContent` | Yes | Assistant chat transcripts and remembered facts (`ConversationStore`, `UserFactsStore`). The active conversation goes to a hosted provider only after per-provider consent in `ProviderConsentSheet`. Apple Intelligence, the default, runs on the device. |
| `Contacts` | Yes | The in-app email address book (`EmailContactStore`): names, addresses and notes. The assistant reads it through `assistant.contacts.list` to address email, so it reaches a consented hosted provider. |
| `EmailAddress` | Yes | The same contacts' addresses and the default email recipients in Settings, sent to a consented hosted provider when the assistant writes an email. |
| `PhysicalAddress` | Yes | Addresses the user types: the home address in Settings → Biometrics, or one given to the assistant for directions. Geocoded by Apple; one given to the assistant reaches the chosen provider. |
| `SearchHistory` | Yes | Web-search queries the assistant writes, sent to Tavily (with the user's Tavily key) or run by Anthropic on Claude, once the user turns web search on. |

Declared API-access reason codes:

| API category | Reason codes |
|---|---|
| `UserDefaults` | `CA92.1`, `1C8F.1` |
| `FileTimestamp` | `C617.1` |

`CA92.1` covers the app's own preferences; `1C8F.1` covers defaults shared
through the App Group. `C617.1` covers timestamps of files inside the app's
own containers.

The following capabilities are declared in `Info.plist` usage strings and
governed at the permission layer; they are not privacy-manifest categories,
but are summarized here for completeness:

- **Bluetooth** (`NSBluetoothAlwaysUsageDescription`) — Polar H10 / Verity
  Sense pairing and streaming, optional power, stride, bike and rower sensors,
  and the optional heart-rate and power broadcaster.
- **Microphone** (`NSMicrophoneUsageDescription`) — voice input to the
  assistant.
- **Speech recognition** (`NSSpeechRecognitionUsageDescription`) —
  `SFSpeechRecognizer` runs on the device when the device and language support
  it; otherwise Apple's speech recognition service transcribes, as the privacy
  policy says.
- **Motion** (`NSMotionUsageDescription`) — CMPedometer and CMAltimeter for
  steps, cadence and elevation gain.
- **Location when in use** (`NSLocationWhenInUseUsageDescription`) — the
  purpose string lists every use: workout recording and Get Me Back (both
  continue with the screen off until they end), trail discovery, weather, and
  nearby street names while the app is open. No location is collected while
  the app is closed and none of those features is running.

### Third-party network egress beyond AI providers

The README's privacy table is the complete list. Two details worth keeping
here:

- **Elevation.** Only when the user taps "Look up and save real elevation" on a
  workout summary. The route is downsampled to at most 100 points and sent as
  coordinates rounded to four decimals (about 11 m) to `api.opentopodata.org`,
  falling back to `api.open-meteo.com/v1/elevation` (`TopoElevationService`).
  No HRV, heart rate, sleep or profile data is sent.
- **Road and trail lookups.** Nominatim receives coordinates rounded to three
  decimals (about 100 m, `OSMNominatimService`); trail discovery sends Overpass
  the same precision (`TrailDiscoveryService`).

### Data sent to third-party AI providers

When the user configures a hosted provider (Anthropic, OpenAI, Gemini, Grok,
DeepSeek), consents, and sends a message, the app builds an assistant context
that can include aggregated health metrics for personalization:

- Sleep aggregates: total/deep/REM/awake minutes, efficiency, fragmentation.
- HR aggregates: mean HR, max HR, resting HR.
- HRV aggregates: RMSSD, SDNN, pNN50, DFA α1, LF/HF, recovery score.
- Vitals: respiration rate, SpO2, wrist temperature (if available).
- Training load summary: ATL, CTL, TSB, hrTSS for recent sessions.
- User profile: age, sex, fitness level, primary sport.
- Recent workout history: sport, distance, duration, pace, HR.

**Raw beat-to-beat RR intervals and beat timestamps are never sent to
third-party AI providers.** They are uploaded, encrypted by the app, to the
user's own private CloudKit container as part of each session backup (see
below). The provider retains data per its own privacy policy; the user chooses
which provider to configure and can remove a key at any time in Settings → Flo.
Apple Intelligence (the default) runs on the device; the only things it sends
off the phone are a web search or place lookup it makes, to that service.

**Apple tool dispatcher.**
[`AppleToolDispatcher`](../Emuqu/Sources/Assistant/Providers/AppleToolDispatcher.swift)
bridges `LanguageModelSession(tools:)` calls back through `CompactToolRouter`
and `FactResolverRegistry`, the same registry that resolves tool calls for
hosted providers, and the same `MedicalQueryGuard` perimeter applies. Tool
calls are resolved by reading local state on the device; the dispatch layer
makes no network call.

**Cache-hit telemetry.**
[`LLMCacheTelemetry`](../Emuqu/Sources/Assistant/Facts/LLMCacheTelemetry.swift)
records prompt-cache hit ratios per provider in memory only. The sample buffer
is never persisted or sent off the device, and is shown read-only on the AI
cache health card in Settings → Troubleshooting, with a reset button. Each
provider's cached-token field (Anthropic `cache_read_input_tokens`, OpenAI
`prompt_tokens_details.cached_tokens`, DeepSeek `prompt_cache_hit_tokens`,
Gemini `cachedContentTokenCount`) is normalised into one record.

#### Privacy manifest and App Store Connect alignment

`PrivacyInfo.xcprivacy` has no per-recipient field, so what the app shares and
with whom is declared in **three layers**, and they must stay aligned:

1. **In-app consent** — `Emuqu/Sources/Assistant/ProviderConsentTracker.swift`
   presents `ProviderConsentSheet` before the first send to any hosted
   provider, per provider, with a schema version so a disclosure change asks
   again.
2. **`PrivacyInfo.xcprivacy`** — declares the *types* of data, as in the table
   above. Apple counts data as linked when it can be associated with an
   identity through an account, a device or other details. Hosted-AI requests
   carry health, fitness, chat, contact and address content and are
   authenticated to the user's own account with each provider, which may
   retain it, so those types are declared linked. Coarse location (rounded
   coordinates to unauthenticated map and weather services) and audio
   (dictation, not stored) are not. Over-declaring is the safe direction: a
   "linked" label discloses more, never less.
3. **App Store Connect → App Privacy questionnaire** — must give the same
   answers and declare each hosted AI provider as a recipient. This is the one
   layer this repository cannot check. Update it whenever a provider is added
   in `Sources/Assistant/Providers/`.

If you add a provider or a data type, change all three.

`MedicalQueryGuard` runs **before** any provider call, so a health-symptom
query is answered locally and never sent. The refused turn is marked
`localOnly` and withheld from every later outbound history and from
summarisation, so the next ordinary message cannot carry it to the provider.

---

## Data at Rest

### iCloud (CloudKit private database) — app-encrypted with a portable key

Everything uploaded to CloudKit — session payloads and live RR backups — is
encrypted by the app before it leaves the device, using `CloudPayloadCodec`
(AES-GCM-256). No health value is written as a plaintext `CKRecord` field.

**Why.** App Review Guideline 5.1.3(ii) says apps may not store personal
health information in iCloud. Compression is not confidentiality.

**Why a separate key.** The archive key is not synchronizable, so a backup
sealed with it could not be opened on a replacement device, which defeats the
backup. `CloudPayloadCodec` uses its own key stored with
`kSecAttrSynchronizable`, so it reaches every device on the same Apple ID —
exactly the devices entitled to read these backups. iCloud Keychain is
end-to-end encrypted, so this does not hand Apple the key. A device that has to
write before iCloud Keychain delivers the existing key creates one under its
own account; sync carries all of them and `decode` tries each, since AES-GCM
authentication rejects a wrong key outright.

`CloudPayloadCodec.hasUsableKey` reports whether there is a key to encrypt
with. It does not, and cannot, assert that another device can decrypt: a
local Keychain read cannot tell whether iCloud Keychain is on and has synced.

**Framing.** Payloads carry a magic prefix (`EMQC`) and a version byte. A
record without the prefix is a legacy record and is returned unchanged. That
branch is chosen by positively identifying the envelope, never by a failed
decryption.

**Fail closed.** If no key is available the upload throws rather than falling
back to plaintext. A skipped backup can be retried; an uploaded one cannot be
recalled.

Enabling **Advanced Data Protection for iCloud** (iOS Settings → [Your name] →
iCloud) adds Apple-level end-to-end encryption on top. It is complementary,
not a substitute.

### Local session files

Session files are encrypted by `EncryptionManager` (AES-GCM-256, versioned
keys) and written with `completeFileProtectionUntilFirstUserAuthentication`.

- Overnight recording and background work (CloudKit sync, building assistant
  context) read and write while the phone is locked. `complete` would make
  those files unreadable then.
- `completeUnlessOpen` keeps a file readable across a lock only while its
  handle stays open; `Data(contentsOf:)` opens and closes in one go, so locked
  reads failed with "Operation not permitted".
- `completeUntilFirstUserAuthentication` is encrypted at rest with a
  hardware-backed key, needs an unlock since boot, and stays readable for the
  rest of that boot.

If the archive key is unreachable at write time (a background write before the
first unlock after a reboot), the session is written as plain JSON with
`completeFileProtection` — unreadable whenever the phone is locked — and
recorded in `PendingEncryptionLedger`. The next launch re-encrypts it.

Assistant conversations, remembered facts and assistant artifacts are written
with `completeFileProtection`.

The residual risk is device theft after first unlock combined with a
jailbreak or forensic image. For personal HRV data this is an accepted
trade-off against breaking overnight recording.

---

## Export compliance (`ITSAppUsesNonExemptEncryption`)

Recorded here because it is asked once a year at best, and re-deriving it under
submission pressure is how the wrong answer gets given.

### What the app actually does

| Where | What | Key |
| --- | --- | --- |
| `Emuqu/Sources/Storage/CloudPayloadCodec.swift` | `AES.GCM.seal` on every CloudKit payload before upload | `SymmetricKey(size: .bits256)` |
| `Emuqu/Sources/Storage/EncryptionManager.swift` | `AES.GCM` on the local archive | `SymmetricKey(size: .bits256)` |
| `Assistant/Facts/`, `Storage/`, `Collection/` and others | SHA-256 for cache keys and file-integrity hashes | n/a — a digest, not a cipher |

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
  `.gitignore` covers `.env`, `.env.local`, `.env.*.local`, `*.p8`, `*.p12`,
  `*.pem`, `*.mobileprovision`. The
  remaining risk (an accidental paste of a real key into a commit) is
  mitigated by single-developer review of every diff before push.
- **Dependency updates are pulled, not pushed.** Dependabot *version* PRs are
  disabled (`open-pull-requests-limit: 0`) because CI is manual-only and the
  PRs accumulated unvalidated — see [`docs/CI_POSTURE.md`](../docs/CI_POSTURE.md).
  Dependabot **security** updates and repository alerts remain enabled, which is
  the part worth an interruption. A deliberate sweep means raising the limit,
  running `make ci` against each bump, then setting it back.

### Software bill of materials

`sbom.spdx.json` is an SPDX 2.3 document covering the 11 resolved Swift
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

The maintainer holds no copy of anyone's data and cannot delete anything on a
user's behalf; deletion runs on the user's own device against their own iCloud
container. How to answer a request is in
[`docs/runbooks/data-deletion.md`](../docs/runbooks/data-deletion.md). What the
app does:

1. **Settings → Advanced Data Controls → Delete All My Data.** The user types
   `DELETE MY DATA` and confirms a second time. `DataPurgeService` then:
   - deletes the app's CloudKit zones (`HRVSessions`, `UserSettings`) from the
     user's private database, first, through
     `CloudKitSyncManager.deleteAllRemoteData()`;
   - wipes the local archive, backups, workout tracks and breadcrumbs, and
     sweeps every other file in the app's containers;
   - removes the AI provider API keys from the Keychain;
   - clears the conversation history, remembered facts and settings, and
     leaves iCloud sync off.

   The trial and purchase record (`EntitlementAnchor`) is kept on purpose: a
   wipe is not a refund.

   If the remote delete fails (offline, signed out of iCloud), the local wipe
   still runs and the report says `remoteDeleted: false`, so the user can run
   it again with a connection. Re-running is safe. The fallbacks are iCloud
   storage management on the device (Settings → [Your name] → iCloud → Manage
   Storage → Emuqu), or deleting the app from every device.
2. **Settings → Wearables → Delete Emuqu sleep from Apple Health** removes the
   sleep samples the app wrote. Other HealthKit samples the app wrote (workouts,
   and HRV and heart rate if export was on) are removed in the Health app,
   from Emuqu's entry in its list of apps.

Data that went to a hosted AI provider, Tavily or a map, weather or elevation
service is governed by that service's own policy.

### App Store rejection

Use [`docs/runbooks/app-store-rejection.md`](../docs/runbooks/app-store-rejection.md).
Two checks belong to this document: `make infoplist-guard` catches
`INFOPLIST_KEY_*UsageDescription` build settings in the project file that
would silently override `Info.plist`, and `PrivacyInfo.xcprivacy` must exist in
both the iPhone and Watch targets and match the three layers above.

---

## Supported Versions

The `main` branch is the supported release line for security fixes. There is
no LTS branch.
