# 004 — Debt is ratcheted, never waived

## Context

Every quality rule in this repository has a numeric ceiling in `.ci/*.txt`
rather than a pass/fail assertion: SwiftLint warnings, `.shared` singleton uses,
`try?` uses, legacy `ObservableObject` conformances, fixed-point fonts, test
skips, aggregate type size.

That looks, at a glance, like institutionalised tolerance for debt. It is the
opposite, and the distinction matters enough to write down.

## Decision

A ceiling may only move **down**, and a floor (every `.ci/min_*.txt`, such as
the coverage minimums) only **up**. `scripts/check_budget_monotonicity.sh`
compares every numeric `.ci/*.txt` value, whole or decimal, with the baseline
and fails the build on any loosening (a ceiling raised, a floor lowered, or a
budget deleted or made non-numeric) that lacks a `budget-raise-ok:` trailer
naming the file and the reason in some commit of the compared range. The
baseline is the target branch on a pull request and the tip before the push on
a push to main, so every commit of a multi-commit push is inside the range.
Only when that tip is missing from the checkout (a branch-creating or forced
push) does the gate fall back to the parent commit, and it says so.

There is no per-site escape hatch. There are zero `swiftlint:disable` directives
in `Emuqu/Sources`, and the refactor-spec gate counts justified exceptions
separately so they cannot hide inside the main number.

## Why not a hard zero

Because a rule set to an aspiration is worse than no rule. The coverage gate
demonstrated this: it required 90% for months, could never pass, and was
therefore never run — while the README and a runbook both stated the 90% figure
as though it held. A gate nobody can satisfy is a gate everybody routes around,
and its documentation becomes a lie by default.

A measured ceiling is honest about the present, blocks regression immediately,
and converts "we should fix this someday" into a number that only moves one way.

## Consequence

The numbers in `.ci/` are a debt inventory, and a reviewer is right to read them
as such. Eighteen waivers went to zero this way, and the last oversized types
have been split. Static reads of the composition root are what remain, counted
in `.ci/shared_usage_budget.txt`. That is the honest measure of what is still
outstanding, which is the point of writing it down rather than asserting a
standard that was never met.

These ceilings are debt inventories rather
than assurance targets. That is intended.
