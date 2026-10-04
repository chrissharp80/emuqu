# CI posture — why the macOS suite does not run automatically

**Read this before filing a finding about missing CI automation or branch protection.**

Every macOS workflow in `.github/workflows/` is `workflow_dispatch` only. There
is no push trigger, no pull-request trigger, and no schedule for anything that
needs Xcode. The `main` branch has no required status checks and no required
reviews.

The one exception is `gates.yml`: the script gates that
need only bash and python — copy perimeter, science register, scoring
governance, localization, documentation, SBOM, source-hygiene guards, the
tech-debt budgets and refactor-spec conformance — run on every push and pull
request on an **ubuntu** runner, in about a minute, billed at 1x. It is a fast
subset, not a replacement: SwiftLint, the tests, coverage and the sanitizer
still need macOS and still run on demand.

That is deliberate, it is costed, and the checks themselves are neither missing
nor weakened. This page exists so the reasoning is in the repository rather than
being re-derived — or misread — by each new reviewer.

## The arithmetic

macOS GitHub Actions minutes bill at **10×**. A 3,000-minute plan is therefore
about **300 macOS minutes a month**.

A full run of this repository's macOS CI jobs (`tests`, `thread-sanitizer`,
`lint-and-budgets`) is ~108 wall-clock minutes, about 1,080 billable.

About 1,080 billable minutes against three thousand is **fewer than three runs a
month, for everything** (measured on run 33202282889; see "Runs are scoped"
below) — and that is before a release build, which is the one thing that
genuinely needs a machine that is not the developer's.

On a push trigger, the allowance is gone in under a week and nothing runs for
the rest of the month. That is not hypothetical: it is what happened to this
codebase under its previous name, and it is why every CI run in this
repository's visible history failed before a runner was ever allocated. The
jobs were not broken. There was no budget left to start them.

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

### Running CI locally before paying for it

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
| **Tests about the tests** | Snapshot references committed, UI-test fresh-install reset, coverage floors (overall / logic / views) |
| **The gates themselves** | `verify_gates_fail.sh` plants a violation per gate and requires each to go red; `check_gate_preflight.sh` requires each to fail closed on a missing input; `check_gates_wired.sh` requires each to actually run in `ci.yml` |

The last row is the one that matters most. A gate that passes because it is
measuring nothing is worse than no gate, because it is documented as protection.

That sentence used to be aspirational. On 2026-09-01 there were **nineteen
gates in `scripts/` with no planted violation at all** — added, wired into
`ci.yml`, and trusted, without anyone ever watching one fail. Two of the
nineteen turned out to be measuring less than they claimed:

* `check_budget_monotonicity.sh` skips when given no baseline, and a comment in
  it said local runs still got a working-tree-vs-`HEAD` comparison "for free".
  They did not — with no baseline the function exits before reading a single
  file. Pass one explicitly: `check_budget_monotonicity.sh HEAD`.
* `check_no_leaked_mutations.sh` reported one case as "not literal-comparable"
  next to the word *clean*. That case was the normalized-power formula, and it
  had never been checked. An unreadable case is now fatal rather than a note.

Every gate now has a plant except two that need a build or a simulator
(`check_coverage.sh`, `check_thread_sanitizer.sh`), which are verified by their
own CI runs. `check_uitest_fresh_install.sh` is a static grep that runs on
Ubuntu, so it has a plant like the rest. Every planted violation goes red.

Writing the plants also found three gates measuring one half of their own
subject, each of which had reported clean for as long as it had existed:

| Gate | What it was not seeing | Live instances found |
|---|---|---|
| `check_empty_range_loops.sh` | `for i in 0 ..< (xs.count - N)` — the same trap as `1 ..< xs.count`, wearing a different shape | 6 |
| `check_comment_citations.sh` | `File.swift:NNN` in Markdown; it read Swift comments only | 26 |
| `check_doc_links.sh` | a cited path with a `:NNN` tail, which its pattern could not match at all — so a line number hid a wrong directory indefinitely | 26 |

A gate that covers one of two shapes reports a clean tree it has not read. That
is the same finding as this file's original three, and it is why every widening
above ships with its own plant.

Remembering to add a plant is what produced the list of nineteen, so
`verify_gates_fail.sh` now ends by enumerating `scripts/check_*.sh` and
`scripts/enforce_*.sh` and failing if any of them has no plant and no recorded
reason for the exemption. Adding a gate and proving it are one change.

### Three questions, not one

A gate is worth its runtime only if all three have an answer:

| Question | Answered by |
|---|---|
| Does it go red on a real violation? | `verify_gates_fail.sh` — a planted violation per gate |
| Does it fail closed when its input is missing? | `check_gate_preflight.sh` |
| Does CI actually run it? | `check_gates_wired.sh` |

