# Architecture decision records

These ADRs cover six decisions a new maintainer
would otherwise have to reconstruct from commit archaeology: the encryption
fallback, the CI cost posture, the concurrency escapes, ratcheted debt
budgets, no `unowned` back-references, and Swift 6 strict concurrency.

The first three were already written down at length — just not
somewhere a reader would look first, and not labelled as decisions. This index
is the missing map; the reasoning lives with the code it governs, which is where
it stays accurate.

| # | Decision | Where the reasoning lives |
|---|---|---|
| 001 | Sensitive storage falls back, then repairs, rather than failing hard | [`Emuqu/Sources/Storage/PendingEncryptionLedger.swift`](../../Emuqu/Sources/Storage/PendingEncryptionLedger.swift) |
| 002 | Nothing that needs macOS runs automatically | [`docs/CI_POSTURE.md`](../CI_POSTURE.md) |
| 003 | Concurrency escapes are allowlisted, not eliminated | [`scripts/check_unchecked_sendable.sh`](../../scripts/check_unchecked_sendable.sh) |
| 004 | Debt is ratcheted, never waived | [`docs/adr/004-ratcheted-budgets.md`](004-ratcheted-budgets.md) |
| 005 | No `unowned` back-references | [`docs/adr/005-no-unowned-back-references.md`](005-no-unowned-back-references.md) |
| 006 | Swift 6 language mode is the concurrency gate | [`docs/adr/006-swift-6-strict-concurrency.md`](006-swift-6-strict-concurrency.md) |

## 001 — Sensitive storage falls back, then repairs

**Context.** `EncryptionManager` is unavailable before the first unlock after a
reboot. That is exactly when a completed overnight recording gets archived by a
background task.

**Options.** Fail the write (lose a night the user cannot regenerate); write
plaintext silently (what the code did); or
write under the strictest protection class and repair later.

**Decision.** The third. The bytes are written with `.completeFileProtection` —
unreadable whenever the device is locked, not merely before first unlock — the
session is recorded in `PendingEncryptionLedger`, and `reencryptPendingSessions()`
rewrites it encrypted at the next launch where the key is reachable.

**Consequence.** A window exists where health data sits on disk without
application-layer encryption, protected by the filesystem alone. That window is
bounded by one app launch and is logged at `.error`. The alternative was losing
user data to protect a file the OS had already made unreadable.

## 002 — Nothing that needs macOS runs automatically

See [`docs/CI_POSTURE.md`](../CI_POSTURE.md), which carries the arithmetic
(macOS bills at 10×; one full run is ~1,080 billable minutes against a
3,000-minute cap) and the accepted costs. The script gates that need no
Xcode run on a Linux runner on every push (`.github/workflows/gates.yml`);
the build, test, sanitizer and coverage jobs stay manual.

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

Twenty-eight helper types kept `unowned` back-pointers to their owners and two
of them crashed the unit suite from resumed continuations. They are values now,
holding the owner strongly and built on demand, and a gate bans `unowned`.

See [`005-no-unowned-back-references.md`](005-no-unowned-back-references.md).
