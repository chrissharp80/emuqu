# App Review — reviewer notes and release flow-walk

Two audiences, one file:

1. **App Review.** What a reviewer needs to reach every feature without a chest
   strap, an overnight recording, or a paid subscription.
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
> populate. The same control is at **More → Settings → Troubleshooting →
> Sample data → "Load sample data"**, and searching Settings for "demo" finds
> it. Sample nights are tagged Demo, a banner on the Dashboard says they are
> sample data, and **"Remove sample data"** deletes them and nothing else.
> No Polar strap, HealthKit permission, or account is required.
>
> Health data is stored on device. Optional paths can send it elsewhere, all
> under the user's control:
>
> • **iCloud backup** — presented on its own onboarding screen with the toggle
>   ON and a Skip button. Payloads are encrypted by the app before upload with
>   a key held in the user's Keychain, not by us; Emuqu operates no server.
> • **Hosted AI assistant** — off until the user supplies their own API key.
> • **Web search, weather, trails, elevation** — each off until enabled, each
>   disclosed in context. HealthKit access is optional and the app is
> fully usable if it is denied. The AI assistant defaults to on-device Apple
> Intelligence; hosted providers require the user to add their own API key and
> to accept a per-provider data-sharing disclosure first.
>
> Emuqu is a wellness and fitness app. It is not a medical device, makes no
> diagnostic claim, and declines medical questions.

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
- [ ] Record an indoor workout with coach alerts on. Audio cues fire.
- [ ] Start from the Watch. The phone follows.
- [ ] Live metrics reach the wrist during a workout.
- [ ] Relaunch the Watch app mid-workout. State restores.

### AI assistant

- [ ] Default provider is Apple Intelligence. No key required, nothing leaves
      the device.
- [ ] Add a hosted provider key. **The consent sheet appears before the first
      send** and names what will be transmitted.
- [ ] Settings → AI Assistant → *provider* shows the consent date and a working
      **Withdraw consent** control.
- [ ] Withdraw, then ask again. It re-prompts.
- [ ] Remove the key. Consent is withdrawn with it.
- [ ] Ask a medical question ("do I have AFib?"). It declines and does not send.

### Paywall and entitlements

- [ ] The paywall is reachable from a fresh install with no purchase history.
- [ ] Sandbox purchase completes and unlocks.
- [ ] Restore purchases works on a second device.

### Data deletion

- [ ] Settings → Delete All My Data, with the typed confirmation.
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
