# How a change lands in Emuqu

Emuqu does not accept outside contributions. The source is published under
the PolyForm Strict License so the work can be read, studied and built, not
changed or redistributed, and pull requests are closed without review. Bug
reports through the issue templates are welcome.

This file is the maintainer's own procedure. Emuqu is a solo-maintained iOS
and watchOS app that reads heart-rate variability off a chest strap and turns
it into a recovery score. That shapes everything below: there is no second
reviewer, so the gates are the reviewer. The Linux gates run on every push to
`main` and on every pull request; everything that needs Xcode runs only when
you run it. The conventions here
exist to keep that meaningful.

If you are new to the codebase, read [`docs/MAINTAINERS.md`](docs/MAINTAINERS.md)
first — it is the map. This file is only about how a change gets made and
landed.

## The one rule that matters

**Every gate is enforced, and no gate is waived.** If a check fails, the fix is
to change the code or to change the rule with a written reason. Adding a
`swiftlint:disable` with a better paragraph attached is not a fix, and a
justification that survives review becomes a documented rule change, not a
local escape.

There are currently zero `swiftlint:disable` directives in `Emuqu/Sources`.
Keep it that way.

## Before you start

```bash
make setup-hooks
```

```bash
make codemap-setup
```

The first installs the pre-commit hook; the second installs the pinned tree-sitter
the code map needs (the hook fails without it). It needs Python 3.10 or newer, which
macOS's own `python3` (3.9) is not; it uses the first `python3.13` … `python3.10` or
`python3` on PATH that is, then Homebrew's, the python.org installer's or pyenv's, or
`CODEMAP_BASE_PYTHON`. A SwiftLint error or a stale
code-map record blocks the commit;
SwiftFormat only reports whether the staged files drifted, because most of the
tree does not yet conform to `.swiftformat`. `gates.yml` runs the script gates
on every push to `main`, but nothing macOS-based does, so this hook is what
catches a lint regression before it lands.

## While you work

**Build after every edit, and run the unit target once per file.** Do not batch
verification across ten files and then try to bisect a failure.

```bash
xcodebuild -project Emuqu.xcodeproj -scheme Emuqu \
  -destination 'platform=iOS Simulator,name=iPhone 17 Pro' build

xcodebuild test -project Emuqu.xcodeproj -scheme Emuqu \
  -destination 'platform=iOS Simulator,name=iPhone 17 Pro' \
  -only-testing:EmuquTests
```

Warnings are errors (`SWIFT_TREAT_WARNINGS_AS_ERRORS = YES`). A build that
emits a warning does not compile.

### The code map is part of the change

Every function, script target, workflow step and doc section has a record in
[`docs/codemap/records/`](docs/codemap/README.md). CI, `make ci` and the
pre-commit hook fail until the records for what you changed are current.

1. Before you change a unit, run `make codemap-impact` (or
   `.venv-codemap/bin/python scripts/codemap/codemap.py impact <path::key>`) and
   read its record, its callers, the tests that reach it and the open findings.
2. Make the change.
3. `make codemap-guard` lists every record to bring up to date. Rewrite each
   against the code as it now is, and remove the flags your change fixed.
4. "re-check" lines (`codemap.py status` lists them) are callers whose callee
   now does something different. Re-read each one; if its own behaviour
   changed, change it or its record too.
5. Stamp each record after you have re-read it, callees before callers:
   `.venv-codemap/bin/python scripts/codemap/codemap.py stamp <path> [<key> ...]`.
6. Fixing a high- or medium-severity finding lowers
   `.ci/codemap_open_high.txt` or `.ci/codemap_open_med.txt` in the same change.

The full procedure is in [`docs/codemap/README.md`](docs/codemap/README.md).

### Budgets ratchet down, never up

`.ci/*.txt` holds a ceiling for every category of accepted debt — singleton
reach-throughs, `try?` uses, legacy `ObservableObject` conformances, SwiftLint
warnings, `@unchecked Sendable` escapes, and more. When you reduce one,
**lower the budget file in the same change** so the gain is locked in.

Raising a ceiling, or lowering one of the `min_*` floors, needs a trailer line
in the message of a commit that lands with it:

```text
budget-raise-ok: .ci/<name>.txt <why the debt is worth taking and when it will be repaid>
```

