#!/usr/bin/env bash
#
# CI guard: the refactor spec's mechanically-checkable rules, measured.
#
# Why this exists. `docs/REFACTOR_SPEC.md` ends in a "Refactor Completion
# Checklist (Hard Gate)" of 29 items. A checklist nothing in CI measures is not
# a gate: the only items that hold are the ones that happen to overlap a
# SwiftLint rule — and extractions that stop at SwiftLint's 100-line budget,
# not the spec's 20, are exactly what an unmeasured standard looks like after
# a year.
#
# This measures the four checklist items that can be checked mechanically and
# are not already covered by another gate:
#
#   * "Functions are <= 20 lines"        -> `.ci/spec_long_functions_budget.txt`
#   * "Nesting depth is <= 2"            -> `.ci/spec_deep_nesting_budget.txt`
#   * the same two rules applied to computed properties and inits
#                                        -> `.ci/spec_long_properties_budget.txt`
#                                        -> `.ci/spec_deep_nesting_properties_budget.txt`
#   * "All commented-out code removed"   -> `.ci/spec_commented_code_budget.txt`
#   * "No swallowed errors, no empty catches" -> hard zero, no budget
#
# Deliberately NOT re-measured here, because another gate already owns them:
# `try?` counts and `.shared` counts (enforce_tech_debt_budgets.sh), log
# redaction (check_log_redaction.sh), magic numbers and most naming rules
# (SwiftLint), dead code (check_no_orphan_swift.sh).
#
# The remaining checklist items — behavioural parity, purity, one-directional
# data flow, "names describe exactly what they do" — are judgement calls. A
# script that pretended to score them would be worse than no script, so this
# one does not try.
#
# THE WAIVER BUDGETS START AT ZERO, AND THAT IS DELIBERATE.
#
# A waiver mechanism that gets used eight times and then has its budget set to
# eight, all in one sitting, at the exact moment a refactor pushes the
# unjustified count up and cannot meet it, is not what "rare, justified
# exceptions" means; it is the same escape the codebase already has
# (`swiftlint:disable:next function_body_length` plus a note calling the
# function "long by construction"), which is how it drifts this far.
#
# The mechanism stays, because the spec really does allow exceptions. The budget
# is zero, so taking one means editing a budget file that only ratchets down and
# check_budget_monotonicity.sh will show it in the diff. The door exists, it is
# locked, and opening it is visible.
#
# Budgets ratchet DOWN only; `check_budget_monotonicity.sh` enforces that.
# The numbers start where the codebase actually is, not where we wish it were —
# same convention as every other budget in `.ci/`.
#
# Exit 0 clean, 1 over budget, 2 on config error.

set -uo pipefail
cd "$(dirname "$0")/.."

# The whole target, not `Emuqu/Sources`. The narrower root silently excludes
# the one file outside it: `Emuqu/EmuquApp.swift`, the app's root, whose `body`
# can grow into a single expression hundreds of lines long that no gate looks
# at — the kind of property that costs seconds of type-check time and is found
# only when a sibling tips past the frontend's hard limit and fails CI with
# "unable to type-check this expression in reasonable time". `Emuqu/` holds no
# other Swift outside `Sources/`, so this adds exactly that one file.
SCAN_DIR="Emuqu"

# `EmuquWatch Watch App` is measured too. Left out of this gate, a 25-line
# function injected into `WatchApp.swift` leaves `make spec-conformance` green,
# and those are lines that ship to users.
#
# One combined budget rather than four, because the watch is 7 files and the
# per-axis detail the app target needs would be noise here. It ratchets down
# like every other budget; the app-target budgets are untouched, so this is a
# new budget rather than a raise.
WATCH_SCAN_DIR="EmuquWatch Watch App"
WATCH_BUDGET_FILE=".ci/spec_watch_budget.txt"
if [[ ! -d "$SCAN_DIR" ]]; then
    echo "check_refactor_spec_conformance: scan directory missing: $SCAN_DIR" >&2
    exit 2
fi

read_budget() {
    local file=".ci/$1"
    if [[ ! -f "$file" ]]; then
        echo "check_refactor_spec_conformance: missing budget file: $file" >&2
        exit 2
    fi
    tr -d '[:space:]' < "$file"
}

LONG_BUDGET="$(read_budget spec_long_functions_budget.txt)"
NEST_BUDGET="$(read_budget spec_deep_nesting_budget.txt)"
COMMENT_BUDGET="$(read_budget spec_commented_code_budget.txt)"

