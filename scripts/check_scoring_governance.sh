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
# 2. The scoring constants are hashed (Constants+RecoveryScore.swift,
#    HRVThresholds.swift, and the ScoringBounds / ScoringWeights enums of
#    Constants.swift, where the composite weights live). Change a weight, a
#    threshold or a band and the hash moves; the gate then requires ScoringVersion.current to have
#    moved too. This is what stops an archive quietly becoming a mixture of two
#    algorithms under one version string — the failure the version stamp exists
#    to prevent.
#
#    The baseline must match both the current version and the current hash, so
#    a version bump is refreshed into it in the same change. Accepting any
#    version other than the recorded one let one bump that left the baseline
#    alone switch the check off for good: every later constant change passed,
#    bump or not. Each hashed file and enum must also yield at least one
#    constant; a refactor the pattern no longer matches (`static var`, computed
#    values) would otherwise hash nothing and never move.
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
    found = sorted(CONST_RE.findall(source))
    if not found:
        sys.stderr.write(f"check_scoring_governance: no scoring constants matched in {name}\n")
        raise SystemExit(2)
    for symbol, value in found:
        digest.update(f"{name}:{symbol}={value}\n".encode())
        seen += 1

# Composite weights and score bounds live in Constants.swift beside
# non-scoring constants (unit conversions, UserDefaults keys), so only
# these two enums are hashed from it.
SCORING_ENUMS = {"Emuqu/Sources/Utilities/Constants.swift": ["ScoringBounds", "ScoringWeights"]}
for name, enums in SCORING_ENUMS.items():
    path = pathlib.Path(name)
    if not path.is_file():
        sys.stderr.write(f"check_scoring_governance: missing {name}\n")
        raise SystemExit(2)
    source = re.sub(r"//[^\n]*", "", path.read_text(encoding="utf-8"))
    for enum in enums:
        block = re.search(r"^enum " + enum + r"\b.*?^\}", source, re.S | re.M)
        if not block:
            sys.stderr.write(f"check_scoring_governance: enum {enum} not found in {name}\n")
            raise SystemExit(2)
        found = sorted(CONST_RE.findall(block.group(0)))
        if not found:
            sys.stderr.write(f"check_scoring_governance: no scoring constants matched in {enum} ({name})\n")
            raise SystemExit(2)
        for symbol, value in found:
            digest.update(f"{name}:{enum}.{symbol}={value}\n".encode())
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

fields = baseline_path.read_text(encoding="utf-8").split()
if len(fields) != 2:
    sys.stderr.write(f"check_scoring_governance: {baseline_path} must hold '<version> <hash>'\n")
    raise SystemExit(2)
recorded_version, recorded_hash = fields
if current_hash != recorded_hash and version == recorded_version:
    problems.append(
        f"scoring constants changed ({recorded_hash} -> {current_hash}) while "
        f"ScoringVersion.current stayed {version!r}. Bump the version and update "
        f"{baseline_path}, so stored scores stay attributable to the algorithm "
        "that produced them."
    )
elif (version, current_hash) != (recorded_version, recorded_hash):
    problems.append(
        f"{baseline_path} records {recorded_version} {recorded_hash}, but the code is "
        f"{version} {current_hash}. Write '{version} {current_hash}' to it in the same "
        "change as the version bump, or the next constant change goes unchecked."
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
