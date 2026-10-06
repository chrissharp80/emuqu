# App Review — reviewer notes and release flow-walk

Two audiences, one file:

1. **App Review.** What a reviewer needs to reach every feature without a chest
   strap, an overnight recording, or a purchase.
2. **You, before a release.** The flow-walk `docs/runbooks/hotfix.md` sends you
   to. Walk all of it on a physical device before an upload.

Referenced by [`hotfix.md`](runbooks/hotfix.md) and
[`app-store-rejection.md`](runbooks/app-store-rejection.md). Those runbooks
assumed this file existed for some time before it did; if a rejection cites
"2.1 — cannot reach core functionality", the reviewer instructions below are
the first thing to check.

---

## What the reviewer must be told

Emuqu reads beat-to-beat heart-rate data from a **Bluetooth chest strap** and
turns overnight recordings into a recovery score. That creates two review
problems, and both need addressing in the App Store Connect notes:

**No strap, no data.** A reviewer on a simulator or a bare iPhone cannot pair a
Polar H10 and cannot record a night. Every screen that depends on session
history will be empty unless demo data is available.

**The main flow takes eight hours.** The primary use is "wear it overnight, read
the score in the morning." A reviewer cannot do that.

State both plainly in the review notes, along with whatever demo-fixture path
the build ships with. Do not make a reviewer guess.

### Reviewer notes template

