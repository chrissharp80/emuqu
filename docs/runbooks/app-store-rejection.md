# Runbook: App Store Rejection Response

**When this fires.** App Store Review emails you with a rejection notice
inside Resolution Center. You have ~14 days to respond before the build
is removed from the queue.

**What you do (in order).**

## 1. Read the actual reason

Open Resolution Center. Don't paraphrase. Don't assume. Copy the literal
guideline number(s) and the reviewer's prose into a scratch doc.

The five rejections this app is most likely to hit, in descending
likelihood:

- **5.1.1(i)** — privacy nutrition label vs. actual collected data.
  *Most likely cause:* a new feature added a data collection that wasn't
  declared in `PrivacyInfo.xcprivacy` AND the App Store Connect privacy
  questionnaire wasn't updated. See "Privacy manifest and App Store Connect
  alignment" in [`.github/SECURITY.md`](../../.github/SECURITY.md) for the
  three-layer alignment contract.
- **2.5.4 / 5.1.1** — background-mode minimality. *Most likely cause:*
  `UIBackgroundModes` declares `location` / `bluetooth-peripheral` / `audio`
  but the app uses them outside an active user-visible session. Only
  `WorkoutLocationManager` streams background location (a GPS workout's
  route), and `BackgroundAudioManager` holds the audio session only while
  a spoken cue plays.
- **1.4.1** — health & medical accuracy. *Most likely cause:* AI
  assistant copy crossed from wellness into diagnostic. See
  `MedicalQueryGuard` and the MEDICAL BOUNDARY block in
  `Emuqu/Sources/Assistant/Providers/AIProvider+SystemPromptText.swift`.
- **5.1.3** — HealthKit data uses. *Most likely cause:* HealthKit data
  reached an advertising endpoint or a data broker. We don't do this —
  but a new analytics SDK (Firebase / Mixpanel / etc.) being pulled in
  by a transitive dependency would trigger it. Grep `Package.resolved`.
- **2.1 (incomplete information)** — App Reviewer can't reach core
  functionality. *Most likely cause:* the reviewer notes in
  [`docs/REVIEW.md`](../REVIEW.md) are stale
  or the demo-fixture path stopped working. Walk every step.

## 2. Reproduce the rejection trigger locally

Don't just respond with "we believe this is in compliance." Open the
relevant code path and confirm. If you can't reproduce, ask the
reviewer for the device + iOS version + steps in Resolution Center.

## 3. Decide: fix-and-resubmit OR appeal

**Fix-and-resubmit** when the rejection points at something real.
Land the fix on `main`, bump CFBundleVersion, archive, upload to
App Store Connect, attach the new build to the rejected submission,
add a Resolution Center reply pointing at the build number and the
specific commit SHA that addresses the cited guideline. Make the
reviewer's job easy: name the commit and the file, paste the
new copy if it's a wording fix.

**Appeal** when the rejection is a misread (rare, but it happens —
especially with first-launch flows that need specific permissions
to show their content). Use the Submit an Appeal button in
Resolution Center. Be explicit about which guideline and why the
behavior they observed isn't a violation. Don't be combative —
provide the guideline-relevant paragraph from your own privacy
policy / Info.plist / SECURITY.md.

## 4. Resubmit

If you cut a new build, attach it to the open submission rather than
creating a new one — that keeps the review on the original timeline.

## 5. Record the cause and the fix

Even if the rejection cause was a misread, write it down against the
build that shipped it, in your own notes outside the repository. Future-you needs
to know which categories of rejection have happened and what was
done about them.

## Common gotchas

- A new TestFlight upload doesn't auto-fix the App Store submission.
  You have to actively replace the build in App Store Connect.
- App Store Connect sometimes lags 30 minutes between TestFlight
  processing and the build being available to attach. Wait it out.
- If you bumped CFBundleVersion locally, the upload may collide with
  an existing TestFlight build. Check `git log -p` for the version
  bump on the `main` branch first.

## Contacts

- Resolution Center: appstoreconnect.apple.com → My Apps → Activity
- Developer Phone Support (for genuinely-stuck cases):
  https://developer.apple.com/contact/phone/
