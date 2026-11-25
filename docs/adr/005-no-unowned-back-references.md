# 005 — Helpers hold no back-reference, or hold their owner strongly; `unowned` is banned

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

1. A part takes the owned state objects and services it uses, not its owner,
   and the owner builds it once and keeps it: the collector's coordinators,
   the workout recorder's ticker, session lifecycle and coach context, the
   strap's link and recording coordinators, and the HealthKit query types. It
   has no back-pointer to trap on, and its timers and tasks capture it weakly.
   A helper that must reach its owner is a `struct` holding the owner
   **strongly**, built on demand; the owner does not retain it, so there is no
   cycle, and it cannot outlive what it points at.
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
- A helper that holds its owner is a value. It carries no state, and the
  compiler rejects `[weak self]` inside it, so every capture has to be decided
  explicitly. A part that holds no owner states its dependencies in its
  initializer, and the coupling budget (`scripts/check_coupling_budget.sh`)
  counts any part that holds a whole hub instead.
- `weak` remains available for a genuinely optional back-reference, and a
  few owners use it (for example `WorkoutVoiceCoach`, `BeatConsistencyPriorsCache`,
  `TrainingMetricsCache`).
