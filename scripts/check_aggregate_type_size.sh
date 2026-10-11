#!/usr/bin/env bash
#
# CI guard: how big is a TYPE, summed across every file that extends it.
#
# Why this exists. `.ci/large_swift_files_1500_budget.txt`
# is 0 and no file in the repository exceeds 1,500 lines. Both true, and both
# blind to the thing the limit is for: a type split across N files is invisible
# to a per-file limit. The per-file gate reports zero while a type such as
# RRCollector runs to thousands of lines across 23 files — and one of those
# files exists specifically to let the other 22 pretend the sub-objects are not
# there. The refactor spec asks for modules "comprehensible without jumping
# across the codebase" and says "if a module requires a tour, it is too big".
#
# Splitting by concern is a real improvement and the filenames here are a good
# table of contents — this gate is not an argument against extensions. It is
# the number that says whether the split reduced the type or just relocated it.
#
# TWO budgets, both in `.ci/`, both ratcheting DOWN:
#
#   aggregate_type_size_budget.txt    how many types exceed the threshold
#   aggregate_type_excess_budget.txt  how many lines they exceed it BY, summed
#
# The count alone is not a gate, because a count cannot see growth. RRCollector
# could go from 6,691 lines to 20,000 without changing it: the type is over the
# threshold either way, so the count holds and the gate stays green while the
# thing it measures triples. The excess figure is the
# one that moves when a big type grows, and it moves in the right direction when
# a split genuinely reduces a type rather than relocating it.
#
# What it measures: the bodies of every top-level declaration and extension of
# a name, across the scanned tree (comments and string literals masked, so
# their braces do not count). What it does NOT measure: file-scope functions
# and separate sibling types that exist only to serve a type — code moved there
# leaves the type's total, which is a known way round this gate.
#
# Exit 0 clean, 1 over either budget, 2 on config error or a declaration whose
# braces never balance (that type cannot be measured, so it is not reported as
# zero).

set -uo pipefail
cd "$(dirname "$0")/.."

SCAN_DIR="${1:-Emuqu/Sources}"
BUDGET_FILE="${AGGREGATE_TYPE_BUDGET_FILE:-.ci/aggregate_type_size_budget.txt}"
EXCESS_BUDGET_FILE="${AGGREGATE_TYPE_EXCESS_BUDGET_FILE:-.ci/aggregate_type_excess_budget.txt}"
THRESHOLD="${AGGREGATE_TYPE_THRESHOLD:-1500}"

if [[ ! -d "$SCAN_DIR" ]]; then
    echo "check_aggregate_type_size: scan directory missing: $SCAN_DIR" >&2
    exit 2
fi
# Assigns into the variable named by $2 via `printf -v` rather than echoing.
# A `budget="$(read_budget ...)"` form would run the function in a SUBSHELL, so
# its `exit 2` would end the subshell and leave the caller with an empty budget
# — which `(( count > budget ))` reads as zero and reports as a budget failure.
# A config error must not be able to masquerade as a debt finding.
read_budget() {
    local file="$1" value
    if [[ ! -f "$file" ]]; then
        echo "check_aggregate_type_size: missing budget file: $file" >&2
        exit 2
    fi
    value="$(tr -d '[:space:]' < "$file")"
    if [[ ! "$value" =~ ^[0-9]+$ ]]; then
        echo "check_aggregate_type_size: budget file is not an integer: $file" >&2
        exit 2
    fi
    printf -v "$2" '%s' "$value"
}

read_budget "$BUDGET_FILE" budget
read_budget "$EXCESS_BUDGET_FILE" excess_budget

MEASURED="$(python3 - "$SCAN_DIR" "$THRESHOLD" <<'PY'
import collections
import pathlib
import re
import sys

scan_dir, threshold = sys.argv[1], int(sys.argv[2])

DECL = re.compile(
    r'^\s*(?:@[\w()., *:"\-]+\s+)*'
    r'((?:(?:public|internal|private|fileprivate|open|final|package|indirect|@objc)\s+)*)'
    r'(class|struct|enum|actor|extension|protocol)\s+([\w.]+)'
)
QUOTE = re.compile(r'(#*)("""|")')


def blank(text):
    return ''.join('\n' if ch == '\n' else ' ' for ch in text)


def comment_end(text, i):
    """End of the (nestable) block comment opening at i."""
    depth = 0
    while i < len(text):
        if text.startswith('/*', i):
            depth, i = depth + 1, i + 2
        elif text.startswith('*/', i):
            depth, i = depth - 1, i + 2
            if depth == 0:
                return i
        else:
            i += 1
    return i


def string_end(text, i, hashes, quote):
    """End of the string literal whose opening delimiter ends at i."""
    close = quote + hashes
    while i < len(text):
        if not hashes and text[i] == '\\':
            i += 2
        elif text.startswith(close, i):
            return i + len(close)
        elif quote == '"' and text[i] == '\n':
            return i
        else:
            i += 1
    return i


