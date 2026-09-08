# ADR 006 — Swift 6 language mode is the concurrency gate

**Status.** Accepted.

**Context.** The app talks to a heart-rate strap, HealthKit, CoreLocation,
WatchConnectivity, the Translation framework and several cloud APIs, and it
does most of its analysis off the main actor. Until now the project compiled
in Swift 5 mode with `targeted` strict concurrency: isolation errors failed
the build, but a non-`Sendable` value crossing an actor boundary was a
warning, and warnings were budgeted rather than fixed. A budget of
warnings about data races is a list of data races nobody has looked at.

**Options.**

1. Keep Swift 5 mode and ratchet the `complete` diagnostic count down over
   time. Cheap, but every diagnostic stays a warning until the count reaches
   zero, and a new one is a number going up, not a red build.
2. Move to Swift 6 language mode with `complete` strict concurrency in every
   build configuration. Every diagnostic is a compile error; the only way to
   ship a race is to write `@unchecked Sendable` or `nonisolated(unsafe)`,
   which the allowlist gate (ADR 003) counts and names.
3. Mark the long-lived stores `@unchecked Sendable` and move on. Silences
   the compiler without changing what it was warning about.

**Decision.** Option 2. The tree was brought to zero diagnostics first, then
the setting was flipped in all ten configurations, and
`check_strict_concurrency_enabled.sh` fails CI if any configuration leaves
Swift 6 mode or `complete`. The patterns that got the tree to zero are
recorded in `docs/ARCHITECTURE.md` ("Swift 6 language mode"): main-actor
stores with lock-backed `nonisolated` snapshots, `Sendable` analysis types,
one documented handle for the thread-safe-but-undeclared Polar SDK object,
SDK values kept inside a single `nonisolated` region, and framework payloads
crossing isolation as plain values.

**Consequences.** The escape count fell from 30 to the figure in `.ci/unchecked_sendable_budget.txt`. Everything whose
state could sit in an `OSAllocatedUnfairLock` now does (caches, flags,
the language manager's locale and bundle, the test-override store); what
remains is either an SDK contract the framework does not declare
(`StrapAPI`, the WhisperKit feeder, `AmbientLocationService`'s
CLLocationManager delegate) or a store whose guarded state holds
non-`Sendable` framework values (`MKPolyline` in `ActiveRouteSession`,
encoder/decoder pairs in the backups, `SessionArchive`, `BaselineTracker`)
or is confined to a serial queue it names (`ConversationStore`,
`SystemDiagnosticsManager`, `KeyboardPerfSignpost`). The allowlist gate holds
the count (read from `.ci/unchecked_sendable_budget.txt`) and lists only files that still carry an escape. A background reader of user settings must
use `settingsSnapshot`, not `settings`; the compiler enforces this. The
counting build that once measured diagnostics against a budget is retired: the
compiler is the gate, and the enabled-check only proves it is switched on.
