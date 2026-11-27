#!/usr/bin/env bash
set -euo pipefail

SOURCE_ROOT="${1:-Emuqu}"

SHARED_BUDGET_FILE="${SHARED_BUDGET_FILE:-.ci/shared_usage_budget.txt}"
TRY_OPTIONAL_BUDGET_FILE="${TRY_OPTIONAL_BUDGET_FILE:-.ci/try_optional_budget.txt}"
LARGE_FILE_BUDGET_FILE="${LARGE_FILE_BUDGET_FILE:-.ci/large_swift_files_1500_budget.txt}"
LARGE_FILE_THRESHOLD="${LARGE_FILE_THRESHOLD:-1500}"
# ObservableObject is legacy under the Observation framework (@Observable).
# This budget ratchets it toward zero — new code must use @Observable, and the
# number can only ever be lowered as types migrate. See docs/MAINTAINERS.md §9.1.
OBSERVABLE_OBJECT_BUDGET_FILE="${OBSERVABLE_OBJECT_BUDGET_FILE:-.ci/legacy_observable_object_budget.txt}"
# The flat `try?` budget treats a swallowed error on a cache READ the same as
# one on a WRITE. They are not the same: a failed
# read falls back to recompute, a failed write silently loses user data and
# surfaces days later as a missing session. This second budget isolates the
# write/encode/delete subset so it can be ratcheted to zero independently
# while the read-path count stays under the existing, looser budget.
TRY_OPTIONAL_WRITE_BUDGET_FILE="${TRY_OPTIONAL_WRITE_BUDGET_FILE:-.ci/try_optional_write_budget.txt}"
# The Watch target, counted the same five ways and held to one combined budget,
# as `check_refactor_spec_conformance.sh` does for it: it carries little of
# each kind, and a file per kind would be noise. It ratchets down like the rest.
WATCH_ROOT="${WATCH_ROOT:-EmuquWatch Watch App}"
WATCH_BUDGET_FILE="${WATCH_BUDGET_FILE:-.ci/watch_tech_debt_budget.txt}"

read_budget() {
    local file_path="$1"
    if [[ ! -f "$file_path" ]]; then
        echo "Budget file not found: $file_path" >&2
        exit 66
    fi
    local value
    value="$(tr -d '[:space:]' < "$file_path")"
    # A whole number only. `(( count > budget ))` with a budget of `83.0` is a
    # bash syntax error, which `if` reads as false: the gate would pass.
    # No leading zero either: bash reads `08` as octal, `(( count > 08 ))` is
    # an error, and `if` reads the error as false.
    if [[ ! "$value" =~ ^(0|[1-9][0-9]*)$ ]]; then
        echo "Budget file is not a whole number: $file_path" >&2
        exit 65
    fi
    echo "$value"
}

shared_budget="$(read_budget "$SHARED_BUDGET_FILE")"
try_optional_budget="$(read_budget "$TRY_OPTIONAL_BUDGET_FILE")"
large_file_budget="$(read_budget "$LARGE_FILE_BUDGET_FILE")"
observable_object_budget="$(read_budget "$OBSERVABLE_OBJECT_BUDGET_FILE")"
try_optional_write_budget="$(read_budget "$TRY_OPTIONAL_WRITE_BUDGET_FILE")"
watch_budget="$(read_budget "$WATCH_BUDGET_FILE")"

# `try?` on a line that also performs a write / encode / persist / delete.
# Deliberately line-scoped and conservative — it is a ratchet, not a proof.
#
# `.archive(`, `.flush(` and `.commit(` are in the list because the generic
# vocabulary of persistence is not this codebase's: its primary write is
# `SessionArchive.archive(_:)`, and a verb list that does not know "archive"
# lets `_ = try? archive.archive(...)` calls — the shape found in
# HealthKitManager, WorkoutSessionLifecycle+Metrics, RRCollector+NapRepairMigration,
# DashboardV2View+Cards and RecoveryScoreDetailView — sit in the tree while
# this gate reports 0. A swallowed archive write is a lost night of recorded
# data.
#
# Counted in Python rather than grep on purpose: this repo's shells disagree
# about `\b` (BSD grep / ugrep / GNU grep / rg all differ), and the rest of
# this script already tolerates that by counting simple literals. A word-
# boundary rule needs one unambiguous engine, and python3 is already a hard
# dependency here (enforce_swiftlint_budget.sh, Tools/copy_linter/lint.py).
# measure_debt <root>: prints the five counts for the Swift under <root>, in the
# order `.shared`, `try?`, `try?` on writes, large files, `ObservableObject`.
# It runs inside `$( )`, so a failed count returns 1 rather than exiting, and
# the caller checks that the output is five whole numbers.
measure_debt() {
    local root="$1" write pattern_counts shared try_optional observable large
    write="$(
    python3 - "$root" <<'PY'
import os
import re
import sys

root = sys.argv[1]
pattern = re.compile(
    # Verb PREFIXES of a call: `createDirectory(`, `removeItem(`, `setAttributes(`
    # and `write(to:` all count. A bare word rule misses every one of them.
    r"(?<![A-Za-z0-9_])try\?.*(?:\b(?:write|save|persist|encode|store|setValue|setAttributes|setResourceValue|create|remove|delete|move|copy|replace|trash|truncate|update|insert|upsert)[A-Za-z]*\s*\("
    # Call-shaped, not word-shaped. Here `archive` is both the write verb and
    # the name of the object it is called on, so a bare word match counts every
    # `try? archive.retrieve(...)` read as a write and the gate becomes noise.
    # (An apostrophe on this line would break the enclosing bash heredoc.)
    r"|\.(?:archive|flush|commit)\()",
    re.IGNORECASE,
)

count = 0
for dirpath, _dirnames, filenames in os.walk(root):
    for name in filenames:
        if not name.endswith(".swift"):
            continue
        path = os.path.join(dirpath, name)
        with open(path, encoding="utf-8", errors="replace") as handle:
            code = [l for l in handle.read().split("\n") if not l.strip().startswith("//")]
        # A call continued on the next line (`try? data\n    .write(to:)`) is
        # one statement: join leading-dot continuations before matching.
        for line in re.sub(r"\n\s*(?=\.)", "", "\n".join(code)).split("\n"):
            if pattern.search(line):
                count += 1
print(count)
PY
)" || return 1

