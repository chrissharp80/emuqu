# ADR 007 — One app target, one composition root

**Status.** Accepted.

**Context.** The iPhone app's code sits in layers by directory under
`Emuqu/Sources/` (`Collection`, `Analysis`, `Storage`, `Services`,
`Assistant`, `Views` and the rest), and its long-lived services are
process-wide objects, each declared as `static let shared`. Two questions
follow: whether those layers should be separate modules, and how code that
needs a service reaches it. Reading `Type.shared` wherever a service is used
leaves nowhere to substitute one in a test and no single place that says who
depends on what.

**Options.**

1. Split the layers into local Swift packages or framework targets, so the
   module boundary enforces the layering.
2. Keep the app in one target and give it one composition root that every
   service is reached through.
3. Keep one target and keep `Type.shared` reads where they are.

**Decision.** Option 2.

*One target.* `Emuqu.xcodeproj` has four native targets: `Emuqu` (the iPhone
app), `EmuquTests` (unit tests), `EmuquUITests` (UI tests) and
`EmuquWatch Watch App`. Every iPhone source file compiles into `Emuqu`, one
Swift module; its only other modules are the remote packages `PolarBleSdk`
and `WhisperKit`. `EmuquTests` reaches the app through `@testable import
Emuqu` and compiles one Watch file, `WatchMessageDecoding.swift`, to test it.
The Watch app is a separate target and module built from its own folder,
which Xcode adds file by file (a synchronised folder), with
`SWIFT_DEFAULT_ACTOR_ISOLATION = MainActor`; it compiles no iPhone source. A
package split was not taken because the layers are not a one-way stack: the
composition root names a service from nearly every layer, and code in
`Collection`, `Storage`, `Services`, `Assistant` and `Views` reaches services
of other layers through it. As modules, each of those services would need a
`public` interface, and each cross-layer reach a protocol or a move. The
layers stay directories, and the root below is where their dependencies on
one another are written down.

*One composition root.* `AppDependencies`
(`Emuqu/Sources/Utilities/AppDependencies.swift`) groups the services by
layer as `app`, `analysis`, `assistant`, `collection`, `location`,
`providers`, `services` and `storage`. Each accessor returns the substitute
set on the container's `overrides`, if any, and otherwise the type's
`shared` instance (or, for the two Overpass services, the one instance the
root builds around a shared `OverpassClient`). Accessors resolve when they
are read, so nothing is built before it is asked for. `AppDependencies.current`
is the container in force, held behind a lock because fact resolvers read it
off the main actor. The app never assigns it; a test builds a fresh
container, sets its substitutes on `overrides`, assigns it to `current`, and
calls `AppDependencies.reset()` when it finishes.

Views read the container through the `\.dependencies` environment key. Its
default value is computed, `AppDependencies.current` at the moment of the
read, so a container a test installs reaches views without anything injecting
it; a preview or test can still set `.environment(\.dependencies, ...)`.
Classes take their services as `init` parameters defaulting to
`AppDependencies.current`, and static helpers read `AppDependencies.current`.
The app struct, `EmuquApp`, builds its root-level state objects the same way.

The Watch target cannot see `AppDependencies`, so it has its own root in the
same shape, `WatchDependencies` (`EmuquWatch Watch App/WatchDependencies.swift`),
for its session manager and strap connector. `WatchApp` reads it at launch and
hands the objects to the view tree.

`scripts/check_no_shared_outside_root.sh` (`make shared-root-guard`, run by
`make ci`, `gates.yml` and `ci.yml`) fails when any Swift file in either app reads `.shared` outside the two root
files. Declaring `static let shared` is allowed anywhere, and system
singletons (`URLSession.shared`, `UIApplication.shared` and the others the
script lists) are not the app's to inject.

**Consequences.** A test can replace any long-lived service without touching
the code that uses it, and a new reach for a singleton fails CI. Every service
stays a process-wide object reachable from anywhere through `current`, so the
root records the dependencies but does not narrow them: what a type uses is
read from its accessors, not enforced by a module boundary.
