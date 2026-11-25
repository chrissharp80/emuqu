# CI posture

Every pull request and every push to `main` runs two workflows:

- `gates.yml`: the script gates that need only bash and python (copy perimeter,
  science register, scoring governance, localization, documentation, SBOM,
  source-hygiene guards, the tech-debt budgets, refactor-spec conformance,
  and the Python ports of the analysis code against the Swift tests'
  expectations) on an **ubuntu** runner in a minute or two.
- `ci.yml` at scope `unit`: SwiftLint and the budgets, strict concurrency, the
  macOS build, the unit suite with the Views coverage floor, and the unit suite
  under Thread Sanitizer, on GitHub's standard macOS runner. The jobs run in
  parallel; a run takes 30 to 40 minutes, set by Thread Sanitizer and the tests
  job, which each take 20 to 40 minutes on a runner.

`main` requires every job that runs on a pull request to pass, on a branch that is up to date with `main`, before anything merges: the `gates.yml` job ("Script gates (no Xcode)") and the five `ci.yml` jobs ("Lint + tech-debt budgets", "Strict concurrency enabled", "Release build", "Thread Sanitizer", "Tests + coverage").

The repository is public, and standard GitHub-hosted runners cost public
repositories no Actions minutes. The UI target and the full coverage floors
(scope `full`, about two hours on current runners) run on demand and before every release.

## What actually enforces quality here

Everything `ci.yml` runs also runs on the developer's Mac:

```bash
make ci
```

That runs **every gate, the Release build, the unit suite under Thread
Sanitizer, and the full test suite** (UI target and all three coverage floors)
— the identical scripts CI invokes, against the identical budget files in
`.ci/`. It costs nothing, and Thread Sanitizer and the UI target make it the
slow part of a day. It is a discipline, not an enforcement: nothing records
that it ran. Two differences from GitHub are deliberate: it runs the test suite
at scope `full` where a pull request runs `unit`, and the budget ratchet
compares with the branch's merge base with `origin/main` (below) where CI
compares with the parent commit or the pull request's base.

`./scripts/evidence_report.sh` prints the live counts; nothing in this document
restates a number the tooling already knows, because a restated number rots.

### Running CI locally before pushing

```bash
make ci-local          # scope gates: every gate, ~2 minutes, free
make ci-local-unit     # scope unit: the above plus the Release build, the unit suite and Thread Sanitizer
```

`scripts/simulate_ci.sh` **parses `.github/workflows/ci.yml` and executes its
`run:` blocks in order**. It keeps no list of its own, so it cannot drift from
the workflow: a step added to CI is picked up automatically, and a step it does
not know how to run locally is a hard error rather than a silent skip. Which
jobs run comes from each job's own `if:`, evaluated against the scope, so the
script runs the same jobs GitHub runs for that scope. Only two steps are
genuinely unrunnable on a developer machine — selecting the runner's Xcode and
installing the pinned SwiftLint onto the runner's `PATH` — and neither can fail
a build.

Run it **after committing**: the budget-ratchet gate compares `HEAD` against
`HEAD~1`, so an uncommitted budget change is invisible to it exactly as it would
be on the runner. The script says so when the tree is dirty.

### The gates

Grouped by what they protect. Every one is a script in `scripts/`, run by
`make ci`, `make ci-local`, and GitHub Actions; only the budget ratchet's
baseline differs between them (below).

| Area | Gates |
| --- | --- |
| **Style & debt** | SwiftLint budget, tech-debt budgets (the Watch target against its own combined ceiling; every debt ceiling a whole number), budget monotonicity, refactor-spec conformance, the SwiftLint custom rules (no `unowned`, no dated or licence comments, no raw date-to-milliseconds conversion), fixed-point font budget, test-skip budget |
| **Correctness traps** | Empty-range loops (`1 ..< count` on a possibly-empty collection), unchecked `Sendable`, strict-concurrency enablement, orphaned Swift files |
| **Privacy & safety** | No health data in CloudKit, log redaction, no developer endpoint, privacy-manifest vocabulary, Info.plist key drift, FDA copy perimeter + runtime-guard sync |
| **Localization** | Coverage across every locale, bundle reachability, literal resolution, orphaned catalogue keys, locale-aware decimal formatting |
| **Supply chain** | SBOM currency, SBOM drift against `Package.resolved` and the in-app acknowledgements, every `xcodebuild` run pinned to `Package.resolved` |
| **Documentation** | Link and constant integrity |
| **Tests about the tests** | Snapshot references committed, UI-test fresh-install reset, coverage floors (overall / logic / views) |
| **The gates themselves** | `verify_gates_fail.sh` plants a violation per gate and requires each to go red; `check_gates_wired.sh` requires each to actually run in `ci.yml` |

The last row is the one that matters most. A gate that passes because it is
measuring nothing is worse than no gate, because it is documented as protection.

