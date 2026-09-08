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
# A guard within the preceding lines satisfies this gate. The point is that the
# guard exists NEXT TO the loop, not somewhere up the call graph.
set -euo pipefail

python3 - <<'PY'
import pathlib, re, sys

# Two shapes, one trap:
#   for i in 1 ..< xs.count           -> traps when xs is empty
#   for i in 0 ..< (xs.count - N)     -> traps when xs.count < N
PATTERNS = [
    re.compile(r'for\s+\w+\s+in\s+1\s*\.\.<\s*([\w.]+)\.count'),
    re.compile(r'for\s+\w+\s+in\s+0\s*\.\.<\s*\(?\s*([\w.]+)\.count\s*-\s*\d+'),
]
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
        # Look back only as far as the ENCLOSING function. Scanning a fixed
        # number of lines lets a guard belonging to the function ABOVE satisfy
        # this check — which it did for `RecurrenceClassifier.cumulativeDistances`,
        # whose own loop was unguarded while the previous function's
        # `guard pts.count >= 2` sat six lines up.
        start = 0
        for k in range(n - 1, max(0, n - 60), -1):
            if re.match(r'\s*(?:@\w+\s+)*(?:(?:private|fileprivate|internal|public|static|nonisolated|mutating|final|class)\s+)*func\s', lines[k]):
                start = k
                break
        window = '\n'.join(lines[start:n])
        guarded = re.search(
            rf'(guard|if|while)\b[^\n]*(?:'
            rf'{var}\.count\s*(?:>=?\s*[1-9]|>\s*0)'
            rf'|{var}\.count\s*<\s*[1-9]'
            rf'|!\s*{var}\.isEmpty'
            rf'|{var}\.isEmpty'
            rf'|{var}\.count\s*!=\s*0'
            rf')', window) or re.search(
            # `for seg in ... where seg.count >= 2` guards the inner loop.
            rf'where\s+[^\n]*{var}\.count\s*(?:>=?\s*[1-9]|>\s*0)', window)
        # An explicit waiver, in the same style as `swallow-ok` elsewhere in
        # this repo. It must carry a reason, so a future reader can check the
        # claim rather than trust a bare marker.
        waiver = re.search(r'empty-range-ok:\s*(\S.*)', '\n'.join(lines[max(0, n - 3):n + 1]))
        if not guarded and not waiver:
            problems.append((f, n + 1, line.strip()))

if problems:
    print(f"check_empty_range_loops: {len(problems)} unguarded count-arithmetic range loop(s).\n")
    for f, n, code in problems:
        print(f"  {f}:{n}")
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
