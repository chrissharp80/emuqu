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
RAW_SERIES_PATTERN='\\\((rr|rrValues|rrSeries|beats|rrIntervals|samples)\)'

# Bracket classes rather than backslash escapes: this string is handed to awk
# via -v, which processes escape sequences in the assigned value, so a `\(`
# would arrive as a bare `(` and silently turn into a regex group.
# `NSLog` and `(Swift.)print` are log calls too. The app target has dozens of
# NSLog call sites, all lifecycle text today, and a list without them leaves
# every one outside this gate's field of view.
LOG_CALL='(debugLog|debugLogExternal|RuntimeLogger[.]shared[.]log|logger[.](debug|info|notice|warning|error|fault)|os_log|os_signpost|NSLog|(Swift[.])?print)[(]'

tmp="$(gate_mktemp log-redaction)" || exit $?
trap 'rm -f "$tmp"' EXIT

# Collect log call sites, honouring `// log-redaction-ok: <reason>` either on
# the same line or on the line immediately above (the `disable:next` shape,
# so the escape hatch doesn't push an already-long call site over line_length).
find "${SOURCE_ROOTS[@]}" -name '*.swift' -type f -print0 \
    | xargs -0 awk -v pat="$LOG_CALL" '
        FNR == 1 { prev = "" }
        {
            if ($0 ~ pat && $0 !~ /log-redaction-ok/ && prev !~ /log-redaction-ok/) {
                print FILENAME ":" FNR ":" $0
            }
            prev = $0
        }
    ' 2>/dev/null > "$tmp" || true

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
