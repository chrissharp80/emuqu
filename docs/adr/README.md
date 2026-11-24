# Architecture decision records

These ADRs cover eight decisions a new maintainer
would otherwise have to reconstruct from commit archaeology: the encryption
fallback, the CI cost posture, the concurrency escapes, ratcheted debt
budgets, no `unowned` back-references, Swift 6 strict concurrency, one app
target with one composition root, and gates that guard behaviour rather than size.

The first three are written up at length next to the code they govern, which is
where the reasoning stays accurate. This index is the map.

| # | Decision | Where the reasoning lives |
|---|---|---|
| 001 | Sensitive local storage falls back, then repairs, rather than failing hard; a CloudKit upload fails closed | [`Emuqu/Sources/Storage/PendingEncryptionLedger.swift`](../../Emuqu/Sources/Storage/PendingEncryptionLedger.swift) |
| 002 | The macOS jobs run at scope `unit`; the full run is on demand | [`docs/CI_POSTURE.md`](../CI_POSTURE.md) |
| 003 | Concurrency escapes are allowlisted, not eliminated | [`scripts/check_unchecked_sendable.sh`](../../scripts/check_unchecked_sendable.sh) |
| 004 | Debt is ratcheted, never waived | [`docs/adr/004-ratcheted-budgets.md`](004-ratcheted-budgets.md) |
| 005 | No `unowned` back-references | [`docs/adr/005-no-unowned-back-references.md`](005-no-unowned-back-references.md) |
| 006 | Swift 6 language mode is the concurrency gate | [`docs/adr/006-swift-6-strict-concurrency.md`](006-swift-6-strict-concurrency.md) |
| 007 | One app target, one composition root | [`docs/adr/007-single-target-composition-root.md`](007-single-target-composition-root.md) |
| 008 | Gates guard behaviour, not size | [`docs/adr/008-gates-guard-behaviour.md`](008-gates-guard-behaviour.md) |

## 001 — Sensitive storage falls back, then repairs

**Context.** `EncryptionManager`'s key cannot be read before the first unlock
after a reboot. That is exactly when a completed overnight recording gets
archived, and when the overnight raw RR and workout streams are appended to, by
background tasks.

**Options.** Fail the write (lose a night the user cannot regenerate); write
plaintext silently; or write plaintext under the strictest protection class the
write allows, record it, and repair it later.

**Decision.** The third, shaped by how each file is written:

- A whole file written in one go (an archive session file, a one-shot raw RR
  backup) is written as plain JSON with `.completeFileProtectionUnlessOpen`:
  it can be created while the device is locked and, once closed, cannot be read
  again until the next unlock. Its id is recorded in `PendingEncryptionLedger`
  (stores `.session` and `.rawBackup`).
- A streamed file (the raw RR points file, the workout GPS, sample and
  heart-rate streams) keeps `.completeFileProtectionUntilFirstUserAuthentication`
  even when it holds plain lines, because the overnight appends continue while
  the device is locked and a file of the stricter class could not be opened for
  them. Its id is recorded in the ledger (stores `.rawBackup` and
  `.workoutTrack`).
- The archive index is written as plain JSON when the key cannot be reached.

The repairs run at the next launch where the key is reachable, and the two
backup stores also run theirs whenever protected data becomes available or the
app becomes active:
`reencryptPendingSessions(in:)` rewrites the session files,
`RawRRBackup.reencryptPendingBackups()` (on unlock, `repairAfterUnlock()`) and
`WorkoutTrackBackup.reencryptPendingTracks()` re-seal the streamed files line by
line and rewrite the one-shot files, on the same queue as their appends, and
`SessionArchive.resealPlainIndexIfNeeded()` reseals the index. An id leaves the
ledger only once its files hold no plaintext.

Two kinds of write do not fall back. A CloudKit upload fails closed:
`CloudPayloadCodec.sealForUpload` throws `CloudSyncError.encryptionUnavailable`
when there is no key, because an uploaded record cannot be taken back, and the
skipped upload is retried on a later cycle. A cache that can be rebuilt (the UI
state cache, the training metrics cache, and the Apple Health sleep and
baseline caches kept in `UserDefaults`) skips the write instead and keeps its
previous copy.

