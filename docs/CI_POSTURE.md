# CI posture

Every pull request and every push to `main` runs two workflows:

- `gates.yml`: the script gates that need only bash and python (copy perimeter,
  science register, scoring governance, localization, documentation, SBOM,
  source-hygiene guards, the code map, the tech-debt budgets and refactor-spec
  conformance) on an **ubuntu** runner in about a minute. It is the status
  check `main` requires before anything merges.
- `ci.yml` at scope `unit`: SwiftLint and the budgets, strict concurrency, the
  macOS build, the unit suite with the Views coverage floor, and the unit suite
  under Thread Sanitizer, on GitHub's standard macOS runner. The jobs run in
  parallel; a run takes about 15–20 minutes.

The repository is public, and standard GitHub-hosted runners cost public
repositories no Actions minutes. The UI target and the full coverage floors
(scope `full`, about 90 minutes) run on demand and before every release.

## The arithmetic, while the repository was private

Until the repository went public, macOS Actions minutes billed at **10×** the
Linux rate against a 3,000-minute plan, about **300 macOS minutes a month**. A
full run of the macOS jobs (`tests`, `thread-sanitizer`, `lint-and-budgets`)
was ~108 wall-clock minutes, about 1,080 billable (run 33202282889): fewer than
three full runs a month. That is why `ci.yml` was manual-only and why it has a
`scope` input. Public repositories are not billed for standard GitHub-hosted
runners, so the constraint no longer applies; the scopes remain because the UI
target is still the slow part of a run.

## What actually enforces quality here

The checks did not go away. They moved to the machine that can afford to run
them:

```bash
make ci
```

That runs **every gate plus the full test suite** — the identical scripts CI
invokes, against the identical budget files in `.ci/`. On the developer's Mac it
costs nothing and takes about forty minutes.

`./scripts/evidence_report.sh` prints the live counts; nothing in this document
restates a number the tooling already knows, because a restated number rots.

### Running CI locally before pushing

```bash
make ci-local          # every gate, ~2 minutes, free
make ci-local-unit     # the above plus the unit suite
```

`scripts/simulate_ci.sh` **parses `.github/workflows/ci.yml` and executes its
`run:` blocks in order**. It keeps no list of its own, so it cannot drift from
the workflow: a step added to CI is picked up automatically, and a step it does
not know how to run locally is a hard error rather than a silent skip. Only two
steps are genuinely unrunnable on a developer machine — selecting the runner's
Xcode and `brew install` — and neither can fail a build.

Run it **after committing**: the budget-ratchet gate compares `HEAD` against
`HEAD~1`, so an uncommitted budget change is invisible to it exactly as it would
be on the runner. The script says so when the tree is dirty.

### The gates

Grouped by what they protect. Every one is a script in `scripts/`, run
identically by `make ci`, `make ci-local`, and GitHub Actions.

| Area | Gates |
| --- | --- |
| **Style & debt** | SwiftLint budget, tech-debt budgets, budget monotonicity, refactor-spec conformance, aggregate type size, fixed-point font budget, test-skip budget |
| **Correctness traps** | Empty-range loops (`1 ..< count` on a possibly-empty collection), unchecked `Sendable`, strict-concurrency enablement, orphaned Swift files |
| **Privacy & safety** | No health data in CloudKit, log redaction, no developer endpoint, privacy-manifest vocabulary, Info.plist key drift, FDA copy perimeter + runtime-guard sync |
| **Localization** | Coverage across every locale, bundle reachability, literal resolution, orphaned catalogue keys, locale-aware decimal formatting |
| **Supply chain** | SBOM currency, SBOM drift against `Package.resolved` and the in-app acknowledgements |
| **Documentation** | Link and constant integrity, comment `file:line` citations resolve, documented file counts match the tree |
| **Change tracking** | Code map: every function, script, workflow step and doc section has a record written after its code last changed, and records whose callees changed since are listed for re-check |
| **Tests about the tests** | Snapshot references committed, UI-test fresh-install reset, coverage floors (overall / logic / views) |
| **The gates themselves** | `verify_gates_fail.sh` plants a violation per gate and requires each to go red; `check_gate_preflight.sh` requires each to fail closed on a missing input; `check_gates_wired.sh` requires each to actually run in `ci.yml` |