measure_spec() {
python3 - "$1" <<'PY'
import re, sys, pathlib

# COMPUTED PROPERTIES AND INITS ARE MEASURED, NOT ONLY `func`.
#
# A declaration pattern of `func\s+(\w+)` sees functions and nothing else. It
# reports 0 long functions and 0 deep nesting, both numbers true, and both
# blind to the half of the codebase where SwiftUI code actually lives:
# `var body: some View`, `var entries: [Fact]`, and every other computed
# property, plus every `init`. That is where the violations sit — a `body`
# such as `RecordView.body` runs to hundreds of lines at depth 8 — and the
# great majority of them are under Views/, which is about half the app by line
# count, carries nearly all of the deep nesting, and has the lowest line
# coverage: the untested half and the unmeasured half are the same half.
#
# Properties are counted and budgeted SEPARATELY from functions on purpose. The
# function counters sit at 0 after a long decomposition effort, and folding
# hundreds of property violations into them would erase that and leave one
# number nobody can act on. Two axes, two budgets, both ratcheting down.

MODS = (r'(?:@[\w()., *:"\-]+\s+)*'
        r'(?:(?:open|public|internal|private|fileprivate|package|static|class|final'
        r'|override|nonisolated|mutating|nonmutating|required|convenience|dynamic)'
        r'(?:\([\w ]+\))?\s+)*')

FUNC = re.compile(r'^\s*' + MODS + r'func\s+(?P<name>\w+)')
# A computed property is colon-typed and opens a brace with no `=` before it.
# `var x = 0 { didSet {...} }` is a STORED property with an observer and is not
# a unit of logic; requiring the type annotation and forbidding `=` excludes it.
PROP = re.compile(r'^\s*' + MODS + r'var\s+(?P<name>\w+)\s*:\s*[^={]+\{\s*$')
INIT = re.compile(r'^\s*' + MODS + r'(?P<name>init|subscript)\b')
# A stored property initialised by an immediately-invoked closure matches none
# of the three patterns above. `FUNC` needs `func`; `PROP` forbids `=`
# (deliberately, to exclude `var x = 0 { didSet { … } }`); `INIT` needs
# `init`. Without this pattern the shape is unmeasured:
#
#     private lazy var session: URLSession = {
#         ... 41 lines ...
#     }()
#
# That is a function body with a different keyword in front of it —
# `OpenAICompatibleStreamer.session`, `Archive+Migrations.relinkEncoder` and
# `StoreKitManager.isPurchased` are all this shape at 28 to 41 lines. The spec
# limit is about how much logic sits in one unreadable place, not about
# which keyword introduced it.
CLOSURE_PROP = re.compile(
    r'^\s*' + MODS + r'(?:lazy\s+)?(?:let|var)\s+(?P<name>\w+)\s*'
    r'(?::\s*[^={]+?)?\s*=\s*\{\s*$'
)

# Commented-out CODE, not prose that happens to start with a keyword.
#
# A naive version of this — "a // line beginning with let/if/for/return" —
# reports well over a hundred hits, every single one a sentence: "// for a fresh start",
# "// while the LLM is still streaming", "// if consent was revoked mid-session".
# A gate measuring the wrong thing is worse than no gate, so each pattern below
# demands a syntactic signal: an assignment, a trailing brace, call parens.
CODE_PATTERNS = [
    re.compile(r'^\s*//\s*[}{]\s*$'),
    re.compile(r'^\s*//\s*(let|var)\s+\w+\s*(:\s*[\w\[\]<>?., ]+)?\s*='),
    re.compile(r'^\s*//\s*(private\s+|public\s+|static\s+|final\s+)*func\s+\w+\s*\('),
    re.compile(r'^\s*//\s*(if|guard|for|while|switch)\b.*\{\s*$'),
    re.compile(r'^\s*//\s*\w+(\.\w+)+\([^)]*\)\s*;?\s*$'),
    re.compile(r'^\s*//\s*(try|await)\s+\w+(\.\w+)*\('),
    re.compile(r'^\s*//\s*return\s+\w+(\.\w+)*\([^)]*\)\s*$'),
]
# A block that shows callers HOW to use the thing is documentation, not a
# corpse. Skip the whole contiguous comment block when it announces itself.
EXAMPLE_MARKER = re.compile(r'(Usage|Example|For example|e\.g\.)\s*:?', re.IGNORECASE)
COMMENT_LINE = re.compile(r'^\s*//')
# NOT `catch\s*\{\s*\}` ON RAW TEXT.
#
# One comment defeats that: `catch { // ignore\n }` passes, and so does
# `catch { _ = error }`, so comment-only catches sit in the tree while the gate
# prints "Empty catch blocks: 0" against a hard zero. The shape to picture is
# `AssistantArtifactStore.load()` catching `DecodingError` behind the comment
# "First run — file doesn't exist yet" and letting the next `persist()`
# atomically overwrite the user's artifacts with an empty list.
#
# The rule: a `catch` body with no statement in it — comments and whitespace
# only — swallows the error (see `swallowed_catches`). The escape hatch is
# explicit and greppable, in the same shape as `check_log_redaction.sh`'s:
#
#     } catch {
#         // swallow-ok: interruptions in a polling loop are expected
#     }
#
# A reason is required. A bare marker is reported as malformed.
CATCH_BLOCK = re.compile(r'catch\s*(?:\w[\w\s,.()]*?\s*)?\{')
SWALLOW_OK = re.compile(r'//\s*swallow-ok:\s*\S')
SWALLOW_MARKER_ONLY = re.compile(r'//\s*swallow-ok:?\s*$')


def catch_bodies(source):
    """Yield the text of every `catch { ... }` body."""
    for match in CATCH_BLOCK.finditer(source):
        depth = 0
        start = match.end() - 1
        for index in range(start, len(source)):
            if source[index] == '{':
                depth += 1
            elif source[index] == '}':
                depth -= 1
                if depth == 0:
                    yield source[start + 1:index]
                    break


def swallowed_catches(source):
    """(swallowed, malformed_markers) — catches that discard the error."""
    swallowed = 0
    malformed = 0
    for body in catch_bodies(source):
        if SWALLOW_MARKER_ONLY.search(body) and not SWALLOW_OK.search(body):
            malformed += 1
            continue
        if SWALLOW_OK.search(body):
            continue
        # A body with no STATEMENT in it is the empty catch the spec forbids.
        # Comments and whitespace are not handling.
        #
        # Deliberately NOT "the body never mentions `error`": that rule
        # reports dozens of sites, almost all of them genuine handling —
        # `catch { continuation.finish(throwing: .cancelled) }` converts to a
        # typed error, `catch { break }` exits a cancellation loop,
        # `catch { return nil }` makes absence the signal, and
        # `catch let nsError as NSError` binds a differently-named value. A
        # gate whose findings are overwhelmingly correct code teaches people
        # to ignore it.
        code = re.sub(r'/\*.*?\*/', '', re.sub(r'//[^\n]*', '', body), flags=re.DOTALL)
        if not code.strip():
            swallowed += 1
    return swallowed, malformed

# The spec own words are "Functions are <= 20 lines (rare, justified
# exceptions only)" and "Nesting depth is <= 2 (rare, justified exceptions
# only)". A gate with no notion of an exception measures a STRICTER rule than
# the spec states, which is its own kind of dishonesty — and it makes the target
# unreachable, so nobody aims at it.
#
# An exception is declared in the code, above the declaration:
#
#     // spec:long-function <why this one is genuinely a table, not logic>
#     // spec:deep-nesting  <why flattening this would obscure it>
#
# The reason is mandatory — a bare marker does not count and is reported as
# malformed. Justified declarations are counted separately and capped by their
# own budget, so "justify everything" is not an escape hatch.
SPEC_LONG_OK = re.compile(r'^\s*//\s*spec:long-function\s+(?P<why>\S.*)$')
SPEC_NEST_OK = re.compile(r'^\s*//\s*spec:deep-nesting\s+(?P<why>\S.*)$')
SPEC_MARKER_ANY = re.compile(r'^\s*//\s*spec:(long-function|deep-nesting)\s*$')


def waiver_above(lines, decl_index, pattern):
    # Scan the contiguous comment block immediately above the declaration.
    k = decl_index - 1
    while k >= 0 and re.match(r'^\s*(///|//|@\w+)', lines[k]):
        if pattern.match(lines[k]):
            return True
        k -= 1
    return False


def malformed_waiver_above(lines, decl_index):
    k = decl_index - 1
    while k >= 0 and re.match(r'^\s*(///|//|@\w+)', lines[k]):
        if SPEC_MARKER_ANY.match(lines[k]):
            return True
        k -= 1
    return False


# Count commented-out code, skipping documentation example blocks.
def commented_out_code_lines(lines):
    total = 0
    i = 0
    while i < len(lines):
        if not COMMENT_LINE.match(lines[i]):
            i += 1
            continue
        start = i
        while i < len(lines) and COMMENT_LINE.match(lines[i]):
            i += 1
        block = lines[start:i]
        if any(EXAMPLE_MARKER.search(line) for line in block):
            continue
        total += sum(1 for line in block if any(p.match(line) for p in CODE_PATTERNS))
    return total

MAX_BODY = 20
MAX_DEPTH = 2

def strip(line: str) -> str:
    line = re.sub(r'"(?:[^"\\]|\\.)*"', '""', line)
    return re.sub(r'//.*$', '', line)


# THE BODY BRACE IS FOUND BY PAREN DEPTH, NOT BY LINE OFFSET.
#
# A walker that scans forward line by line from the declaration, treats the
# first `{` it sees as the body brace, and gives up entirely if it has not
# found one within ten lines has two silent evasions:
#
#   (a) `if not started and j - i > 10: break` abandons any declaration whose
#       body brace sits more than ten lines below the `func`/`init` keyword.
#       `RRCollector.init` has a twenty-parameter signature; its brace is 27
#       lines down, and a 126-line body at nesting depth 3 is reported as
#       nothing at all.
#
#   (b) Terminating on `if started and depth == 0` at end of line means a
#       BALANCED `{}` inside the SIGNATURE ends the measurement. A default
#       closure parameter on its own line —
#       `progress: @escaping (Int, Int) -> Void = { _, _ in }` — makes such a
#       walker report a body of MINUS ONE line. `retroApplySleepSettings` (114
#       lines, depth 4) and `recoverFromBackup` (104 lines, depth 4) both hide
#       there.
#
# Between them, a dozen-odd declarations over the 20-line limit and several
# nested deeper than 2 go unreported while the gate prints 0 and 0 and the
# budgets sit at zero. A gate that cannot see the largest thing it measures is
# worse than no gate, because the zero gets believed.
#
# So a `{` only opens the body when it is not inside the parameter list, the
# generic clause, or a default value. No line cap is needed once the rule is
# right.
def find_body_brace(lines, decl_index, max_lookahead=400):
    """(brace_line, brace_col) of the declaration's body brace, or None.

    Scans forward from the declaration tracking (), [] and <> depth. A `{` at
    depth 0 opens the body. A `{` at depth > 0 is a default value or a closure
    type inside the signature and is skipped along with its matching `}`.
    """
    depth = 0
    brace_in_signature = 0
    for offset in range(max_lookahead):
        index = decl_index + offset
        if index >= len(lines):
            return None
        line = strip(lines[index])
        for col, ch in enumerate(line):
            if ch in '([':
                depth += 1
            elif ch in ')]':
                depth = max(0, depth - 1)
            elif ch == '{':
                if depth > 0 or brace_in_signature > 0:
                    brace_in_signature += 1
                else:
                    return index, col
            elif ch == '}':
                if brace_in_signature > 0:
                    brace_in_signature -= 1
        # A protocol requirement / stored property ends without ever opening a
        # body. `;` or a blank line after a complete signature means give up.
        if depth == 0 and brace_in_signature == 0 and offset > 0:
            stripped = line.strip()
            if stripped.endswith(';') or (not stripped and offset > 2):
                return None
    return None


def measure_body(lines, brace_line, brace_col):
    """(body_line_count, max_nesting_depth) for the body opening at that brace.

    Nesting is measured RELATIVE to the body brace, so a func body's own brace
    is depth 0 and the spec's "depth <= 2" means at most two levels inside it.
    """
    depth = 0
    local_max = 0
    for index in range(brace_line, len(lines)):
        line = strip(lines[index])
        start = brace_col if index == brace_line else 0
        for ch in line[start:]:
            if ch == '{':
                depth += 1
                local_max = max(local_max, depth - 1)
            elif ch == '}':
                depth -= 1
                if depth == 0:
                    return index - brace_line - 1, local_max
    return None

long_funcs = deep_funcs = commented = empty_catches = malformed_swallow = 0
long_props = deep_props = 0
justified_long = justified_deep = 0
malformed = []
worst_long, worst_deep = [], []

for f in sorted(pathlib.Path(sys.argv[1]).rglob('*.swift')):
    text = f.read_text(encoding='utf-8', errors='ignore')
    lines = text.splitlines()
    commented += commented_out_code_lines(lines)
    file_swallowed, file_malformed_swallow = swallowed_catches(text)
    empty_catches += file_swallowed
    malformed_swallow += file_malformed_swallow

    i = 0
    while i < len(lines):
        m = FUNC.match(lines[i])
        kind = 'func'
        if not m:
            m = PROP.match(lines[i]) or INIT.match(lines[i]) or CLOSURE_PROP.match(lines[i])
            kind = 'prop'
        if not m:
            i += 1
            continue
        # Body length is measured from the OPENING BRACE, not the `func`
        # keyword. Swift signatures routinely span five or six lines when each
        # parameter gets its own; counting those as body inflates the number and
        # reports a 16-line function as 24.
        located = find_body_brace(lines, i)
        if located is None:
            i += 1
            continue
        brace_line, brace_col = located
        measured = measure_body(lines, brace_line, brace_col)
        if measured is None:
            i += 1
            continue
        body, local_max = measured
        j = brace_line + body + 1
        rel = str(f).replace('Emuqu/Sources/', '')
        name = m.group('name')
        if malformed_waiver_above(lines, i):
            malformed.append(f"{rel}:{i + 1} {name}")
        if body > MAX_BODY:
            if waiver_above(lines, i, SPEC_LONG_OK):
                justified_long += 1
            elif kind == 'func':
                long_funcs += 1
                worst_long.append((body, rel, i + 1, name))
            else:
                long_props += 1
                worst_long.append((body, rel, i + 1, name))
        if local_max > MAX_DEPTH:
            if waiver_above(lines, i, SPEC_NEST_OK):
                justified_deep += 1
            elif kind == 'func':
                deep_funcs += 1
                worst_deep.append((local_max, rel, i + 1, name))
            else:
                deep_props += 1
                worst_deep.append((local_max, rel, i + 1, name))
        i = max(j, i + 1)

worst_long.sort(reverse=True)
worst_deep.sort(reverse=True)
print(f"{long_funcs} {deep_funcs} {commented} {empty_catches} {justified_long} "
      f"{justified_deep} {len(malformed) + malformed_swallow} {long_props} {deep_props}")
for entry in malformed[:5]:
    print(f"BADWAIVER {entry}")
for n, rel, ln, name in worst_long[:5]:
    print(f"LONG {n} {rel}:{ln} {name}")
for n, rel, ln, name in worst_deep[:5]:
    print(f"DEEP {n} {rel}:{ln} {name}")
PY
}

