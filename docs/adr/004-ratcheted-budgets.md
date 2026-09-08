# 004 — Debt is ratcheted, never waived

## Context

Every quality rule in this repository has a numeric ceiling in `.ci/*.txt`
rather than a pass/fail assertion: SwiftLint warnings, `.shared` singleton uses,
`try?` uses, legacy `ObservableObject` conformances, fixed-point fonts, test
skips, aggregate type size, strict-concurrency diagnostics.

That looks, at a glance, like institutionalised tolerance for debt. It is the
opposite, and the distinction matters enough to write down.

## Decision

A ceiling may only move **down**. `scripts/check_budget_monotonicity.sh` fails
the build on any increase that lacks a `budget-raise-ok:` trailer naming the
file and the reason.

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
as such. Eighteen waivers went to zero this way. Static reads of the composition root
(128) and three types over 1,500 lines are what remain, and those are the honest
measure of what is still outstanding — which is the point of writing them down rather than
asserting a standard that was never met.

These ceilings are debt inventories rather
than assurance targets. That is intended.