The path must be written exactly as shown; the reason is for the reader.
`gates.yml` is the guard that enforces this: on a push to `main` it compares
every budget with the commit before the push, and on a pull request with the
target branch, and fails on any loosening without a matching trailer in that
range. Locally, `make budget-monotonicity` compares the working tree with
`HEAD`. That catches an uncommitted raise, but it cannot see a trailer you have
not committed yet, nor a raise you already committed; for those, run
`BUDGET_BASE_REF=origin/main make budget-monotonicity`. Treat an increase as a
decision, not a formality.

### Adding a new Swift file

The Xcode project is checked in. A new file in `Emuqu`, `EmuquTests` or
`EmuquUITests` must be registered in `Emuqu.xcodeproj/project.pbxproj` at
**four** points: `PBXBuildFile`, `PBXFileReference`, the group's `children`
array, and the target's `Sources` build phase. `make orphan-swift-guard` fails
if a file on disk is not in the project, which is the usual way a missed
registration is caught.

`EmuquWatch Watch App` is the exception: it is a synchronised folder, so a file
there is in the watch target by being on disk. Do not register it by hand; a
second, explicit entry builds the file twice and fails with "Multiple commands
produce".

A path containing `+` **must be quoted** in the file reference —
`path = "Foo+Bar.swift";`. An unquoted one makes `xcodebuild` unable to read
the project at all, which reads as catastrophic corruption and is a
two-character fix.

### Adding user-facing text

Every user-visible string is localized into 17 languages and CI enforces 100%
coverage. Use `String(localized:bundle:)` with `LanguageManager.appBundle` —
`make localization-bundle-guard` fails an unqualified lookup.

**Do not reformat an existing localized literal.** The string *is* the key.
Rewrapping one across lines can change what Xcode extracts, which orphans the
translations behind it. If a localized line is too long for the line-length
rule, leave it long; that is why those warnings are in the budget.

Health copy passes through `Tools/copy_linter/lint.py` (`make copy-perimeter`),
which blocks regulated-claim language. Write what was observed, not what it
means clinically: "below your usual range", not "indicates a problem".

## Before you open a pull request

```bash
make ci
```

Check the exit status, not the last line of output. **This is the enforcement.**
`gates.yml` runs the bash-and-python gates on every push, including the
tech-debt budgets and spec conformance; the build, the test suite, SwiftLint
and its warning budget need macOS and run only on demand, for reasons costed
in [`docs/CI_POSTURE.md`](docs/CI_POSTURE.md). So `make ci` is the gate rather
than a convenience. `make ci` runs lint, budgets, spec conformance,
localization, copy perimeter, documentation links, and the full test suite
with coverage. The test suite is the slow part, because the UI target drives a
real simulator. Two checks that `ci.yml` runs are not part of `make ci`,
because each needs a build of its own: `make thread-sanitizer` (the unit suite
under Thread Sanitizer) and `make release-build` (the Release configuration
compiles). Run them as well when a change touches concurrency or could differ
under the optimizer.

`make codemap-impact` lists everything your branch's changes can affect; the
pull request gets the same list in the `gates.yml` job summary. Check each
caller, test and shared-state user it names.

Fill in [the pull-request template](.github/PULL_REQUEST_TEMPLATE.md). It is
short and it is the only review record this project gets.

## Style

The refactor specification in
[`docs/REFACTOR_SPEC.md`](docs/REFACTOR_SPEC.md) is the
standard, and `make spec-conformance` enforces the measurable parts of it:
declarations stay at or under 20 lines, nesting stays at or under depth 2, no
commented-out code, no empty catch blocks.

The length and nesting rules allow a written waiver for a declaration that
cannot be split without harm. Waivers are counted against budgets in `.ci/`
(the `spec_justified_*` files), which ratchet down like every other budget, so
taking a new one is a budget raise and needs the trailer above.

Beyond what the gate measures:

- **Comments explain why, never what.** The code says what it does. A comment
  earns its place by recording a decision, an incident, or a constraint that
  the next reader would otherwise have to rediscover — usually with a date.
- **Name things for what they are.** `calculateOvernightHrvBaseline`, not
  `processData`.
- **Errors are typed and carry context.** No swallowed errors, no empty
  catches, no secrets in the message.
- **Prefer a pure function.** Side effects belong at the boundary; the middle
  of the codebase should be logic you can call from a test without a simulator.

## Security and privacy

Report a vulnerability privately — see [`.github/SECURITY.md`](.github/SECURITY.md).
Do not open a public issue for one.

Any change that alters what leaves the device is a privacy change, not a
feature change. It needs the consent surface, `PrivacyInfo.xcprivacy`, the
privacy policy, and the App Store Connect answers updated together. The
security policy describes how they line up; keep all four in agreement.