MEASURED="$(measure_spec "$SCAN_DIR")"

if [[ -z "$MEASURED" ]]; then
    echo "check_refactor_spec_conformance: measurement produced no output." >&2
    exit 2
fi

read -r LONG NEST COMMENTED EMPTY_CATCHES JUST_LONG JUST_NEST BAD_WAIVERS LONG_PROPS NEST_PROPS <<<"$(printf '%s\n' "$MEASURED" | head -n1)"

JUST_LONG_BUDGET="$(read_budget spec_justified_long_budget.txt)"
JUST_NEST_BUDGET="$(read_budget spec_justified_nesting_budget.txt)"
LONG_PROPS_BUDGET="$(read_budget spec_long_properties_budget.txt)"
NEST_PROPS_BUDGET="$(read_budget spec_deep_nesting_properties_budget.txt)"

echo "Refactor-spec conformance (docs/REFACTOR_SPEC.md):"
printf -- "- Functions > %s lines: %s (budget: %s; ratchet toward 0)\n" 20 "$LONG" "$LONG_BUDGET"
printf -- "- Nesting depth > %s: %s (budget: %s; ratchet toward 0)\n" 2 "$NEST" "$NEST_BUDGET"
printf -- "- Computed properties / inits > %s lines: %s (budget: %s; ratchet toward 0)\n" 20 "$LONG_PROPS" "$LONG_PROPS_BUDGET"
printf -- "- Computed properties / inits nested > %s: %s (budget: %s; ratchet toward 0)\n" 2 "$NEST_PROPS" "$NEST_PROPS_BUDGET"
printf -- "- Commented-out code lines: %s (budget: %s; ratchet toward 0)\n" "$COMMENTED" "$COMMENT_BUDGET"
printf -- "- Empty catch blocks (comments only, no swallow-ok): %s (budget: 0)\n" "$EMPTY_CATCHES"
printf -- "- Justified long declarations: %s (budget: %s)\n" "$JUST_LONG" "$JUST_LONG_BUDGET"
printf -- "- Justified deep nesting: %s (budget: %s)\n" "$JUST_NEST" "$JUST_NEST_BUDGET"
printf -- "- Malformed waivers (marker with no reason): %s (budget: 0)\n" "$BAD_WAIVERS"

