# How a change lands in Emuqu

Emuqu does not accept outside contributions. The source is published under
the PolyForm Strict License so the work can be read, studied and built, not
changed or redistributed, and pull requests are closed without review. Bug
reports through the issue templates are welcome.

This file is the maintainer's own procedure. Emuqu is a solo-maintained iOS
and watchOS app that reads heart-rate variability off a chest strap and turns
it into a recovery score. That shapes everything below: there is no second
reviewer, so the gates are the reviewer. The Linux gates run on every push;
everything that needs Xcode runs only when you run it. The conventions here
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

This installs the pre-commit hook. A SwiftLint error blocks the commit;
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

### Budgets ratchet down, never up

`.ci/*.txt` holds a ceiling for every category of accepted debt — singleton
reach-throughs, `try?` uses, legacy `ObservableObject` conformances, SwiftLint
warnings, `@unchecked Sendable` escapes, and more. When you reduce one,
**lower the budget file in the same change** so the gain is locked in.

Raising a budget requires a written reason in the commit message explaining why
the debt is worth taking and when it will be repaid. `make budget-monotonicity`
is the guard; treat an increase as a decision, not a formality.

### Adding a new Swift file

The Xcode project is checked in. A new file must be registered in
`Emuqu.xcodeproj/project.pbxproj` at **four** points: `PBXBuildFile`,
`PBXFileReference`, the group's `children` array, and the target's `Sources`
build phase. `make orphan-swift-guard` fails if a file on disk is not in the
project, which is the usual way a missed registration is caught.

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
than a convenience. `make ci` runs every gate: lint, budgets, spec
conformance, localization, copy perimeter, documentation links, and the full
test suite with coverage. The test suite is the slow part, because the UI
target drives a real simulator.

Fill in [the pull-request template](.github/PULL_REQUEST_TEMPLATE.md). It is
short and it is the only review record this project gets.

## Style

The refactor specification in
[`docs/REFACTOR_SPEC.md`](docs/REFACTOR_SPEC.md) is the
standard, and `make spec-conformance` enforces the measurable parts of it:
declarations stay at or under 20 lines, nesting stays at or under depth 2, no
commented-out code, no empty catch blocks.

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