# COUNTS CODE, NOT PROSE.
#
# An `rg -o` over raw file text counts every mention in a comment as a use.
# Documenting why a singleton is hard to remove raises the singleton count;
# describing a swallowed error raises the swallowed-error count; writing the
# sentence "exactly one of these is `.shared`" in a header comment moves the
# number the sentence is about. That makes a budget that only ratchets down
# actively hostile to explaining the debt it tracks — which is the one thing a
# solo maintainer most needs to leave behind.
#
# Same engine and same reasoning as the write-path counter above: one
# unambiguous regex implementation rather than four disagreeing greps.
    pattern_counts="$(
    python3 - "$root" <<'PY'
import pathlib
import re
import sys

# Blank comments to spaces rather than deleting them, so nothing on an adjacent
# line is accidentally joined into a match.
BLOCK = re.compile(r"/\*.*?\*/", re.DOTALL)
LINE = re.compile(r"//[^\n]*")


def strip_comments(source: str) -> str:
    source = BLOCK.sub(lambda m: re.sub(r"[^\n]", " ", m.group(0)), source)
    return LINE.sub(lambda m: " " * len(m.group(0)), source)


# `try\?` alone also matches the tail of an identifier — `SessionArchiveEntry?`,
# `ProviderRegistry?`, `CacheEntry?` — and counts dozens of phantom entries as
# debt. A lookbehind restricts it to the actual keyword.
#
# Apple framework singletons are not this app dependency-injection debt.
# `URLSession.shared`, `UIApplication.shared` and the rest belong to the
# platform API; no version of this codebase injects them away, so counting
# them makes the number unmovable and therefore meaningless. The app
# singletons are confined to the composition root, which
# `check_no_shared_outside_root.sh` proves separately. What stays counted is
# the composition root list, which is the number that can still grow.
PLATFORM_SINGLETONS = (
    "URLSession", "UIApplication", "MXMetricManager", "AVAudioApplication",
    "WidgetCenter", "AppTransaction", "AVAudioSession", "FileManager",
    "NotificationCenter", "UNUserNotificationCenter", "WCSession", "HKHealthStore",
)
PLATFORM = re.compile(r"\b(?:" + "|".join(PLATFORM_SINGLETONS) + r")\.shared\b")

PATTERNS = [
    re.compile(r"\.shared\b"),
    re.compile(r"(?<![A-Za-z0-9_])try\?"),
    re.compile(r"\bObservableObject\b"),
]
counts = [0, 0, 0]
for path in pathlib.Path(sys.argv[1]).rglob("*.swift"):
    code = strip_comments(path.read_text(encoding="utf-8", errors="ignore"))
    code = PLATFORM.sub(lambda m: " " * len(m.group(0)), code)
    for index, pattern in enumerate(PATTERNS):
        counts[index] += len(pattern.findall(code))
print(" ".join(str(c) for c in counts))
PY
)" || return 1
    read -r shared try_optional observable <<<"$pattern_counts"
    large="$(find "$root" -name '*.swift' -print0 | xargs -0 wc -l | awk -v min="$LARGE_FILE_THRESHOLD" '$1 >= min && $2 != "total" { count++ } END { print count + 0 }')" || return 1
    printf '%s %s %s %s %s\n' "$shared" "$try_optional" "$write" "$large" "$observable"
}

# A missing root would count as zero debt, which is not the same as none.
for root in "$SOURCE_ROOT" "$WATCH_ROOT"; do
    if [[ ! -d "$root" ]]; then
        echo "Source root not found: $root" >&2
        exit 66
    fi