FAILED=0
over() {
    local label="$1" actual="$2" budget="$3"
    if (( actual > budget )); then
        echo "check_refactor_spec_conformance: $label is $actual, over budget $budget." >&2
        FAILED=1
    fi
}
over "functions > 20 lines" "$LONG" "$LONG_BUDGET"
over "functions nested > 2 deep" "$NEST" "$NEST_BUDGET"
over "computed properties / inits > 20 lines" "$LONG_PROPS" "$LONG_PROPS_BUDGET"
over "computed properties / inits nested > 2 deep" "$NEST_PROPS" "$NEST_PROPS_BUDGET"
over "commented-out code lines" "$COMMENTED" "$COMMENT_BUDGET"
over "empty catch blocks" "$EMPTY_CATCHES" 0
over "justified long functions" "$JUST_LONG" "$JUST_LONG_BUDGET"
over "justified deep nesting" "$JUST_NEST" "$JUST_NEST_BUDGET"
over "malformed waivers" "$BAD_WAIVERS" 0

if (( FAILED )); then
    echo >&2
    echo "Worst offenders:" >&2
    printf '%s\n' "$MEASURED" | grep -E '^(LONG|DEEP) ' | sed 's/^/  /' >&2
    echo >&2
    echo "Either extract, or lower nothing and explain why in the code." >&2
    exit 1
