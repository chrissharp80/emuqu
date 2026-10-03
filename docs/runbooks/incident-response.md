# Runbook: Incident Response

**When this fires.** Something is wrong with shipped behavior and users
are affected. Pick the section that matches what's happening.

---

## A. AI provider outage / breaking change

**Symptom.** Users report the AI assistant is silent, returning errors,
or producing wrong outputs. Cloud-AI provider status page is red, OR
the response shape changed under us.

**Action.**

1. **Tell users to switch provider.** The `FeatureFlags` kill switch
   (Settings → Flo) is stored on each device; there is no remote config,
   so it only turns a provider off for the person who flips it. Turning a
   provider off for everyone means shipping a build. Tell users via email
   / changelog.
2. **Wait it out** if the provider's status page promises restoration
   within hours.
3. **Hotfix** if the provider's API changed. The provider classes live
   at `Sources/Assistant/Providers/`. Each provider implements a small
   `AIProvider` protocol — fix the one that broke, ship via the
   `hotfix.md` runbook.
4. **Don't re-enable** the kill switch until you've reproduced the fix
   on a clean install.

---

## B. CloudKit sync failure (zone-wide)

**Symptom.** Users on multiple devices report sessions don't sync
between phone + Watch + iPad, or the dashboard shows stale data.

**Action.**

