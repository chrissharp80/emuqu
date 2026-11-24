# 005 — Helpers hold their owner strongly; `unowned` is banned

## Context

Many helper types sit beside their owners to keep the owning types under the
aggregate size limit: the collector's recovery, streaming, morning and
session-control coordinators, the HealthKit query groups, the workout ticker
and finalizer, the PDF renderers, the archive store and migrations, the cloud
pull and deletion coordinators, the assistant's router and tool runner. An
`unowned let` back-pointer from such a helper looks safe "because the owner
outlives it".

That holds on every synchronous path and fails on the asynchronous one. A
`Task` or a resumed continuation can keep the helper alive after its owner
has been released; the next read of the back-pointer traps:

    Fatal error: Attempted to read an unowned reference but object … was
    already destroyed

A launch-time migration the collector starts in its own initialiser is enough
to hit it. Fixing only the sites a crash report names leaves every other helper
with the same shape.

## Decision

1. Every helper is a `struct` holding its owner **strongly**, built on demand
   by the owner (`collector.control`, `manager.writes`, `recorder.ticker`, …).
   The owner does not retain the helper, so there is no cycle; the helper
   cannot outlive what it points at, so there is nothing to trap on.
2. Callbacks the owner stores — Combine sinks in its `cancellables`, timers,
   notification tokens, HealthKit query handlers — capture the **owner
   weakly** and rebuild the helper when they fire. A strong capture there
   would be a cycle; a weak one no-ops once the owner is gone.
3. Fire-and-forget tasks launched from a helper capture the owner strongly for
   their duration. A one-time migration or an upload should keep its owner
   alive until it finishes; that is the point of running it.
4. `unowned` is not used in app source. The `no_unowned` SwiftLint rule fails
   the build on any occurrence, and `verify_gates_fail.sh` proves that gate
   goes red on a planted one.

## Consequences

- The class of bug is removed rather than its instances. No coordinator can
  read a freed owner, whatever the async path.
- The helpers are values. They carry no state, and the compiler rejects
  `[weak self]` inside them, so every capture has to be decided explicitly.
- `weak` remains available for a genuinely optional back-reference, and a
  few owners use it (for example `WorkoutVoiceCoach`, `BeatConsistencyPriorsCache`,
  `TrainingMetricsCache`).