**Consequence.** A window exists where health data sits on disk without
application-layer encryption, protected by the filesystem alone. That window is
bounded by one launch with the key reachable. Only an `encrypt()` call that
throws is logged (at `.error`); in the usual trigger, the key being unavailable
before first unlock, the plaintext write is not logged, and the window shows
only as the id's entry in `PendingEncryptionLedger`. The alternative was losing
user data to protect a file the OS had already made unreadable.

## 002 — The macOS jobs run at scope `unit`; the full run is on demand

The script gates that need no Xcode run on a Linux runner on every pull request
and every push to `main` (`.github/workflows/gates.yml`). The macOS jobs in
`.github/workflows/ci.yml` run at scope `unit` on every pull request and every
push to `main`: SwiftLint and the budgets, strict concurrency, the build, the
unit suite and Thread Sanitizer. The UI target and the full coverage floors
(scope `full`) run on demand and before every release. See
[`docs/CI_POSTURE.md`](../CI_POSTURE.md) for what each scope runs, what it
costs and the accepted trade-offs.

## 003 — Concurrency escapes are allowlisted, not eliminated

A handful of `@unchecked Sendable` / `nonisolated(unsafe)` annotations remain,
the count read from `.ci/unchecked_sendable_budget.txt`, each in
a file on an explicit allowlist, each naming the serial queue, lock, or SDK
contract that owns its state. `scripts/check_unchecked_sendable.sh` lists the
files and holds the count; `SessionArchive`'s conformance carries a
member-by-member audit in its own doc comment. The whole project compiles in
Swift 6 language mode with `complete` strict concurrency and zero diagnostics
(ADR 006), so the files in that allowlist are the entire remaining surface;
the count is read from `.ci/unchecked_sendable_budget.txt` and is stated
nowhere else.

## 004 — Debt is ratcheted, never waived

See [`004-ratcheted-budgets.md`](004-ratcheted-budgets.md).

## 005 — Helpers hold their owner strongly; `unowned` is banned

An `unowned` back-pointer from a helper to its owner traps when a resumed
continuation outlives the owner. Helpers are values, holding the owner strongly
and built on demand, and the `no_unowned` SwiftLint rule bans `unowned`.

See [`005-no-unowned-back-references.md`](005-no-unowned-back-references.md).

## 006 — Swift 6 language mode is the concurrency gate

Every build configuration compiles in Swift 6 language mode with `complete`
strict concurrency, so a data-race diagnostic is a compile error rather than a
budgeted warning; the only escapes are the allowlisted ones of ADR 003, and
`check_strict_concurrency_enabled.sh` fails CI if a configuration leaves that
mode.

See [`006-swift-6-strict-concurrency.md`](006-swift-6-strict-concurrency.md).

## 007 — One app target, one composition root

The iPhone app compiles as one target and module, its layers kept as
directories; the Watch app, unit tests and UI tests are separate targets.
Long-lived services are reached through `AppDependencies` (and, on the Watch,
`WatchDependencies`), whose `overrides` let a test substitute any of them, and
`.shared` is read only in those two files, which
`scripts/check_no_shared_outside_root.sh` enforces. `AppDependencies.current`
has no setter; only a test puts another container in force, for a scope that
restores the previous one. The launch work and the data purge are handed
exactly the services they use, and `scripts/check_explicit_dependencies.sh`
keeps container reads out of them and `install` out of app code.

See [`007-single-target-composition-root.md`](007-single-target-composition-root.md).

## 008 — Gates guard behaviour, not size

A rule that holds at zero is a rule (a SwiftLint custom rule where a regular
expression can state it), a count above zero is a ratchet, and no gate measures
a type's size or a document's line numbers.

See [`008-gates-guard-behaviour.md`](008-gates-guard-behaviour.md).