def mask(text):
    """Blank comments and string literals (newlines kept), so braces and
    keywords inside them are neither counted nor matched. Covers block
    comments and multi-line and raw strings, which a per-line strip misses."""
    out, i = [], 0
    while i < len(text):
        quote = QUOTE.match(text, i)
        if text.startswith('//', i):
            end = text.find('\n', i)
            end = len(text) if end < 0 else end
        elif text.startswith('/*', i):
            end = comment_end(text, i)
        elif quote:
            end = string_end(text, quote.end(), quote.group(1), quote.group(2))
        else:
            out.append(text[i])
            i += 1
            continue
        out.append(blank(text[i:end]))
        i = end
    return ''.join(out)


def body_end(lines, index):
    """Line on which the declaration at index closes, or None if it never does."""
    depth, started = 0, False
    for end in range(index, len(lines)):
        for char in lines[end]:
            if char == '{':
                depth, started = depth + 1, True
            elif char == '}':
                depth -= 1
        if started and depth == 0:
            return end
    return None


sizes = collections.Counter()
files = collections.defaultdict(set)
kinds = {}
unbalanced = []

for path in sorted(pathlib.Path(scan_dir).rglob('*.swift')):
    lines = mask(path.read_text(encoding='utf-8', errors='ignore')).split('\n')
    index = 0
    while index < len(lines):
        match = DECL.match(lines[index])
        if not match:
            index += 1
            continue
        modifiers, kind, name = match.group(1), match.group(2), match.group(3)
        # A private or fileprivate type is visible only in its own file, so two
        # of them with one name are two types; keying them by bare name summed
        # every private `Row` in the tree into one.
        if kind != 'extension' and re.search(r'\b(?:private|fileprivate)\b', modifiers):
            name = f"{name}@{path.name}"
        end = body_end(lines, index)
        if end is None:
            # A body that never closes is a parse failure, not a zero-line type.
            unbalanced.append(f"{path}:{index + 1} {name}")
            index += 1
            continue
        sizes[name] += end - index + 1
        files[name].add(str(path))
        if kind != 'extension':
            kinds[name] = kind
        index = end + 1

over = [(size, name) for name, size in sizes.items() if size > threshold]
over.sort(reverse=True)
print(len(over))
print(sum(size - threshold for size, _ in over))
for size, name in over[:12]:
    print(f"OVER {size} {len(files[name])} {kinds.get(name, 'extension-only')} {name}")
for where in unbalanced:
    print(f"UNBALANCED {where}")
PY
)"

if [[ -z "$MEASURED" ]]; then
    echo "check_aggregate_type_size: measurement produced no output." >&2
    exit 2
fi

if printf '%s\n' "$MEASURED" | grep -q '^UNBALANCED '; then
    echo "check_aggregate_type_size: a declaration's braces never balance, so its size cannot be measured:" >&2
    printf '%s\n' "$MEASURED" | sed -n 's/^UNBALANCED /    /p' >&2
    exit 2
fi

count="$(printf '%s\n' "$MEASURED" | sed -n '1p')"
excess="$(printf '%s\n' "$MEASURED" | sed -n '2p')"

echo "Types larger than ${THRESHOLD} lines summed across all their files: ${count} (budget: ${budget}; ratchet toward 0)"
echo "Total lines those types exceed ${THRESHOLD} by: ${excess} (budget: ${excess_budget}; ratchet toward 0)"
printf '%s\n' "$MEASURED" | grep '^OVER ' | while read -r _ size nfiles kind name; do
    printf '    %6s lines across %2s file(s)  %-9s %s\n' "$size" "$nfiles" "$kind" "$name"
done

failed=0
if (( count > budget )); then
    echo >&2
    echo "ERROR: aggregate type size count exceeded budget (${count} > ${budget})." >&2
    echo "A type split across N files is still one type. Extract a collaborator" >&2
    echo "with its own state, or lower nothing and explain why." >&2
    failed=1
fi

if (( excess > excess_budget )); then
    echo >&2
    echo "ERROR: aggregate type excess exceeded budget (${excess} > ${excess_budget})." >&2
    echo "An over-threshold type grew. The count gate cannot see this: a type that" >&2
    echo "was already over stays over however much it gains." >&2
    failed=1
fi

(( failed )) && exit 1

if (( count < budget )); then
    echo "check_aggregate_type_size: below budget — lower ${BUDGET_FILE} to ${count} to lock the gain in."
fi

if (( excess < excess_budget )); then
    echo "check_aggregate_type_size: below excess budget — lower ${EXCESS_BUDGET_FILE} to ${excess} to lock the gain in."
fi

echo "check_aggregate_type_size: clean."
