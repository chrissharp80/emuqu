#!/usr/bin/env bash
# `Int64(a.timeIntervalSince(b) * 1000)` must go through `MillisecondOffset`.
#
# Why this exists. That expression traps on a non-finite or
# out-of-range value, and both operands are routinely dates read back from a
# backup file, an archived session, or a HealthKit query — so "cannot happen"
# is not available. It also TRUNCATES: date arithmetic drifts in binary
# floating point, so a genuine 1.234 s gap arrives as 1233.9999 ms and loses a
# millisecond off every conversion.
#
# This shape produces live defects — the import path, the overnight merge
# offset, and the HealthKit retry bounds have each shipped one.
# `MillisecondOffset` rejects the unrepresentable and rounds rather than
# truncating.
#
# `Date()` on the left is exempt: "now minus a recent timestamp" is always
# finite and small, and requiring a helper there would be noise.
set -euo pipefail

python3 - <<'PY'
import pathlib, re, sys

pat = re.compile(
    r'Int64\(\s*([A-Za-z_][\w.?\[\]$]*)\s*\.timeIntervalSince\(([^()]*)\)\s*\*\s*1_?000'
)
problems = []
for f in sorted(pathlib.Path('Emuqu/Sources').rglob('*.swift')):
    if f.name == 'MillisecondOffset.swift':
        continue
    for n, line in enumerate(f.read_text(encoding='utf-8', errors='ignore').split('\n'), 1):
        code = line.split('//')[0]
        m = pat.search(code)
        if not m:
            continue
        if m.group(1).startswith('Date()'):
            continue
        if re.search(r'date-ms-ok:', line):
            continue
        problems.append((f, n, code.strip()))

if problems:
    print(f"check_date_ms_conversion: {len(problems)} raw date-to-millisecond conversion(s).\n")
    for f, n, code in problems:
        print(f"  {f}:{n}")
        print(f"      {code[:78]}")
    print("\n  `Int64(interval * 1000)` traps on a corrupt stored date and truncates")
    print("  a millisecond off every conversion. Use:")
    print("      MillisecondOffset.between(later, and: earlier)                # Int64?")
    print("      MillisecondOffset.between(later, and: earlier, fallback: 0)   # Int64")
    sys.exit(1)

print("check_date_ms_conversion: clean. Every stored-date conversion goes through MillisecondOffset.")
PY