The third was added on 2026-09-01 and found two gates on its first run. One was
deliberate and now records its reason. The other was
`check_no_leaked_mutations.sh` — the backstop against a killed mutation run
leaving production source altered, written the same day *because* exactly that
had shipped the pNN50 threshold as 75 ms. It was in neither `ci.yml` nor
`make ci`. A gate written in response to an incident, and then never run.

### Two things must not read the tree at the same time

`verify_gates_fail.sh` and `verify_tests_fail.sh` edit tracked source in place
and restore it in an `EXIT` trap. That has cost twice:

* A killed run skips the trap and leaves the mutation applied. That is how the
  pNN50 threshold shipped as 75 ms instead of 50; `check_no_leaked_mutations.sh`
  is the backstop, and it now reads every mutation case rather than most of them.
* Anything reading the tree *while* one of them runs sees a planted violation as
  a real finding. `make ci-local` failed on a planted broken doc citation and a
  planted privacy-manifest type that were both restored seconds later — a red
  run about nothing, and on a hosted macOS runner that is billed at 10x.
  (Naming the planted path here would fail the doc-link gate on this very
  paragraph, which is the gate working.)

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
among others. That last one means the encrypted-write fix cannot silently
regress — weakening the protection class fails the suite.

Sixteen were added for logic lifted out of the god objects, because ~150 new tests are worth what a mutation run says
they are worth and nothing more. Fourteen were caught immediately. The two
survivors are the reason the exercise was worth doing, and both were gaps in
the tests rather than in the code:

* `TrackBackupWatermark` compares three cursors with `||`, and the test dropped
  all three at once — so weakening any ONE clause stayed hidden behind the
  other two. The test now drops one dimension at a time, and there is a
  mutation per clause. **A test that exercises a disjunction only in aggregate
  has not tested any of its terms.**
* The recovery merge's "keep whichever has more beats" tie-break is unreachable
  through its own front door: `DataSourceSelector` answers first for every
  input it can judge, so a test that called `mergedWorkoutPoints` passed while
  the comparison was inverted. The tie-break is now its own function with its
  own test. **A branch you can only reach by accident is a branch you are not
  testing.**

### Where to point it next: at the comments that claim something is subtle

`RRDataImporter+CSV.rrValue` carries a doc comment naming three asymmetries as
load-bearing and "easy to tidy away by accident" — a header-named RR column is
trusted verbatim, an unheadered two-column guess is range-checked, and the
first-column fallback fires on a parse failure but not on a range failure. That
comment is a claim about what the tests would catch, so it is a claim worth
mutating.

All three mutations survived a suite of 36 importer tests. The tests exercised
the happy paths and asserted nothing about any of the asymmetries; the file's
own warning had been true for as long as it had been written. Five tests now
pin them, and the three mutations are permanent.

The lead ran a third time on `WorkoutMileMarkerEngine`, whose zone label the
assistant speaks aloud mid-workout:

    /// Session-observed peak HR. DO NOT use as the denominator for zone
    /// math — that's what produced "Zone 5 at 100 bpm" when peak was only 105.

Swapping the denominator back to session peak survived a green suite. Nothing
asserted the zone the user is told they are in; ten minutes into an easy walk
the peak equals the current HR, so the defect reads every walk as VO2max. Three
tests now pin the denominator, the band edges, and the no-heart-rate case.

Two more of the same shape, both in the science layer:

* `TimeDomainAnalysis.storedHRStatistics` returns nil rather than a 60 bpm
  sentinel when every stored-HR beat in the window was artifact-rejected,
  because a sentinel biases the RHR z-score the recovery score is built on. A
  mutation planting the sentinel survived.
* `HRVSleepStageClassifier.windowVariability` computes SDNN with the POPULATION
  divisor (N), deliberately kept out of `Statistics`, which offers only the
  sample form (N-1). A mutation to N-1 survived. The two diverge most on short
  windows, which is all the classifier runs on.

A comment that says "careful, this is subtle" is a lead, not a safeguard. Eight
were followed across 2026-09-01/02 and eight turned up untested behaviour.

The same lead ran again on `HealthKitManager+HeartRate`, where the delete that
runs before every HR re-export carried:

    // Exact match: "-hr" must NOT swallow the "-hr-<n>" minute series.

That predicate decides what gets erased from the user's permanent Health
record, and the scheme it belongs to was spelled out as string interpolation at
seven call sites across three files. It is now one type, `HealthExportIdentity`,
whose tests enumerate every metric the app writes and assert that no metric's
delete reaches another metric's samples, or another session's — a property that
extends itself to any metric added later, rather than to the pairs someone
happened to think about.

Both survivors in its first run were bugs in the harness, not gaps in the
suite — one named a suite that did not cover the function, the other rewrote a
string inside a doc comment and changed no behaviour. Its header records that,
because a check that reports a result while measuring nothing is the exact
failure this repository keeps finding.