1. Check Apple's CloudKit Dashboard
   (https://icloud.developer.apple.com/dashboard/) for the
   `iCloud.com.chrissharp.flowrecovery` container. Look at recent
   errors in the Logs tab.
2. If Apple has a wide CloudKit outage (status.apple.com → iCloud Drive),
   wait it out. There's nothing to do.
3. If only your container is failing: the most likely cause is a schema
   change that wasn't deployed. CloudKit Dashboard → Schema → Deploy
   to Production.
4. **Don't** mass-reset user state. Each user's CloudKit data is
   private to their iCloud account; you can't write to it.

---

## C. Crash spike

**Symptom.** TestFlight / App Store Connect shows a crash spike in the
last 24 hours. Specific stack trace appears in > 5% of sessions.

**Action.**

1. **Get the symbolicated crash log** from App Store Connect → My Apps
   → Emuqu → Crashes. Filter to the last 24 hours.
2. Pull the dSYM for the affected build from
   `~/Library/Developer/Xcode/Archives/`. Symbolicate manually if
   App Store Connect can't auto-symbolicate.
3. Reproduce locally if possible. If the stack trace points at a
   specific file:line, open that file and read the surrounding code
   for force unwraps, force casts, or unguarded array accesses.
4. `make sendable-guard` to confirm no new `@unchecked Sendable`
   regressions are at play.
5. Hotfix via `hotfix.md` runbook.

**Common causes:**

- Force unwraps on map-bounds calculations when location track is empty.
- HealthKit type registration unwraps.
- Concurrency races on `nonisolated(unsafe)` properties.

---

## D. Encryption key loss

**Symptom.** Users report sessions failing to load with hash-mismatch
or decryption errors.

**Action.**

1. Determine scope: single user (likely Keychain reset on their device,
   e.g. after factory reset where they didn't restore from backup)
   vs. wide-scale (suggests EncryptionManager.shared.key generation
   regression).
2. **Single user**: do NOT open with "delete everything". Triage first —
   an unreadable key is usually a *temporary* access failure, and a wipe
   destroys recoverable data to fix something that was going to resolve
   on its own.

   Work down this list, stopping at the first that explains it:

   a. **Device not unlocked since reboot.** Archive keys are stored
      `AfterFirstUnlock`; before that first unlock they are genuinely
      unreadable and every session fails to decrypt. Ask them to unlock
      the device and relaunch. This is the most common cause and needs
      no action at all.

   b. **iCloud Keychain off or still syncing.** The cloud payload key
      (`CloudPayloadCodec`) is synchronizable. On a new device it arrives
      with iCloud Keychain, which is not instant. Local sessions read
      fine while cloud restores fail — that pattern points here. Confirm
      iCloud Keychain is on and give it time. A device that backed up
      before the key arrived made its own; each key has its own Keychain
      item, so both reach every device and records sealed with either
      open once they have. The log line "waiting for its backup key to
      sync" marks records in that state; the next pull imports them.

   c. **Restored without the Keychain.** A factory reset with no backup
      restore, or a migration that skipped the Keychain, loses the
      archive key permanently. Local encrypted sessions are unreadable.
      Cloud backups are NOT — they use the synchronizable key, so they
      survive the device.

   d. **Only then**, if the data is genuinely unrecoverable and the user
      wants a clean start, More → Settings → Advanced Data Controls →
      Delete All My Data (type DELETE MY DATA and confirm).

   Before suggesting (d), have them export anything still readable —
   deletion is irreversible and a partial archive is worth more than an
   empty one.

3. **Wide-scale**: check `Emuqu/Sources/Storage/EncryptionManager.swift`
   recent changes. Specifically `getOrCreateKey(version:)` and the
   Keychain SecItemAdd flow. The key is keyed by `keychainAccount(for:)`
   per-version — if version was bumped without a migration path, old
   files become unreadable.
4. If wide-scale: hotfix MUST include a fallback to try the previous
   key version on decryption failure. See `reEncryptIfNeeded(_:)` for
   the migration shape.

---

## E. Apple Health data corruption

**Symptom.** Users report incorrect HRV / sleep values, or the recovery
score is way off from their Health app numbers.

**Action.**

1. Most common cause: time-zone math on sleep boundaries
   (`SleepBoundaryResolver` / `addingTimeInterval` patterns). If a user
   crossed a DST boundary in the affected window, that's likely the
   cause.
2. Reproduce by setting your simulator clock to the user's reported
   date and calling the affected analyzer with their actual HealthKit
   query result.
3. Hotfix the date math; add a regression test seeded with the
   reproducing date.

---

## F. Privacy / leak suspicion

**Symptom.** A user notices their HRV / location data appearing in a
context they didn't authorize (e.g. an AI provider replying to a
question with details that suggest more data was sent than expected).

**Treat this as a P0.** Even unconfirmed.

**Action.**

1. **Don't reply with denials yet.** Acknowledge the report, ask for
   the screenshot / chat history that triggered the concern.
2. Open `Emuqu/Sources/Assistant/Facts/AppFactResolver.swift` — this is the
   layer that decides what data the AI sees. The contract is
   that raw RR / sample timestamps are NOT sent — only aggregates.
   Verify nothing has regressed.
3. Open `Emuqu/Sources/Assistant/ProviderConsentTracker.swift` and verify
   the consent gate fires before any provider call.
4. Pull the diagnostic log if the user can share theirs (More →
   Settings → Troubleshooting → Export Diagnostic Log) — confirm what
   was actually sent.
5. If a leak is real:
   - Disable the provider via its `FeatureFlags` kill switch immediately.
   - File a SECURITY.md update describing what happened.
   - Hotfix the leak.
   - Email all users who had that provider enabled.

**Don't sit on suspected leaks.** Apple + the EU regulators care more
about response time than about whether the leak was real.

---

## G. CVE against a transitive dependency you cannot bump

**Symptom.** An advisory feed or a disclosure names a package in
`Package.resolved` that Emuqu does not depend on directly — `Zip` arrives
through `polar-ble-sdk`; `yyjson` and the `swift-*` packages arrive through
WhisperKit.

**Why the obvious move does not work.** SwiftPM resolves the version the
direct dependency asks for, so a transitive pin moves only when that package
moves. There is no patch you can apply and no fork you want to maintain.

1. Establish reachability before doing anything drastic. Ask specifically:
   does the advisory describe something reachable from data an attacker
   controls — a BLE peripheral, a downloaded model, an imported file? If it
   does not, this is a P2 to track, not an incident.
2. If it is reachable, ship a build with that path switched off. There is no
   runtime flag for the sensor path, and Emuqu has no HRV function without a
   Polar strap, so a reachable bug under `polar-ble-sdk` means recording stops
   until the fix lands. On the voice path, degrade to typed input.
3. Tell affected users what they lose and why, in those terms. "Chest-strap
   recording is paused while we wait on a vendor fix" is a sentence people
   accept; silence is not.
4. Open an issue against the direct dependency referencing the advisory. Their
   release is the actual fix. Dependabot is configured monthly with
   `open-pull-requests-limit: 0`, so it opens no PR — watch the upstream
   release yourself and bump by hand.
5. Turn the path back on once the pin moves and the suite is green.

For each transitive pin, the question is not "how do we patch it" but "what
does the app do with that subsystem switched off", and the answer should exist
before the advisory does.

---

## Post-incident (every category)

Write a short note, in your own notes outside the repository, covering:

1. What broke (symptom in user terms).
2. When you noticed.
3. Root cause (in code terms — file and symbol).
4. Why CI didn't catch it.
5. What changed in the codebase / tests so this category can't recur.
6. Time-to-detection, time-to-mitigation, time-to-fix.

That's the deliverable. The fix is the means.
