#!/usr/bin/env bash
# `for i in 1 ..< xs.count` traps when `xs` is empty: `1 ..< 0` is an invalid
# range, not an empty one. The same block usually also calls
# `reserveCapacity(xs.count - 1)`, which traps on -1.
#
# The same trap wears a second face: `for i in 0 ..< (xs.count - 2)`. It reads
# as "stop two short", but on a collection of 0 or 1 it is `0 ..< -1` or
# `0 ..< -2` — invalid, not empty, and it crashes exactly the same way. Found
# twice in `HRSleepEstimator` on 2026-09-01, where both were safe only because
# every caller happened to guard. This gate covers both shapes.
#
# Why this exists (2026-09-01). Four instances were found in one session —
# `TopoElevationService.sustainedClimb`, `Route.risingRuns`,
# `HRVSleepStageClassifier.windowVariability`, `TimeDomainAnalysis`,
# `Verification.findMaxGap` and `DataSourceSelector.findGaps`. Every one was
# reachable only through a caller that happened to guard, which is exactly the
# kind of safety that evaporates when a new caller appears.
#
# A guard in the enclosing function satisfies this gate only when it is strong
# enough: `0 ..< (xs.count - N)` needs `xs.count >= N` (or `> N-1`,
# `if xs.count < N { return }`); `1 ..< xs.count` needs a non-empty guard. The
# point is that the guard exists NEXT TO the loop, not somewhere up the call
# graph.
set -euo pipefail

# The scan roots are relative; from any other directory they hold no files and
# the gate would report clean having read nothing.
cd "$(dirname "$0")/.."

python3 - <<'PY'
import pathlib, re, sys

# Two shapes, one trap:
#   for i in 1 ..< xs.count           -> traps when xs is empty
#   for i in 0 ..< (xs.count - N)     -> traps when xs.count < N
PATTERNS = [
    re.compile(r'for\s+\w+\s+in\s+1\s*\.\.<\s*([\w.]+)\.count'),
    re.compile(r'for\s+\w+\s+in\s+0\s*\.\.<\s*\(?\s*([\w.]+)\.count\s*-\s*(\d+)'),
]
# The enclosing unit's first line: a func, init, deinit or subscript.
UNIT_START = re.compile(
    r'\s*(?:@\w+\s+)*(?:(?:private|fileprivate|internal|public|static|nonisolated|'
    r'mutating|final|class|override|convenience|required)\s+)*'
    r'(?:func\s|init[?!]?\s*[(<]|deinit\b|subscript\s*[(<])')


def required_count(m):
    """The smallest count for which the loop's range is valid."""
    return 1 if m.lastindex == 1 else int(m.group(2))


def guaranteed_counts(var, window):
    """Every minimum count a guard in `window` establishes for `var`."""
    found = []
    cond = rf'(?:guard|if|while)\b[^\n]*'
    for m in re.finditer(cond + rf'{var}\.count\s*(>=|>)\s*(\d+)', window):
        found.append(int(m.group(2)) + (1 if m.group(1) == '>' else 0))
    # `if xs.count < N { return }` leaves at least N behind it.
    for m in re.finditer(cond + rf'{var}\.count\s*<\s*(\d+)', window):
        found.append(int(m.group(1)))
    # `for seg in ... where seg.count >= N` guards the inner loop.
    for m in re.finditer(rf'where\s+[^\n]*{var}\.count\s*(>=|>)\s*(\d+)', window):
        found.append(int(m.group(2)) + (1 if m.group(1) == '>' else 0))
    # Non-empty: `!xs.isEmpty`, `guard ... xs.isEmpty` / `if xs.isEmpty { return }`,
    # `xs.count != 0`.
    if re.search(cond + rf'(?:!\s*{var}\.isEmpty|{var}\.isEmpty|{var}\.count\s*!=\s*0)', window):
        found.append(1)
    return found


problems = []
for f in sorted(pathlib.Path('Emuqu/Sources').rglob('*.swift')):
    lines = f.read_text(encoding='utf-8', errors='ignore').split('\n')
    for n, line in enumerate(lines):
        code_only = line.split('//')[0]
        # `max(0, xs.count - N)` cannot be negative — the range is empty, not
        # invalid, which is the fix this gate asks for.
        if re.search(r'max\s*\(\s*0\s*,', code_only):
            continue
        m = next((p.search(code_only) for p in PATTERNS if p.search(code_only)), None)
        if not m:
            continue
        var = re.escape(m.group(1))
        need = required_count(m)
        # Look back only as far as the ENCLOSING unit, however long it is.
        # A fixed window lets a guard belonging to the function ABOVE satisfy
        # this check — which it did for `RecurrenceClassifier.cumulativeDistances`,
        # whose own loop was unguarded while the previous function's
        # `guard pts.count >= 2` sat six lines up.
        start = next((k for k in range(n - 1, -1, -1) if UNIT_START.match(lines[k])), 0)
        window = '\n'.join(lines[start:n])
        # A guard counts only when it is strong enough for THIS range:
        # `xs.count > 0` does not protect `0 ..< xs.count - 2`, which still
        # traps at a count of 1.
        guarded = any(c >= need for c in guaranteed_counts(var, window))
        # An explicit waiver, in the same style as `swallow-ok` elsewhere in
        # this repo. It must carry a reason, so a future reader can check the
        # claim rather than trust a bare marker.
        waiver = re.search(r'empty-range-ok:\s*(\S.*)', '\n'.join(lines[max(0, n - 3):n + 1]))
        if not guarded and not waiver:
            problems.append((f, n + 1, line.strip(), need))

if problems:
    print(f"check_empty_range_loops: {len(problems)} unguarded count-arithmetic range loop(s).\n")
    for f, n, code, need in problems:
        print(f"  {f}:{n}  (needs a guard of count >= {need})")
        print(f"      {code[:78]}")
    print("\n  `1 ..< 0` and `0 ..< -1` are INVALID ranges and trap — not empty loops.")
    print("  Add a count guard immediately before the loop, e.g.")
    print("      guard xs.count > 1 else { return ... }")
    print("  Or clamp the bound so the range is empty rather than invalid:")
    print("      for i in 0 ..< max(0, xs.count - 2)")
    print("  Or, when the collection is non-empty by construction, waive it with")
    print("  a reason: // empty-range-ok: <why this cannot be empty>")
    sys.exit(1)

print("check_empty_range_loops: clean. Every count-arithmetic range loop guards its input.")
PY