The last row is the one that matters most. A gate that passes because it is
measuring nothing is worse than no gate, because it is documented as protection.

Every gate has a plant except two that need a build or a simulator
(`check_coverage.sh`, `check_thread_sanitizer.sh`), which are verified by their
own CI runs. `check_uitest_fresh_install.sh` is a static grep that runs on
Ubuntu, so it has a plant like the rest. Every planted violation goes red.

A gate that covers one of two shapes of its subject reports a clean tree it has
not read, so every widening of a gate ships with its own plant.
`verify_gates_fail.sh` ends by enumerating `scripts/check_*.sh` and
`scripts/enforce_*.sh` and failing if any of them has no plant and no recorded
reason for the exemption. Adding a gate and proving it are one change.

`check_budget_monotonicity.sh` skips when given no baseline. To check
uncommitted budget edits, pass one explicitly:
`check_budget_monotonicity.sh HEAD`.

### Three questions, not one

A gate is worth its runtime only if all three have an answer:

| Question | Answered by |
|---|---|
| Does it go red on a real violation? | `verify_gates_fail.sh` — a planted violation per gate |
| Does it fail closed when its input is missing? | `check_gate_preflight.sh` |
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

The delete that runs before every HR re-export in `HealthKitManager+HeartRate`
decides what gets erased from the user's permanent Health record. Its naming
scheme is one type, `HealthExportIdentity`, whose tests enumerate every metric
the app writes and assert that no metric's delete reaches another metric's
samples, or another session's — a property that extends itself to any metric
added later, rather than to the pairs someone happened to think about.

`verify_tests_fail.sh` needs a build and a simulator per mutation, so it is not
in `make ci`. Run
it when the analysis or storage code changes.

### Runs are scoped, because a full one is expensive

`ci.yml` takes a `scope` on dispatch; pull requests and pushes run `unit`.
Billable minutes as measured on run 33202282889, while the repository was
private (a public repository is not billed for these runners):

| scope | what runs | billable minutes |
|---|---|---|
| `gates` (dispatch default) | lint, budgets, strict concurrency | ~14 |
| `unit` | + unit suite and Thread Sanitizer | ~300 |
| `full` | + UI target and the coverage floors | ~1080 |

macOS bills at 10x, and 66 of the tests job's 88 minutes are the UI target on
its own — 61% of a whole run for the part least likely to catch a regression in
a given change.

`workflow_call` still defaults to `full`, so the TestFlight deploy gate is
unchanged: a release is checked against everything, exactly as before.

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
- `testflight.yml` calls `ci.yml` as a reusable workflow at scope `full`, so a
  release cannot be cut without the full suite, UI target included, passing
  first.
- `security.yml` (CodeQL) is run on demand when a security pass is wanted.

## What this posture does *not* claim

- **The UI target does not run on every pull request.** A pull request gets the
  macOS build, the unit suite with the Views coverage floor and Thread
  Sanitizer; the UI flows and the overall and logic coverage floors run only at
  scope `full`, on demand and before every release. A change that breaks only
  a UI flow can reach `main` and is caught at the latest by the release gate.
  `make ci` runs the full suite locally, which is a discipline, not an
  enforcement.
- **The macOS jobs are not required checks.** `main` requires only the Linux
  `gates.yml` job. A red `ci.yml` run on a pull request is visible on the pull
  request but does not block the merge by itself.

## For reviewers

The macOS build, the unit suite and Thread Sanitizer run on every pull request
and every push to `main`; the UI target runs on demand and before a release.
`main` is protected by one required check, the Linux `gates.yml` job; nothing
that needs macOS is required.

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

If your finding is *"the macOS jobs should be required checks on `main`"*, the
sequence is: the jobs run on every pull request → a record of green runs →
then require them. The Linux `gates.yml` job went through that sequence and is
required; the macOS jobs are at the first step.

`sbom.spdx.json` covers the app and its 11
resolved packages with versions, commit SHAs, Package URLs and licences, and
`make sbom-check` fails if it goes stale. It is not signed and carries no build
provenance — both need a release pipeline that runs.