done
app_counts="$(measure_debt "$SOURCE_ROOT")" || { echo "Counting failed under $SOURCE_ROOT" >&2; exit 70; }
watch_counts="$(measure_debt "$WATCH_ROOT")" || { echo "Counting failed under $WATCH_ROOT" >&2; exit 70; }
for counts in "$app_counts" "$watch_counts"; do
    if [[ ! "$counts" =~ ^[0-9]+\ [0-9]+\ [0-9]+\ [0-9]+\ [0-9]+$ ]]; then
        echo "Counting produced no usable numbers: '$counts'" >&2
        exit 70
    fi
done
read -r shared_count try_optional_count try_optional_write_count large_file_count observable_object_count <<<"$app_counts"
read -r w_shared w_try_optional w_try_optional_write w_large w_observable <<<"$watch_counts"
# `try?` already counts every `try?`, those on write paths included, so the
# write-path count is shown but not added again.
watch_count=$(( w_shared + w_try_optional + w_large + w_observable ))

summary_lines=(
    "Tech debt budgets:"
    "- .shared usage: ${shared_count} (budget: ${shared_budget})"
    "- try? usage: ${try_optional_count} (budget: ${try_optional_budget})"
    "- try? on write/encode/delete paths: ${try_optional_write_count} (budget: ${try_optional_write_budget}; ratchet toward 0)"
    "- Swift files >= ${LARGE_FILE_THRESHOLD} lines: ${large_file_count} (budget: ${large_file_budget})"
    "- ObservableObject (legacy; prefer @Observable): ${observable_object_count} (budget: ${observable_object_budget})"
    "- ${WATCH_ROOT}: ${watch_count} in all (budget: ${watch_budget}): .shared ${w_shared}, try? ${w_try_optional} (${w_try_optional_write} of them on writes), large files ${w_large}, ObservableObject ${w_observable}"
)

failed=0

# Slack fails the gate. Printing it was not enough: a budget drifted above its
# measured value (`.shared` 83 against 90, `try?` 139 against 170) and every
# addition up to the budget passed green — seven new `.shared` reads and 31
# new swallowed errors, undetectable. The invariant `check_budget_monotonicity.sh`
# states in its own header — "every budget currently sits exactly at its
# measured value" — is now enforced here: a change that removes debt lowers the
# budget file in the same commit.
slack_lines=()
note_slack() {
    local label="$1" count="$2" budget="$3" file="$4"
    if (( count < budget )); then
        slack_lines+=("- FAIL (slack): ${label} is ${count} against a budget of ${budget}; lower ${file} to ${count} in this change to lock the gain in")
        failed=1
    fi
}
note_slack ".shared usage" "$shared_count" "$shared_budget" "$SHARED_BUDGET_FILE"
note_slack "try? usage" "$try_optional_count" "$try_optional_budget" "$TRY_OPTIONAL_BUDGET_FILE"
note_slack "try? on write paths" "$try_optional_write_count" "$try_optional_write_budget" "$TRY_OPTIONAL_WRITE_BUDGET_FILE"
note_slack "large files" "$large_file_count" "$large_file_budget" "$LARGE_FILE_BUDGET_FILE"
note_slack "ObservableObject" "$observable_object_count" "$observable_object_budget" "$OBSERVABLE_OBJECT_BUDGET_FILE"
note_slack "Watch debt" "$watch_count" "$watch_budget" "$WATCH_BUDGET_FILE"
if (( ${#slack_lines[@]} > 0 )); then
    summary_lines+=("${slack_lines[@]}")
fi

if (( shared_count > shared_budget )); then
    summary_lines+=("- FAIL: .shared usage exceeded budget")
    failed=1
fi

if (( try_optional_count > try_optional_budget )); then
    summary_lines+=("- FAIL: try? usage exceeded budget")
    failed=1
fi

if (( try_optional_write_count > try_optional_write_budget )); then
    summary_lines+=("- FAIL: try? on write/encode/delete paths exceeded budget — a swallowed write error is silent data loss")
    failed=1
fi

if (( large_file_count > large_file_budget )); then
    summary_lines+=("- FAIL: large Swift file count exceeded budget")
    failed=1
fi

if (( observable_object_count > observable_object_budget )); then
    summary_lines+=("- FAIL: ObservableObject usage exceeded budget — new types must use @Observable")
    failed=1
fi

if (( watch_count > watch_budget )); then
    summary_lines+=("- FAIL: ${WATCH_ROOT} debt exceeded budget")
    failed=1
fi

printf '%s\n' "${summary_lines[@]}"

if [[ -n "${GITHUB_STEP_SUMMARY:-}" ]]; then
    {
        echo "## Tech Debt Budgets"
        echo
        echo '```text'
        printf '%s\n' "${summary_lines[@]}"
        echo '```'
    } >> "$GITHUB_STEP_SUMMARY"
fi

if (( failed != 0 )); then
    exit 1
fi