> Emuqu requires a Bluetooth heart-rate strap (Polar H10 / Verity Sense) for
> live recording, which cannot be paired in the simulator. The core flow is an
> overnight recording reviewed the next morning.
>
> To evaluate without hardware: launch the app, accept the health disclaimer
> and finish onboarding. The **Dashboard** then shows **"No strap yet? Explore
> with sample data"** directly under "Building your baseline" — tap it. Over
> up to a minute, with progress shown, it adds three weeks of synthetic
> overnight recordings, each analysed and scored by the app's real pipeline rather than pasted in, so the
> recovery score, sleep breakdown, vitals, trends, history and reports all
> populate. The same control is at **More → Settings →
> Troubleshooting → Sample data → "Load sample data"**, and searching Settings
> for "demo" finds it. Sample nights are tagged Demo, a banner on the Dashboard says they are
> sample data, and **"Remove sample data"** deletes them and nothing else.
> No Polar strap, HealthKit permission, or account is required.
>
> **Purchase.** Emuqu is a one-time purchase with a 30-day free trial, which
> starts through its own $0 in-app purchase. A fresh install, including a
> review or TestFlight build on the App Store sandbox, shows the paywall after
> onboarding. Both in-app purchases — the free trial and the unlock — are on
> it, and stay reachable at **More → Settings → Purchase** until one is
> bought. Sandbox purchases complete there and are never charged.
> **Restore Purchases** is on the paywall and in Settings.
>
> **Flo (the AI assistant, the Flo tab).** Flo answers questions about the
> recovery, sleep and training data in the app, so load the sample data first.
> On first opening the tab, accept Flo's notice.
>
> • **With Apple Intelligence** (iPhone 15 Pro or later on iOS 26, with Apple
>   Intelligence turned on and its model downloaded) Flo needs no key and
>   answers on the device. With Apple Intelligence selected there is no text
>   field: tap a suggestion chip, or the microphone at the top left to talk to
>   Flo.
> • **Without Apple Intelligence** the Flo tab shows **Set up Flo**, says what
>   Flo needs, and **Add an API key** opens Settings → Flo.
> • **Typed questions** need a cloud model. A temporary, spend-capped Anthropic
>   key for review is: `<paste the key here; never put a key in the build>`.
>   Flo tab → **Add an API key** (or More → Settings → Flo) → **Claude** →
>   paste → **Save key** → back, **Done** → type a question. Before the first
>   send, Claude's data-sharing sheet appears; tap **Send and remember for
>   Claude** and the answer streams in. The model name at the top of the Flo
>   tab opens **Choose model**, which lists each provider's models.
> • **API keys are the user's own** accounts with each provider (Anthropic,
>   OpenAI, Google, xAI, DeepSeek, and Tavily for web search). Emuqu sells
>   nothing through them, takes no share of their charges, and the purchase
>   does not depend on them. Keys are kept in the device Keychain and sent
>   only to their provider, in request headers.
> • **What is sent.** A cloud provider receives the question and the health,
>   workout and location context needed to answer it, directly from the
>   device; Emuqu runs no server. Before the first send to each provider, a
>   sheet lists every category of data it will receive, how it leaves the
>   device, what that provider's terms say about training on it, keeping it
>   and human review, DeepSeek's processing in China, and a link to the
>   provider's privacy policy. **Don't send** sends nothing. Consent is
>   withdrawn at More → Settings → Flo → the provider → **Withdraw consent**,
>   and removing the key withdraws it too. Apple Intelligence shows no sheet:
>   it answers on the device, and only a web search (with a Tavily key) or a
>   place lookup leaves it.
> • Long-press any reply → **Report response** to report it.
>
> Health data is stored on device. Optional paths can send it elsewhere, all
> under the user's control:
>
> • **iCloud sync** — off by default; the user turns it on from its own
>   onboarding screen or in Settings. Payloads are encrypted by the app before
>   upload with a key held in the user's iCloud Keychain, not by us; Emuqu
>   operates no server. No data read from Apple Health is stored in iCloud
>   (Guideline 5.1.3(ii)): sleep, vitals, VO2max, Apple Watch heart rate and
>   profile values filled from Health are left out, and each device reads
>   Health itself.
> • **Hosted AI assistant** — off until the user supplies their own API key.
> • **Web search** — off until enabled. **Trails and elevation** — looked up
>   only when the user asks. **Weather** — looked up during outdoor workouts,
>   and **nearby roads** while the app is open, both with approximate
>   coordinates, once location is allowed and while the assistant or heat
>   tracking is on. Each
>   is disclosed in the privacy policy and the AI consent sheet. HealthKit access is optional and
>   the app is fully usable if it is denied. The AI assistant defaults to on-device Apple
> Intelligence; hosted providers require the user to add their own API key and
> to accept a per-provider data-sharing disclosure first.
>
> **Background modes.** *bluetooth-central* keeps the strap connected through
> an overnight recording with the screen locked. *location* records a
> workout's route, and a Get Me Back trail, with the screen off until the user
> stops it. *audio* keeps Flo's voice conversation running with the screen
> locked, and holds a session during an indoor workout that will speak: one
> with a heart-rate threshold cue, mile markers or an interval plan. *bluetooth-
> peripheral* is the optional broadcaster that sends live heart rate and power
> to indoor-trainer apps such as Zwift; it is off until turned on at **More →
> Settings → Wearables**, behind its own disclosure.
>
> Emuqu is a wellness and fitness app. It is not a medical device and makes no
> diagnostic claim. The assistant declines diagnostic questions about heart
> rhythm and symptoms, and answers messages about self-harm with crisis
> resources, on the device and before anything is sent to a provider.

**Keep the demo path honest.** `app-store-rejection.md` names a stale demo path
as the most likely cause of a 2.1 rejection. If the fixture route changed, this
file changes in the same commit.

---

## Release flow-walk

Physical device, Release configuration, a real strap. Simulator passes do not
count — the sensor, background, and Watch paths are the ones that break.

### Onboarding and permissions

- [ ] Fresh install. Onboarding runs start to finish.
- [ ] The health disclaimer appears and must be acknowledged.
- [ ] **Deny** HealthKit. The app stays usable; nothing dead-ends.
- [ ] Reinstall, **grant** HealthKit. Sleep and vitals populate.
- [ ] Deny Bluetooth. The record screen explains what is needed, not a spinner.

### Recording — the core path

- [ ] Pair a strap. Signal quality and live BPM appear.
- [ ] Start an overnight recording; background the app; lock the screen.
- [ ] Leave it running long enough to cross a real sleep boundary.
- [ ] **Walk out of range**, come back. It reconnects and the gap is visible in
      the session, not silently interpolated.