It needs a build and a simulator per mutation, so it is not in `make ci`. Run
it when the analysis or storage code changes.

### Runs are scoped, because a full one is expensive

`ci.yml` takes a `scope` on dispatch. Measured on run 33202282889:

| scope | what runs | billable minutes |
|---|---|---|
| `gates` (default) | lint, budgets, strict concurrency | ~14 |
| `unit` | + unit suite and Thread Sanitizer | ~300 |
| `full` | + UI target and the coverage floors | ~1080 |

macOS bills at 10x, and 66 of the tests job's 88 minutes are the UI target on
its own — 61% of a whole run for the part least likely to catch a regression in
a given change. Six full runs in a single day exhausted a month of included
minutes and most of the spending cap, which is what prompted the split.

`workflow_call` still defaults to `full`, so the TestFlight deploy gate is
unchanged: a release is checked against everything, exactly as before.

### The compiler is one of the gates

`scripts/run_tests_with_coverage.sh` passes
`-warn-long-expression-type-checking` and `-warn-long-function-bodies` to the
build it already runs, so a Swift expression that is slow to type-check fails
CI as a named diagnostic rather than as the frontend's hard limit.

That limit is not hypothetical. On 2026-08-27 two test files failed CI with
*"the compiler is unable to type-check this expression in reasonable time"*
while compiling fine locally — a runner-only failure with no local reproduction
and no gate that could have predicted it. Measuring instead of guessing then
found nine slow sites, the worst of them `EmuquApp.body`: a 455-line modifier
chain costing over nine seconds to type-check on its own, which every
incremental build had been paying and which no gate had ever looked at, because
`Emuqu/EmuquApp.swift` sits outside `Emuqu/Sources` and the spec-conformance
scan stopped at that directory.

Both are closed: the scan now covers the whole app target, and
`verify_gates_fail.sh` plants a violation in that specific file so the scan
cannot narrow back without going red. The flags are passed on the command line
rather than set in the project, so a local `xcodebuild archive` for the App
Store can never fail because a runner was busy.

**Nothing is waived.** There are zero `swiftlint:disable` directives in
`Emuqu/Sources`. Budgets ratchet downward only, and `check_budget_monotonicity.sh`
fails a raise that has no written justification.

## Where GitHub Actions is still used

Manually, for the thing it is uniquely good at: proving a release candidate
builds and passes on a machine that is not the developer's.

- `testflight.yml` calls `ci.yml` as a reusable workflow, so a release cannot be
  cut without the full suite passing first.
- `security.yml` (CodeQL) is run on demand when a security pass is wanted.

A full run fits fewer than three times a month; the `gates` and `unit` scopes
cost far less. That is enough for the release cadence.

## What this posture does *not* claim

It is a genuine trade, and these are the real costs:

- **A broken commit can reach `main`.** There is no automated gate between the
  developer's editor and the branch. The mitigation is that `make ci` is run
  before pushing, which is a discipline, not an enforcement.
- **No independent verification of the developer's claims.** A green `make ci`
  is asserted by the person who wrote the code. A CI run on someone else's
  hardware is not.
- **No third-party record.** There is no external artifact showing the suite was
  green at a given commit, other than a manually-triggered run.

Those costs are accepted knowingly. They are smaller than the cost of a CI
system that cannot run at all, which is what the alternative demonstrably was.

## For reviewers

If your finding is *"CI does not run automatically"* or *"`main` is not
protected"* — that is accurate, intended, and documented above. Please score it
against the constraint rather than the checklist.

For a fast, factual snapshot of what is enforced — every ceiling, every
zero-tolerance counter, and where each is written down:

```bash
./scripts/evidence_report.sh          # human-readable
./scripts/evidence_report.sh --json   # machine-readable
```

It runs no builds and takes seconds. It deliberately omits coverage and
pass/fail, because those need a real run and a cached number would be a
stale claim dressed as a current one.

If your finding is *"there is no evidence the checks pass"* — that is fair, and
the answer is to ask for a run rather than to infer failure from a quiet Actions
tab. `make ci` output or a dispatched workflow run will settle it.

If your finding is *"required status checks should be enabled on `main`"* — note
the ordering problem. Required checks that can never execute block every merge
permanently. Enabling them without a working budget makes the repository worse,
not better, and the correct sequence is: budget → one green run → then require.

Findings this posture does **not** answer, and which remain open on their own
merits: singleton-based dependency wiring and view-layer test coverage.
(Aggregate type size is closed: no type is over 1,500 lines, and the budget is 0.) Those are real architectural
debt, not evidence gaps, and nothing on this page excuses them.

An SBOM used to be on that list. `sbom.spdx.json` now covers the app and its 11
resolved packages with versions, commit SHAs, Package URLs and licences, and
`make sbom-check` fails if it goes stale. It is not signed and carries no build
provenance — both need a release pipeline that runs.
