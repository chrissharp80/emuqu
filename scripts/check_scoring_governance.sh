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
# 2. The code that decides a stored score is hashed token by token
#    (scripts/lib/scoring_hash.py, scheme `stored-defuse`). Nothing in it is
#    listed by hand. It starts from the expressions a stored score field is
#    given (the score, its breakdown, the analysis result, the frozen
#    readiness, the training, vitals and sleep snapshots, the HRV quality,
#    the baseline's stored nights), the arguments of every stored type's
#    initializer, and the conditions that decide whether each write runs.
#    From there it follows what those expressions use: the functions they
#    call (into their return expressions), the locals they read back to
#    where they are defined, the parameters they read back to the argument
#    each caller passes, the closures a caller hands over back to where they
#    are invoked, the properties they read back to every write of them, and
#    a value stored by key (UserDefaults, the Keychain, a file) that a hashed
#    reader loads back to the write that stores it.
#    Receivers are typed by inference; where a receiver's type is unknown, a
#    name with few declarations is taken whole, a common one only for its
#    Analysis functions and cases. SwiftUI views and copy-only types are not
#    hashed. Numbers, operators and names all count; comments, whitespace,
#    string contents and access modifiers do not, and each token is keyed by
#    the declaration it sits in, so moving or reordering declarations leaves
#    the hash alone. Change a weight, a band, a threshold, a comparison, the
#    baseline's admission rule or the night key it counts by, and the hash
#    moves; the gate then requires ScoringVersion.current to have moved too.
#    This is what stops an archive quietly becoming a mixture of two
#    algorithms under one version string, the failure the version stamp
#    exists to prevent. Saving, syncing, speaking and drawing a score are
#    not hashed, so editing them needs no bump.
#
#    The gate also checks its own coverage on every run: every body token of
#    a hashed function, found by bracket matching alone, must be filed under
#    that function; a number planted in each hashed declaration must land in
#    its hashed tokens; and every Analysis function the traced expressions
#    name must be hashed. A failure there is a hole in the hash, and the gate goes red.
#
#    The base's own sources must hash under the current scheme. A scheme whose
#    roots the base lacks cannot hash it, and that fails (exit 2) rather than
#    skipping the comparison, unless SCORING_ALLOW_UNHASHABLE_BASE=1 is set.
#
#    The baseline line is `<version> <hash> <scheme>`. A change to how the
#    hash is computed rehashes with no scoring change, so the scheme is
#    recorded and a base is always compared under its own scheme: the tree
#    is hashed the base's way too, and a number that moved still fails. The
#    base's own sources are hashed under the current scheme as well, so a
#    scheme that measures more cannot carry a change only it sees.
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
    # The base's own sources, so they can be hashed under this gate's scheme.
    BASE_TREE="$(mktemp -d)"
    trap 'rm -rf "$BASE_TREE"' EXIT
    if ! git archive "$MERGE_BASE" Emuqu/Sources | tar -x -C "$BASE_TREE"; then
        echo "check_scoring_governance: cannot read the sources at $MERGE_BASE" >&2
        exit 2
    fi
    export BASE_TREE
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
for hole in scoring_hash.self_check():
    problems.append(f"coverage: {hole}")

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

# The base's sources hashed under the current scheme too, so a change of
# scheme that measures more (an operator, a constant outside the scoring
# files) cannot carry an edit only the new scheme sees: the base and the tree
# are compared under one scheme. A base the current scheme cannot read (a
# root it lacks) is a configuration error, not a pass: skipping the
# comparison let a scheme that names a declaration only the tree has carry
# any scoring change past the gate. SCORING_ALLOW_UNHASHABLE_BASE=1 skips it
# on purpose, for a scheme change that has to name a new declaration; the
# run says so.
base_tree = os.environ.get("BASE_TREE", "")
if base_tree and len(base_fields) in (2, 3) and version == base_fields[0]:
    import subprocess
    run = subprocess.run(
        [sys.executable, str(pathlib.Path("scripts/lib/scoring_hash.py").resolve()), scheme],
        cwd=base_tree, capture_output=True, text=True,
    )
    base_now = run.stdout.split()[0] if run.returncode == 0 and run.stdout.split() else ""
    if not base_now:
        reason = (run.stderr or run.stdout).strip() or f"exit {run.returncode}"
        if os.environ.get("SCORING_ALLOW_UNHASHABLE_BASE") != "1":
            sys.stderr.write(
                f"check_scoring_governance: the base's sources cannot be hashed under {scheme!r} ({reason}), "
                "so the change cannot be compared with the base. Make every root of the scheme one the base "
                "has, or set SCORING_ALLOW_UNHASHABLE_BASE=1 to skip this comparison on purpose.\n"
            )
            raise SystemExit(2)
        print(f"check_scoring_governance: note: base comparison under {scheme!r} skipped "
              f"(SCORING_ALLOW_UNHASHABLE_BASE=1): {reason}", file=sys.stderr)
    if base_now and base_now != current_hash:
        problems.append(
            f"scoring code differs from the base branch under the current {scheme!r} scheme "
            f"({base_now} -> {current_hash}) while ScoringVersion.current is still the base's "
            f"{version!r}."
        )

for problem in problems:
    print(f"  {problem}", file=sys.stderr)

print(f"check_scoring_governance: {seen} scoring tokens hashed ({current_hash}) under {scheme}, "
      f"version {version}; rankingWeight contained to CauseDetection")

if problems:
    print(f"check_scoring_governance: {len(problems)} violation(s).", file=sys.stderr)
    raise SystemExit(1)
print("check_scoring_governance: clean.")
PY
