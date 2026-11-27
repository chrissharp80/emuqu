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
# 2. Every number that shapes a recovery score is hashed
#    (scripts/lib/scoring_hash.py, scheme `decl-literals`): the named constants
#    of RecoveryScoreConstants.swift, HRVThresholds.swift and the
#    ScoringBounds / ScoringWeights enums of Constants.swift, and the literals
#    written inline in the scoring code itself (RecoveryScoreCalculator*.swift,
#    ScoreDetailBuilder, VitalsScoring, SleepScienceAnalyzer): the z-score band
#    tables and the `defaultScoringParameters` binding, the age/sex norms,
#    clamps and caps. Comments and string literals are stripped, and each
#    number is keyed by the declaration it sits in, so moving or reordering
#    declarations leaves the hash alone. Change a weight, a band, a threshold
#    or the table the score binds to and the hash moves; the gate then requires
#    ScoringVersion.current to have moved too. This is what stops an archive
#    quietly becoming a mixture of two algorithms under one version string,
#    the failure the version stamp exists to prevent.
#
#    The baseline line is `<version> <hash> <scheme>`. A change to how the
#    hash is computed rehashes with no scoring change, so the scheme is
#    recorded and a base is always compared under its own scheme: the tree
#    is hashed the base's way too, and a number that moved still fails.
#
#    The baseline must match both the current version and the current hash, so
#    a version bump is refreshed into it in the same change. Because that file
#    is edited in the same change, it is also read as the base the change is
#    measured from (`scoring_base_ref`, at the merge base): a hash that differs
#    from the base's under the base's version fails however the baseline was
#    edited. The base is SCORING_BASE_REF when given; on a pull request the
#    target branch; on a push the tip before the push (PUSH_BEFORE, or `before`
#    in the event payload), since after a push origin/main IS the pushed tip
#    and would compare the change with itself; otherwise origin/main. A push CI
#    cannot resolve a base for, or one whose base is the commit being checked,
#    fails. Elsewhere a missing base is reported and that comparison skipped. Accepting any
#    version other than the recorded one let one bump that left the baseline
#    alone switch the check off for good: every later constant change passed,
#    bump or not. Each hashed file, glob and enum must also yield at least one
#    number, so a source that moves away or empties cannot hash nothing and
#    never move.
#
# Exit 0 clean, 1 on a violation, 2 on config error.

set -uo pipefail
cd "$(dirname "$0")/.."

# SCORING_BASELINE names another baseline file; verify_gates_fail.sh uses it
# to edit the baseline in step with the constants without touching the tree.
TRACKED_BASELINE=".ci/scoring_constants_hash.txt"
BASELINE="${SCORING_BASELINE:-$TRACKED_BASELINE}"

# The commit the change is measured from; nothing printed when a push's tip
# before the push cannot be resolved.
scoring_base_ref() {
    if [[ -n "${SCORING_BASE_REF:-}" ]]; then echo "$SCORING_BASE_REF"; return; fi
    if [[ -n "${GITHUB_BASE_REF:-}" ]]; then echo "origin/${GITHUB_BASE_REF}"; return; fi
    if [[ "${GITHUB_EVENT_NAME:-}" != "push" ]]; then echo "origin/main"; return; fi
    local before="${PUSH_BEFORE:-}"
    if [[ -z "$before" && -n "${GITHUB_EVENT_PATH:-}" ]]; then
        before="$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1])).get("before") or "")' "$GITHUB_EVENT_PATH" 2>/dev/null)"
    fi
    # A branch's first push has no tip before it: measure from main.
    if [[ "$before" =~ ^0{40}$ ]]; then echo "origin/main"; return; fi
    if [[ -n "$before" ]] && git rev-parse --verify --quiet "${before}^{commit}" >/dev/null; then echo "$before"; fi
}

BASE_REF="$(scoring_base_ref)"
if [[ -z "$BASE_REF" ]]; then
    echo "check_scoring_governance: this push's tip before the push is not in the checkout, so there is no base to measure the change from" >&2
    exit 2
