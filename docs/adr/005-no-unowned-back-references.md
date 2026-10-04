# 005 — Helpers hold their owner strongly; `unowned` is banned

## Context

Twenty-eight helper types — the collector's recovery, streaming, morning and
session-control coordinators, the HealthKit query groups, the workout ticker
and finalizer, the PDF renderers, the archive store and migrations, the cloud
pull and deletion coordinators, the assistant's router and tool runner — were
split out of their owners in August 2026 to bring the owning types under the
aggregate size limit. Each held an `unowned let` back-pointer, documented as
safe "because the owner outlives it".

That was true on every synchronous path and false on the asynchronous one. A
`Task` or a resumed continuation could keep the helper alive after its owner
had been released; the next read of the back-pointer trapped:

    Fatal error: Attempted to read an unowned reference but object … was
    already destroyed

It reproduced in four observable-state tests on 2026-09-02 and again in the
unit suite on 2026-09-03, from a launch-time migration the collector kicked
off in its own initialiser. Fixing the two sites the crash reports named would
have left twenty-six more with the same shape.

## Decision

1. Every helper is a `struct` holding its owner **strongly**, built on demand
   by the owner (`collector.control`, `manager.writes`, `recorder.ticker`, …).
   The owner does not retain the helper, so there is no cycle; the helper
   cannot outlive what it points at, so there is nothing to trap on.
2. Callbacks the owner stores — Combine sinks in its `cancellables`, timers,
   notification tokens, HealthKit query handlers — capture the **owner
   weakly** and rebuild the helper when they fire. A strong capture there
   would be a cycle; a weak one no-ops once the owner is gone, which is the
   behaviour the old `[weak self]` sinks had.
3. Fire-and-forget tasks launched from a helper capture the owner strongly for
   their duration. A one-time migration or an upload should keep its owner
   alive until it finishes; that is the point of running it.
4. `unowned` is not used in app source. `scripts/check_no_unowned.sh` fails
   the build on any occurrence, and `verify_gates_fail.sh` proves that gate
   goes red on a planted one.

## Consequences

- The class of bug is removed rather than its instances. No coordinator can
  read a freed owner, whatever the async path.
- The helpers are values. They carry no state, and the compiler now rejects
  `[weak self]` inside them, which is what surfaced every capture that had to
  be reconsidered during the change.
- `weak` remains available for a genuinely optional back-reference, and a
  few owners use it (for example `WorkoutVoiceCoach`, `BeatConsistencyPriorsCache`,
  `TrainingMetricsCache`).