fi

# Report a ratchet opportunity rather than silently accepting slack.
for pair in "$LONG:$LONG_BUDGET:spec_long_functions_budget.txt" \
            "$NEST:$NEST_BUDGET:spec_deep_nesting_budget.txt" \
            "$LONG_PROPS:$LONG_PROPS_BUDGET:spec_long_properties_budget.txt" \
            "$NEST_PROPS:$NEST_PROPS_BUDGET:spec_deep_nesting_properties_budget.txt" \
            "$COMMENTED:$COMMENT_BUDGET:spec_commented_code_budget.txt" \
            "$JUST_LONG:$JUST_LONG_BUDGET:spec_justified_long_budget.txt" \
            "$JUST_NEST:$JUST_NEST_BUDGET:spec_justified_nesting_budget.txt"; do
    IFS=: read -r actual budget file <<<"$pair"
    if (( actual < budget )); then
        echo "check_refactor_spec_conformance: below budget — lower .ci/$file to $actual to lock the gain in."
    fi
done

# ---------------------------------------------------------------------------
# Watch target — one combined budget. See the note by WATCH_SCAN_DIR.
# ---------------------------------------------------------------------------
if [[ -d "$WATCH_SCAN_DIR" ]]; then
    if [[ ! -f "$WATCH_BUDGET_FILE" ]]; then
        echo "check_refactor_spec_conformance: missing budget file: $WATCH_BUDGET_FILE" >&2
        exit 2
    fi
    watch_budget="$(tr -d '[:space:]' < "$WATCH_BUDGET_FILE")"
    if [[ ! "$watch_budget" =~ ^[0-9]+$ ]]; then
        echo "check_refactor_spec_conformance: watch budget is not an integer" >&2
        exit 2
    fi
    WATCH_MEASURED="$(measure_spec "$WATCH_SCAN_DIR")"
    read -r W_LONG W_NEST _ _ _ _ _ W_LONG_P W_NEST_P \
        <<<"$(printf '%s\n' "$WATCH_MEASURED" | head -n1)"
    watch_total=$(( W_LONG + W_NEST + W_LONG_P + W_NEST_P ))
    echo "- ${WATCH_SCAN_DIR}: ${watch_total} declarations over the spec limits (budget: ${watch_budget}; ratchet toward 0)"
    echo "    long functions ${W_LONG}, deep nesting ${W_NEST}, long properties ${W_LONG_P}, deep properties ${W_NEST_P}"
    if (( watch_total > watch_budget )); then
        echo >&2
        echo "ERROR: watch-target spec violations ${watch_total} exceed budget ${watch_budget}." >&2
        exit 1
    fi
    if (( watch_total < watch_budget )); then
        echo "    below budget — lower ${WATCH_BUDGET_FILE} to ${watch_total} to lock the gain in"
    fi
fi

echo "check_refactor_spec_conformance: clean."
exit 0