fi
BASE_BASELINE=""
if MERGE_BASE="$(git merge-base HEAD "$BASE_REF" 2>/dev/null)"; then
    if [[ "${GITHUB_EVENT_NAME:-}" == "push" && "$MERGE_BASE" == "$(git rev-parse HEAD)" ]]; then
        echo "check_scoring_governance: the base ($BASE_REF) is the pushed commit itself, so the change would be compared with itself" >&2
        exit 2
    fi
    if ! BASE_BASELINE="$(git show "$MERGE_BASE:$TRACKED_BASELINE" 2>/dev/null)"; then
        echo "check_scoring_governance: $BASE_REF has no $TRACKED_BASELINE at $MERGE_BASE" >&2
        exit 2
    fi
elif [[ "${GITHUB_ACTIONS:-}" == "true" ]]; then
    echo "check_scoring_governance: cannot resolve $BASE_REF; CI must check out full history" >&2
    exit 2
else
    echo "check_scoring_governance: note: $BASE_REF not found, so the version is not checked against the base branch" >&2
fi
export BASE_BASELINE

python3 - "$BASELINE" <<'PY'
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

# --- 2. scoring literals vs the version string -----------------------------
# scripts/lib/scoring_hash.py holds every scheme a baseline can name; the
# tree is hashed under the current one, and under the base's when that differs.
sys.path.insert(0, "scripts/lib")
import scoring_hash


def hash_under(scheme):
    if scheme not in scoring_hash.SCHEMES:
        sys.stderr.write(f"check_scoring_governance: unknown hashing scheme {scheme!r}\n")
        raise SystemExit(2)
    try:
        return scoring_hash.SCHEMES[scheme]()
    except scoring_hash.ConfigError as error:
        sys.stderr.write(f"check_scoring_governance: {error}\n")
        raise SystemExit(2)


scheme = scoring_hash.CURRENT_SCHEME
current_hash, seen = hash_under(scheme)

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
if len(fields) not in (2, 3):
    sys.stderr.write(f"check_scoring_governance: {baseline_path} must hold '<version> <hash> <scheme>'\n")
    raise SystemExit(2)
recorded_version, recorded_hash = fields[:2]
recorded_scheme = scoring_hash.scheme_of(fields)
if recorded_scheme != scheme:
    problems.append(
        f"{baseline_path} was hashed under {recorded_scheme!r}, but this gate hashes under "
        f"{scheme!r}. Write '{version} {current_hash} {scheme}' to it."
    )
elif current_hash != recorded_hash and version == recorded_version:
    problems.append(
        f"scoring literals changed ({recorded_hash} -> {current_hash}) while "
        f"ScoringVersion.current stayed {version!r}. Bump the version and update "
        f"{baseline_path}, so stored scores stay attributable to the algorithm "
        "that produced them."
    )
elif (version, current_hash) != (recorded_version, recorded_hash):
    problems.append(
        f"{baseline_path} records {recorded_version} {recorded_hash}, but the code is "
        f"{version} {current_hash}. Write '{version} {current_hash} {scheme}' to it in the same "
        "change as the version bump, or the next constant change goes unchecked."
    )

# The base is compared under the scheme its baseline was written with, so a
# change of scheme leaves the comparison in force: the tree is rehashed the
# base's way, and any number that differs from the base still fails.
import os
base_fields = os.environ.get("BASE_BASELINE", "").split()
if len(base_fields) in (2, 3):
    base_version, base_hash = base_fields[:2]
    base_scheme = scoring_hash.scheme_of(base_fields)
    tree_hash = current_hash if base_scheme == scheme else hash_under(base_scheme)[0]
    if tree_hash != base_hash and version == base_version:
        problems.append(
            f"scoring literals differ from the base branch under its {base_scheme!r} scheme "
            f"({base_hash} -> {tree_hash}) while ScoringVersion.current is still the base's "
            f"{version!r}. Editing {baseline_path} does not stand in for a version bump."
        )

for problem in problems:
    print(f"  {problem}", file=sys.stderr)

print(f"check_scoring_governance: {seen} scoring literals hashed ({current_hash}) under {scheme}, "
      f"version {version}; rankingWeight contained to CauseDetection")

if problems:
    print(f"check_scoring_governance: {len(problems)} violation(s).", file=sys.stderr)
    raise SystemExit(1)
print("check_scoring_governance: clean.")
PY