Every gate has a plant except `check_coverage.sh`, which needs a real build and
is verified by its own CI runs. `check_thread_sanitizer.sh` is planted against a
stand-in `xcodebuild`: a race in the suite, and each of the two settings that
make a race visible (serial testing, so the report reaches the log, and
`TSAN_OPTIONS=halt_on_error=1`, so it fails the run) removed from the gate. On a
real run the gate proves the same two things first with a canary,
`EmuquTests/ThreadSanitizerCanaryTests`, which races on purpose; it fails unless
that race is reported and fails its run. `check_uitest_fresh_install.sh` is a static grep that runs on
Ubuntu, so it has a plant like the rest. Every planted violation goes red.

A gate that covers one of two shapes of its subject reports a clean tree it has
not read, so every widening of a gate ships with its own plant.
`verify_gates_fail.sh` ends by enumerating `scripts/check_*.sh` and
`scripts/enforce_*.sh` and failing if any of them has no plant and no recorded
reason for the exemption. Adding a gate and proving it are one change.

`check_budget_monotonicity.sh` skips when given no baseline. `make
budget-monotonicity` passes one: the merge base of `HEAD` and `origin/main`, so
a raise already committed on the branch is compared as well as an uncommitted
one, or `HEAD` alone (and it says so) in a clone with no `origin/main`.
`BUDGET_BASE_REF=<ref>` overrides it. `ci.yml` compares with the parent commit;
`gates.yml` with the pull request's base or the tip before the push.

### Three questions, not one

A gate is worth its runtime only if all three have an answer:

| Question | Answered by |
|---|---|
| Does it go red on a real violation? | `verify_gates_fail.sh` — a planted violation per gate |
| Does it fail closed when its input is missing? | `scripts/lib/preflight.sh`, which every gate sources |
| Does CI actually run it? | `check_gates_wired.sh` |

### Two things must not read the tree at the same time

`verify_gates_fail.sh` and `verify_tests_fail.sh` edit tracked source in place
and restore it in an `EXIT` trap. Two things follow from that:

* A killed run skips the trap and leaves the mutation applied.
  `check_no_leaked_mutations.sh` is the backstop, and it reads every mutation
  case.
* Anything reading the tree *while* one of them runs sees a planted violation as
  a real one.

Both harnesses now take a lock (`.git/emuqu-tree-mutation.lock`) and
`simulate_ci.sh` refuses to start while it is held. A lock whose owner process
is gone is stale: it is taken over, with a warning that the killed run never
restored and the tree should be checked.

### The tests are checked too, not just the code

`scripts/verify_gates_fail.sh` proves each gate goes red on a planted
violation. `scripts/verify_tests_fail.sh` applies the same discipline to the
test suite: it changes the meaning of production code and requires the tests to
notice.

Coverage cannot answer this question. Coverage says a line executed, not that
any assertion depended on its result — a suite can execute every line of a
scoring function and still pass when the scores come out inverted.

It is deliberately not a mutation-testing framework. A framework mutates
everything and reports a percentage, which on a codebase this size is a number
nobody acts on and a bill nobody wants. This mutates a small chosen set of
high-stakes behaviours and requires each to be caught, so a survivor names a
specific unasserted behaviour rather than moving a statistic.

Every mutation in it is required to be caught: the pNN50 threshold, SDNN,
RMSSD, the normalized-power fourth-root, the comparison that picks a recovery
label, and the branch that decides whether a session is written encrypted,
among others. Weakening the protection class of the encrypted write fails the
suite.

Logic lifted out of large types gets mutations of its own, because new tests are
worth what a mutation run says they are worth and nothing more. Two rules come
from that:

* **A test that exercises a disjunction only in aggregate has not tested any of
  its terms.** `TrackBackupWatermark` compares three cursors with `||`; its test
  drops one dimension at a time, and there is a mutation per clause.
* **A branch you can only reach by accident is a branch you are not
  testing.** The recovery merge's "keep whichever has more beats" tie-break
  sits behind `DataSourceSelector`, which answers first for every input it can
  judge, so the tie-break is its own function with its own test.

### Where to point it next: at the comments that claim something is subtle

`RRDataImporter+CSV.rrValue` carries a doc comment naming three asymmetries as
load-bearing and "easy to tidy away by accident" — a header-named RR column is
trusted verbatim, an unheadered two-column guess is range-checked, and the
first-column fallback fires on a parse failure but not on a range failure. That
comment is a claim about what the tests would catch, so it is a claim worth
mutating. Tests pin all three asymmetries, and the three mutations are
permanent.

The same applies to `WorkoutMileMarkerEngine`, whose zone label the assistant
speaks aloud mid-workout. Its zone math must not use the session-observed peak
HR as the denominator: ten minutes into an easy walk the peak equals the current
HR, so every walk would read as VO2max. Tests pin the denominator, the band
edges and the no-heart-rate case, and a mutation swaps the denominator back.

A comment that says "careful, this is subtle" is a lead, not a safeguard.

