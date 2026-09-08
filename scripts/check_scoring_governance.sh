#!/usr/bin/env bash
#
# CI guard: two conditions the round-4 science audit set for keeping
# unvalidated scoring heuristics in place rather than removing them.
#
#   * "rankingWeight cannot appear as confidence in UI, exports, analytics, or
#      accessibility text"
#   * "A scoring-version change is required whenever inputs, thresholds, or
#      weights change"
#
# Both were true when checked, and neither was ENFORCED. "Cannot" and
# "happens to not" are different properties, and the difference is what a gate
# is for. This makes them structural.
#
# 1. rankingWeight is an ordering key for the probable-cause list. It is a
#    hand-set number with no outcome data behind it, so rendering it anywhere a
#    user can see would present a made-up figure as a confidence. It may not
#    leave Analysis/CauseDetection.
#
# 2. The scoring constants are hashed. Change a weight, a threshold or a band
#    and the hash moves; the gate then requires ScoringVersion.current to have
#    moved too. This is what stops an archive quietly becoming a mixture of two
#    algorithms under one version string — the failure the version stamp exists
#    to prevent.
#
# Exit 0 clean, 1 on a violation, 2 on config error.

set -uo pipefail
cd "$(dirname "$0")/.."

BASELINE=".ci/scoring_constants_hash.txt"

python3 - "$BASELINE" <<'PY'
import hashlib
import pathlib
import re
import sys

baseline_path = pathlib.Path(sys.argv[1])
problems = []

# --- 1. rankingWeight containment -----------------------------------------
ALLOWED_PREFIX = "Emuqu/Sources/Analysis/CauseDetection/"
for path in sorted(pathlib.Path("Emuqu/Sources").rglob("*.swift")):
    rel = str(path)
    if rel.startswith(ALLOWED_PREFIX):
        continue
    text = path.read_text(encoding="utf-8", errors="ignore")
    for number, line in enumerate(text.splitlines(), start=1):
        if "rankingWeight" in line:
            problems.append(
                f"{rel}:{number}: rankingWeight outside CauseDetection. "
                "It is a hand-set ordering key, not a confidence, and must not reach "
                "UI, exports, analytics or accessibility text."
            )

# --- 2. scoring constants vs the version string ---------------------------
SCORING_SOURCES = [
    "Emuqu/Sources/Utilities/Constants+RecoveryScore.swift",
    "Emuqu/Sources/Analysis/HRVThresholds.swift",
]
CONST_RE = re.compile(r"static let\s+(\w+)\s*:?\s*[\w<>\[\], .]*=\s*([-\d.]+)")

digest = hashlib.sha256()
seen = 0
for name in SCORING_SOURCES:
    path = pathlib.Path(name)
    if not path.is_file():
        sys.stderr.write(f"check_scoring_governance: missing {name}\n")
        raise SystemExit(2)
    # Comments are stripped so rewording a rationale never looks like a
    # scoring change — only the numbers count.
    source = re.sub(r"//[^\n]*", "", path.read_text(encoding="utf-8"))
    for symbol, value in sorted(CONST_RE.findall(source)):
        digest.update(f"{name}:{symbol}={value}\n".encode())
        seen += 1

current_hash = digest.hexdigest()[:16]

version_src = pathlib.Path("Emuqu/Sources/Analysis/ScoringVersion.swift").read_text(encoding="utf-8")
match = re.search(r'static let current\s*=\s*"([^"]+)"', version_src)
if not match:
    sys.stderr.write("check_scoring_governance: cannot read ScoringVersion.current\n")
    raise SystemExit(2)
version = match.group(1)

if not baseline_path.is_file():
    sys.stderr.write(f"check_scoring_governance: missing {baseline_path}\n")
    raise SystemExit(2)

recorded_version, recorded_hash = baseline_path.read_text(encoding="utf-8").split()
if current_hash != recorded_hash and version == recorded_version:
    problems.append(
        f"scoring constants changed ({recorded_hash} -> {current_hash}) while "
        f"ScoringVersion.current stayed {version!r}. Bump the version and update "
        f"{baseline_path}, so stored scores stay attributable to the algorithm "
        "that produced them."
    )

for problem in problems:
    print(f"  {problem}", file=sys.stderr)

print(f"check_scoring_governance: {seen} scoring constants hashed ({current_hash}), "
      f"version {version}; rankingWeight contained to CauseDetection")

if problems:
    print(f"check_scoring_governance: {len(problems)} violation(s).", file=sys.stderr)
    raise SystemExit(1)
print("check_scoring_governance: clean.")
PY
