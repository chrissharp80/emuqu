# Runbook: GDPR / CCPA Data-Deletion Request

**When this fires.** A user emails asking for their data to be deleted
(GDPR Article 17 "right to erasure", CCPA "right to delete"), or asks
for a copy of their data (GDPR Article 15 / 20 "right to access /
portability").

**Your obligation.**

- GDPR Article 17: respond within **30 days**. Erasure must be
  "without undue delay."
- CCPA: respond within **45 days** with a 45-day extension allowed.
- HIPAA does not apply — this is a wellness app, not a covered entity
  or business associate. SECURITY.md documents the posture.

## Architecture you're working with

Emuqu's data-handling posture (per [SECURITY.md](../../.github/SECURITY.md)):

- **No backend.** There is no server-side database. Every byte of user
  data is on the user's own device + their iCloud private container.
- **CloudKit private DB** holds session backups, raw RR archives,
  workout tracks. The user's own iCloud account owns these records.

  **Signing out of iCloud does NOT delete them.** Apple is explicit that
  information stored in iCloud stays in iCloud after sign-out — sign-out
  removes the copy from *that device*, not from the account. Neither does
  erasing the device. This runbook and its reply
  template used to tell users the opposite, which is the worst possible direction
  for a deletion instruction to be wrong in: the user believes their health
  data is gone and stops looking.

  What actually removes the cloud copy is the app's own zone deletion, run by
  Settings → Advanced → Delete All Data while online. That is implemented and
  reported; see the online/offline handling below.
  after device wipe.
- **Keychain** holds API keys (Anthropic, OpenAI, etc.) — device-local,
  never synced (kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly).
- **Third-party AI providers** (Anthropic, OpenAI, Google, xAI,
  DeepSeek) retain conversation content per their own privacy policies.
  Emuqu has no API to delete on their behalf.

## Step 1 — Understand what you can and cannot do

**Emuqu has no account system.** There is no server, no login, no user
record, and therefore nobody to verify. Every byte of a user's data lives on
their device and in *their own* iCloud container, which you have no access to.

That has one important consequence: **there is no action you can take on a
requester's behalf, so there is nothing to authenticate them for.** Deletion
is entirely user-controlled, in-app.

*Until 2026-08-27 this step told you to verify the requester against "the
email address on file (Settings → Profile)". That field is a **report
recipient** — commonly the user's coach or clinician, not the user. Verifying
a deletion request against it would have authenticated the wrong person, for
an action you cannot perform anyway.*

Reply with the in-app flow below. Do not ask for screenshots, and do not
collect any personal data in order to answer a request about deleting
personal data.

## Step 2 — Local data deletion

The user can do this themselves at any time:

> Settings → Advanced → Delete All Data

That action invokes `DataPurgeService.purgeAllUserData(...)` which wipes:

- The session archive (`SessionArchive.shared`)
- Raw RR backups (`RawRRBackup`)
- CloudKit sync state (`CloudKitSyncState`)
- Keychain entries (API keys, encryption key)
- AI conversation history (`ConversationStore`)
- AI memory facts (`UserFactsStore`)
- Health-disclaimer + AI-disclaimer acceptance flags
- Persistent debug log + crash logs
- Units preference
- Home-screen widget published state

Direct the user to that flow first. It's faster than waiting for you.

## Step 3 — CloudKit private-DB deletion

**The in-app purge already does this.** `DataPurgeService` awaits
`CloudKitSyncManager.deleteAllRemoteData()`, which removes the app's custom
zones (`HRVSessions`, `UserSettings`) from the user's private database before
wiping local state. Step 2 covers it.

It can fail when the device is offline or signed out of iCloud. The local wipe
still completes, and the result reports `remoteDeleted: false`, which the UI
surfaces as a prompt to run the purge again with connectivity. Re-running is
idempotent, so "try it again on Wi-Fi" is the whole remedy.

Only if that keeps failing, direct the user to iCloud.com → Account Settings →
Manage Storage → Emuqu → Delete, which does remove the stored records.

Do NOT offer "sign out of iCloud" as a fallback. It removes the copy from that
device and leaves the account's copy in place — Apple documents this
explicitly. Offering it as an erasure step tells the user the data is gone
while it is not.

**You still have no access to a user's private iCloud container** — you cannot
do any of this for them. The difference from the old text is that the *app*
can, and does.

*This step said remote deletion was impossible until 2026-08-27. It has been
implemented since 2026-06-10.*

## Step 4 — Third-party AI provider data

For any provider the user configured, direct them to that provider's
own deletion flow. We don't have an API into their retention layer:

- Anthropic: privacy@anthropic.com
- OpenAI: privacy.openai.com
- Google: myactivity.google.com
- xAI: privacy@x.ai
- DeepSeek: privacy@deepseek.com

Note in your reply that the user's chat content went to the provider
they explicitly enabled (per `ProviderConsentTracker` consent log).

## Step 5 — Data export (Article 15 / 20)

The user can export their own data via:

- Settings → Advanced → Export → CSV / GPX / TCX / PDF
- Each format is documented in `docs/USERS_MANUAL.md`

If the requester wants a single archive, run all formats and zip them.

## Step 6 — Reply template

```
Subject: Re: Data deletion request — Emuqu

Hi [name],

Thanks for the request. Emuqu stores all your data on your own
device + your own iCloud private container — there's no server I run
where your data lives.

To delete both the on-device and the iCloud copy:

  1. Make sure the device is online — the iCloud deletion needs a
     connection.
  2. Open Emuqu → Settings → Advanced → Delete All Data.
  3. The screen reports what was removed. If it says the iCloud step
     did not complete, run it again once you have a connection.

Please do NOT rely on signing out of iCloud to erase anything: signing
out removes the copy from that device, and Apple keeps what is already
stored in your account. The in-app deletion is what actually removes
the records from iCloud.

If you would like independent confirmation, iCloud.com → Manage Storage
lets you see what remains under your account.

If you used a cloud AI provider (Anthropic / OpenAI / Gemini / xAI /
DeepSeek) inside the app, your chat content lives on their servers
under your account with them. Reach out to their privacy team to
delete that — I can't do it for you.

To export your data first (GDPR Article 15 / 20), use Settings →
Advanced → Export. Reply to this email if you'd like a guided walkthrough.

— Chris
```

## Step 7 — Log the request

Note the request in a private file (NOT committed to the repo):

```
~/flow-recovery-private/dsr-log.csv
date, requester (email), type (delete/access), responded_date, notes
```

This is your audit trail if the regulator ever asks for proof of
process. Keep for 3 years.

## Edge cases

- **Account-takeover suspicion**: there is nothing to protect against here,
  and that is the point. You hold no account, no server-side data and no
  ability to delete anything on the user's behalf — the deletion runs entirely
  on their own device against their own iCloud container. A request from a
  stranger cannot erase someone else's data, so identity verification buys
  nothing and collecting identifying material to answer a deletion request is
  the opposite of what the request is asking for.

  Reply with the same in-app instructions you would give anyone.

  *This section previously said to "require the
  screenshot verification in Step 1", which Step 1 explicitly removed and
  which does not exist. A runbook that contradicts itself two pages apart
  gets followed inconsistently under pressure.*
- **Minor (under 13)**: COPPA posture — note in reply that the app
  doesn't collect data on under-13 users; if they're requesting on
  behalf of a child, the same delete flow works.
- **Deceased user**: respond to next-of-kin with the same flow. Apple
  has a separate Digital Legacy program for iCloud account access.

## Compliance posture (for your records)

- Article 17 response window: 30 days (GDPR), 45 days (CCPA).
- We exceed both because all action is user-initiated.
- We do not retain anything after delete-all-data.
- We do not have a database of user emails for marketing — there's
  nothing to "remove from a list".