The delete that accompanies every re-export to Apple Health
(`HealthSampleReplacer`: read the earlier samples, save the new ones, delete the
earlier ones the save did not replace through their sync identifier) decides
what gets erased from the user's permanent Health record. Its naming
scheme is one type, `HealthExportIdentity`, whose tests enumerate every metric
the app writes and assert that no metric's delete reaches another metric's
samples, or another session's — a property that extends itself to any metric
added later, rather than to the pairs someone happened to think about.

`verify_tests_fail.sh` needs a build and a simulator per mutation, so it is not
in `make ci` or on pull requests. It is its own workflow, `mutations.yml`: every
TestFlight deploy waits for it, and it can be dispatched by hand. At about seven
minutes a mutation it runs as six parallel jobs, each one share
(`MUTATION_SHARD=<index>/<count>`), and every share must pass. Run it when the
analysis or storage code changes.

### Runs are scoped, because a full one is expensive

`ci.yml` takes a `scope` on dispatch; pull requests and pushes run `unit`.
Approximate billable minutes per scope at macOS rates (a public repository is
not billed for these runners):

| scope | what runs | billable minutes |
|---|---|---|
| `gates` (dispatch default) | lint, budgets, strict concurrency | ~14 |
| `unit` | + unit suite and Thread Sanitizer | ~300 |
| `full` | + UI target and the coverage floors | ~1080 |

macOS bills at 10x, and 66 of the tests job's 88 minutes are the UI target on
its own — 61% of a whole run for the part least likely to catch a regression in
a given change.

`workflow_call` defaults to `full`, so the TestFlight deploy gate checks a
release against everything.

### The compiler is one of the gates

`scripts/run_tests_with_coverage.sh` passes
`-warn-long-expression-type-checking` and `-warn-long-function-bodies` to the
build it already runs, so a Swift expression that is slow to type-check fails
CI as a named diagnostic rather than as the frontend's hard limit.

The spec-conformance scan covers the whole app target, including
`Emuqu/EmuquApp.swift`, which sits outside `Emuqu/Sources`, and
`verify_gates_fail.sh` plants a violation in that file so the scan cannot
narrow back without going red. The flags are passed on the command line
rather than set in the project, so a local `xcodebuild archive` for the App
Store can never fail because a runner was busy.

**Nothing is waived.** There are zero `swiftlint:disable` directives in
`Emuqu/Sources`. Budgets ratchet downward only, and `check_budget_monotonicity.sh`
fails a raise that has no written justification.

## Where GitHub Actions is still used

- Every pull request and push to `main`: `gates.yml` and `ci.yml` (`unit`).
- `testflight.yml` calls `ci.yml` as a reusable workflow at scope `full`, and
  `mutations.yml`, so a release cannot be cut without the full suite, UI target
  included, passing and every mutation caught first. Its deploy job runs in the `testflight` environment: only `main` can
  deploy to it, the owner has to approve each run, and the signing and App
  Store Connect secrets live there. The deploy job's own `if:` requires `main`
  too, and its last step removes the signing keychain and keys whatever the
  outcome.
- `security.yml` (CodeQL and dependency review) is run on demand when a
  security pass is wanted. The dependency review fails unless every package
  pinned in `Package.resolved` is in the repository's dependency-graph SBOM,
  since a graph without them would review nothing for them.

## What this posture does *not* claim

- **The UI target does not run on every pull request.** A pull request gets the
  macOS build, the unit suite with the Views coverage floor and Thread
  Sanitizer; the UI flows and the overall and logic coverage floors run only at
  scope `full`, on demand and before every release. A change that breaks only
  a UI flow can reach `main` and is caught at the latest by the release gate.
  `make ci` runs the full suite locally, which is a discipline, not an
  enforcement.
- **The UI flows are not a required check.** `main` requires the
  `gates.yml` job and the five `ci.yml` jobs at scope `unit` (lint and
  budgets, strict concurrency, the Release build, Thread Sanitizer, tests with
  coverage). The UI flows and the full coverage floors run only at scope
  `full`.

## For reviewers

The macOS build, the unit suite and Thread Sanitizer run on every pull request
and every push to `main`; the UI target runs on demand and before a release.
`main` requires six checks to pass on a branch that is up to date with it:
the Linux `gates.yml` job and the five `ci.yml` jobs.

For a fast, factual snapshot of what is enforced — every ceiling, every
zero-tolerance counter, and where each is written down:

```bash
./scripts/evidence_report.sh          # human-readable
./scripts/evidence_report.sh --json   # machine-readable
```

It runs no builds and takes seconds. It deliberately omits coverage and
pass/fail, because those need a real run and a cached number would be a
stale claim dressed as a current one.

If your finding is *"there is no evidence the checks pass"*, look at the `CI`
run on the pull request, or on the commit for a push to `main`. Its run summary
has one line per macOS job with the scope and the result. For the UI target
and the full coverage floors, ask for a run at scope `full`.

`sbom.spdx.json` covers the app and its 11
resolved packages with versions, commit SHAs, Package URLs and licences, and
`make sbom-check` fails if it goes stale. It is not signed and carries no build
provenance — both need a release pipeline that runs.