- [ ] Force-quit mid-recording. Relaunch. Crash recovery offers the session and
      restores it without losing beats.
- [ ] Stop and accept. A recovery score is produced and archived.

### Morning results

- [ ] Score, breakdown, and factors render. No `NaN`, no blank ring.
- [ ] Re-analyze. The score either holds or changes for a stated reason.
- [ ] Edit the sleep timeline. The score recomputes.
- [ ] Export the PDF. Every section renders; no placeholder text.

### Workouts and Watch

- [ ] Record an outdoor GPS workout. Route, splits, HR zones all populate.
- [ ] Record an indoor workout with a heart-rate threshold cue set. Audio cues
      fire with the screen locked.
- [ ] Start from the Watch. The phone follows.
- [ ] Live metrics reach the wrist during a workout.
- [ ] Relaunch the Watch app mid-workout. State restores.

### AI assistant

- [ ] Default provider is Apple Intelligence. No key required, nothing leaves
      the device.
- [ ] On a device without Apple Intelligence and with no key, the Flo tab
      shows **Set up Flo** (no disabled chips), and **Add an API key** opens
      Settings → Flo. After a key is saved and the sheet closed, the chat and
      text field appear.
- [ ] **Choose model** lists every model of each provider with a key. Pick a
      non-default model: the badge shows it, and the reply's footer names it.
- [ ] The Gemini consent sheet states both the free-key and the paid-key terms.
- [ ] A reply with a `##` heading shows a bold line, not `#` marks.
- [ ] Add a hosted provider key. **The consent sheet appears before the first
      send** and names what will be transmitted.
- [ ] Settings → Flo → *provider* shows the consent date and a working
      **Withdraw consent** control.
- [ ] Withdraw, then ask again. It re-prompts.
- [ ] Remove the key. Consent is withdrawn with it.
- [ ] Ask a medical question ("do I have AFib?"). It declines and does not send.
- [ ] Type "I want to die". The crisis reply appears, on device, with no send.

### Paywall and entitlements

- [ ] The paywall is reachable from a fresh install with no purchase history.
- [ ] A TestFlight build shows the same paywall after onboarding.
- [ ] Start the free trial (the $0 purchase). The paywall then offers only
      the unlock, and the trial clock shows under Purchase. Xcode builds have
      permanent access: the paywall notes it ("Full access is already active
      on this device.") and offers only the unlock, never the trial.
- [ ] Sandbox purchase completes and unlocks.
- [ ] Restore purchases works on a second device.

### Data deletion

- [ ] More → Settings → Advanced Data Controls → Delete All My Data, with the
      typed confirmation.
- [ ] Sessions, backups, conversations, keys, and settings are all gone.
- [ ] With iCloud on and online: the remote copy goes too.
- [ ] **In airplane mode:** the local wipe still completes, and the result tells
      the user to re-run with connectivity. Re-running is idempotent.

### Accessibility and localisation

- [ ] VoiceOver through onboarding, record, results, and settings.
- [ ] Largest accessibility text size. Nothing clips or overlaps.
- [ ] One RTL locale (Arabic) — layout mirrors correctly.
- [ ] One CJK locale (Japanese) — no truncation in the score card.
- [ ] Reduce Motion and Increase Contrast both respected.

---

## Before you upload

- [ ] `make ci` passes end to end. Check the exit status, not the last line.
- [ ] The uploaded commit is the commit whose checks passed.
- [ ] Privacy answers in App Store Connect match `PrivacyInfo.xcprivacy`, the
      consent sheet, and the privacy policy. If any provider payload changed,
      all four change together.
- [ ] The archive's privacy report has no undeclared required-reason API.
- [ ] Review notes and the demo path above are current for this build.
- [ ] On a fresh install, "No strap yet? Explore with sample data" is on the
      Dashboard without scrolling; loading it shows a recovery score, and
      "Remove sample data" leaves the Dashboard back at Get started.
