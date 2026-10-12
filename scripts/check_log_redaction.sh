#!/usr/bin/env bash
#
# CI guard: no personal health data in log statements.
#
# Why this exists: docs/REFACTOR_SPEC.md requires
# "never log sensitive user data — redact/sanitize before logging", and a
# principle in the spec needs automated enforcement behind it. Every other
# perimeter in this repo has a gate: the FDA copy perimeter has
# Tools/copy_linter/lint.py, permission strings have check_infoplist_key_drift.sh,
# concurrency escapes have check_unchecked_sendable.sh. This is that gate, in
# the same shape.
#
# What it looks for: interpolation of identifiable-person or raw-health values
# directly into a log call. The app logs a LOT (deliberately — see
# DebugLog.swift), and aggregate/derived numbers are fine to log. What is not
# fine is a name, an email, a coordinate pair, or a raw RR/beat series.
#
# This is deliberately conservative: it flags a small, high-signal set of
# patterns rather than trying to classify every interpolation. False positives
# are resolved by adding an inline `// log-redaction-ok: <reason>` on the line.
#
# Exit 0 clean, 1 on violation.

set -uo pipefail
cd "$(dirname "$0")/.."

source "$(dirname "$0")/lib/preflight.sh"

# The watch target is scanned too. It makes no logging calls today, so the
# hole is empty, but it talks to the phone over WatchConnectivity and a PII
# leak into a `print()` there would otherwise be invisible to the one gate
# written to prevent exactly that.
SOURCE_ROOTS=("${@:-Emuqu/Sources}")
if (( $# == 0 )); then
    SOURCE_ROOTS=("Emuqu/Sources" "EmuquWatch Watch App")
fi
SOURCE_ROOT="${SOURCE_ROOTS[0]}"

# Patterns that must never appear interpolated into a log line.
# Kept as extended-regex alternatives, matched only inside a log call.
# NOTE: `displayName` is deliberately NOT in this list. In this codebase it
# overwhelmingly names hardware and sports ("Polar H10", "Trail Run"), not
# people — including it produced only false positives. Person-names are
# reached through the contact-specific properties below.
PII_PATTERN='\\\(([^)]*\.)?(email|emailAddress|recipientEmail|fullName|firstName|lastName|contactName|recipientName|apiKey|token|bearer|password|secret)[^)]*\)'
GEO_PATTERN='\\\([^)]*\.(latitude|longitude)[^)]*\)'
# A bare `\(rr)` and a member path `\(self.rrIntervals)` / `\(session.rr)` alike.
# `samples` only bare: as a member it is a sample COUNT in this codebase
# (`\(pass.samples)`), not a series.
RAW_SERIES_PATTERN='\\\((([^)]*\.)?(rr|rrValues|rrSeries|beats|rrIntervals)|samples)\)'

# `NSLog` and `(Swift.)print` are log calls too. The app target has dozens of
# NSLog call sites, all lifecycle text today, and a list without them leaves
# every one outside this gate's field of view.
LOG_CALL='(debugLog|debugLogExternal|RuntimeLogger[.]shared[.]log|logger[.](debug|info|notice|warning|error|fault)|os_log|os_signpost|NSLog|(Swift[.])?print)[(]'

# A missing root would make the scan read nothing and report clean.
for root in "${SOURCE_ROOTS[@]}"; do
    if [[ ! -d "$root" ]]; then
        echo "check_log_redaction: source root not found: $root" >&2
        exit 2
    fi
done

tmp="$(gate_mktemp log-redaction)" || exit $?
trap 'rm -f "$tmp"' EXIT

# Collect log call sites, one per line as `file:line:<the whole call>`. A call
# split across lines is joined first, so an interpolation on a continuation
# line is seen. `// log-redaction-ok: <reason>` waives a call when it sits on
# any line of the call or on the line immediately above it (the `disable:next`
# shape, so the escape hatch does not push a long call over line_length).
python3 - "$LOG_CALL" "${SOURCE_ROOTS[@]}" > "$tmp" <<'PY' || { echo "check_log_redaction: the scan failed; nothing was measured." >&2; exit 2; }
import pathlib
import re
import sys

LOG_CALL = re.compile(r"(?<!\w)" + sys.argv[1])


def call_end(text, i):
    """Index just past the parenthesis closing the one at `i`.

    String literals are skipped, except for the code inside an interpolation,
    so a paren in copy or in an interpolated expression cannot end the call.
    """
    depth, j, n, in_string, interpolations = 0, i, len(text), False, []
    while j < n:
        c = text[j]
        if in_string:
            if c == "\\" and text.startswith("(", j + 1):
                interpolations.append(depth)
                depth += 1
                in_string = False
                j += 2
                continue
            if c == "\\":
                j += 2
                continue
            if c == '"':
                in_string = False
            j += 1
            continue
        if text.startswith("//", j):
            newline = text.find("\n", j)
            j = n if newline < 0 else newline
            continue
        if c == '"':
            in_string = True
        elif c == "(":
            depth += 1
        elif c == ")":
            depth -= 1
            if interpolations and depth == interpolations[-1]:
                interpolations.pop()
                in_string = True
            elif depth == 0:
                return j + 1
        j += 1
    return n


for root in sys.argv[2:]:
    for path in sorted(pathlib.Path(root).rglob("*.swift")):
        text = path.read_text(encoding="utf-8", errors="replace")
        lines = text.split("\n")
        for m in LOG_CALL.finditer(text):
            first = text.count("\n", 0, m.start())
            if lines[first].lstrip().startswith("//"):
                continue
            call = text[m.start():call_end(text, m.end() - 1)]
            last = first + call.count("\n")
            above = lines[first - 1] if first > 0 else ""
            if "log-redaction-ok" in above or any(
                    "log-redaction-ok" in lines[k] for k in range(first, last + 1)):
                continue
            print(f"{path}:{first + 1}:" + " ".join(l.strip() for l in call.split("\n")))
PY

violations=0
report() {
    local label="$1" pattern="$2"
    local hits
    hits="$(grep -E "$pattern" "$tmp" || true)"
    if [[ -n "$hits" ]]; then
        echo "FAIL: $label interpolated into a log statement:"
        printf '%s\n' "$hits" | sed 's/^/    /'
        echo
        violations=1
    fi
}

report "personal identifiers / credentials" "$PII_PATTERN"
report "precise coordinates" "$GEO_PATTERN"
report "raw beat/RR series" "$RAW_SERIES_PATTERN"

if (( violations )); then
    cat <<'EOF'
Fix one of these ways:
  (a) Log a derived/aggregate value instead (count, mean, bucket, hash prefix).
  (b) Redact at the call site before interpolating.
  (c) If the value is genuinely non-identifying in this context, append
      `// log-redaction-ok: <one-line reason>` to the line.

Rationale: docs/REFACTOR_SPEC.md — "Never log sensitive user data.
Redact/sanitize before logging."
EOF
    exit 1
fi

scanned="$(wc -l < "$tmp" | tr -d ' ')"
echo "check_log_redaction: clean. Scanned ${scanned} log call sites under ${SOURCE_ROOTS[*]}."
