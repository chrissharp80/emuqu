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
# fine is a name, an email, a coordinate pair, a raw RR/beat series, what the
# user said or typed, or the name of the street or city they are on.
#
# This is deliberately conservative: it flags a small, high-signal set of
# patterns rather than trying to classify every interpolation. False positives
# are resolved by adding an inline `// log-redaction-ok: <reason>` on the line.
#
# Exit 0 clean, 1 on violation.

set -uo pipefail
cd "$(dirname "$0")/.."

source "$(dirname "$0")/lib/preflight.sh"

# The watch target is scanned too. It logs through `os.Logger` instances named
# `log` (`log.info(…)`, `self?.log.info(…)`) and through a `Logger(…)` built in
# place and called on the next line, and it talks to the phone over
# WatchConnectivity, so a PII leak there would otherwise be invisible to the one
# gate written to prevent exactly that.
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
PII_PATTERN='\\\((String\(describing: *)?([^)]*\.)?(email|emailAddress|recipientEmail|fullName|firstName|lastName|contactName|recipientName|apiKey|token|bearer|password|secret)[^)]*\)'
GEO_PATTERN='\\\((String\(describing: *)?([^)]*\.)?(latitude|longitude|lat|lon|lng)\b[^)]*\)'
# What the user said or typed (an assistant or web-search query, a voice
# transcript, a prompt) and where they are (a street or city name), bare or
# truncated with `.prefix(n)`, with or without a `?? "…"` fallback. A count or
# a nil test (`\(query.count)`, `\(road == nil ? …)`) is not matched.
# Text-preserving transforms: the value is still what the user typed after
# any of these (`\(query.lowercased())`, `\(road.prefix(40))`).
TEXT_TRANSFORMS='(\.(prefix\([0-9]+\)|suffix\([0-9]+\)|lowercased\(\)|uppercased\(\)|capitalized|localizedLowercase|localizedCapitalized|trimmingCharacters\([^)]*\)|description|debugDescription))*'
USER_TEXT_NAMES='query|q|transcript|utterance|userText|userMessage|prompt|question|thoroughfare|subThoroughfare|locality|subLocality|road|street|crossStreet'
USER_TEXT_PATTERN='\\\((String\(describing: *)?([^)]*\.)?('"$USER_TEXT_NAMES"')'"$TEXT_TRANSFORMS"'( \?\? "[^"]*")?\)'
# Where the user is under any variable name that says so: a camelCase name
# ending in Road, Street, Thoroughfare or Locality (`currentRoad`,
# `nearestStreet`), and the road-graph grid keys (`cellKey`, `gridKey`,
# `tileKey`), which are a ~250 m square of the user's position. A value
# copied into a name that says neither (`let key = currentRoad`) is out of
# any pattern's reach, so the copy site is where to keep it out of a log.
LOCATION_NAME_PATTERN='\\\((String\(describing: *)?([^)]*\.)?([a-z][A-Za-z]*(Road|Street|Thoroughfare|Locality|CellKey|GridKey|TileKey)|cellKey|gridKey|tileKey)'"$TEXT_TRANSFORMS"'( \?\? "[^"]*")?\)'
# A location value whole: a `CLLocation` or coordinate prints its latitude
# and longitude (`\(location)`, `\(loc)`, `\(location.coordinate)`,
# `\(lastLocation)`), and a placemark prints its street and city.
# A member of one that is not a position (`\(location.horizontalAccuracy)`)
# is not matched.
LOCATION_VALUE_NAMES='location|loc|coordinate|coordinates|placemark|[a-z][A-Za-z]*Location|[a-z][A-Za-z]*Coordinate|[a-z][A-Za-z]*Placemark'
LOCATION_VALUE_PATTERN='\\\((String\(describing: *)?([^)]*\.)?('"$LOCATION_VALUE_NAMES"')(\.coordinate)?(\.description)?\)'
# The name of a saved route (free text the user typed) or of a place. A bare
# `name` is not matched: in this codebase it mostly names a device or sport.
PLACE_NAME_PATTERN='\\\((String\(describing: *)?([^)]*\.)?(savedRoute|route|osmHit|placemark|mapItem)\.name\)'
# Other free text the user typed or named, under the names it is stored by:
# a saved route's name copied out (`routeName`, `estimate.routeName`,
# `extrapolationRouteName`), a contact's or a plan's name, a memory fact's
# text, session notes and tags, and the name of a file they chose
# (`originalFileName`). Bare or text-preserved; a count is not matched.
USER_FIELD_NAMES='routeName|[a-z][A-Za-z]*RouteName|(contact|recipient|plan|fact|memory)\.(name|text)|factText|notes?|[a-z][A-Za-z]*Notes?|tags|[a-z][A-Za-z]*Tags|fileName|[a-z][A-Za-z]*FileName'
USER_FIELD_PATTERN='\\\((String\(describing: *)?([^)]*\.)?('"$USER_FIELD_NAMES"')'"$TEXT_TRANSFORMS"'( \?\? "[^"]*")?\)'
# A bare `\(rr)` and a member path `\(self.rrIntervals)` / `\(session.rr)` alike.
# `samples` only bare: as a member it is a sample COUNT in this codebase
# (`\(pass.samples)`), not a series.
# A series reshaped on the way in (`\(rr.map(String.init).joined())`,
# `\(rrIntervals.prefix(20))`) is still the series.
RAW_SERIES_NAMES='rr|rrValues|rrSeries|beats|rrIntervals'
RAW_SERIES_PATTERN='\\\((String\(describing: *)?(([^)]*\.)?('"$RAW_SERIES_NAMES"')(\.(map|compactMap|flatMap|lazy|prefix|suffix|dropFirst|dropLast|sorted|reversed|joined|description|debugDescription)\b|\))|samples\))'
# The same values joined to a string literal with `+` rather than
# interpolated (`debugLog("asked: " + query)`, `query + " asked"`). The
# literal anchors the match, so a word in copy beside an interpolation
# (`"beats + \(count)"`) is not read as an operand.
CONCAT_NAMES='email|emailAddress|fullName|firstName|lastName|contactName|recipientName|apiKey|token|password|secret|'"$USER_TEXT_NAMES"'|'"$LOCATION_VALUE_NAMES"'|'"$RAW_SERIES_NAMES"
CONCAT_PATTERN='"[[:space:]]*\+[[:space:]]*([A-Za-z_][A-Za-z0-9_]*\.)*('"$CONCAT_NAMES"')'"$TEXT_TRANSFORMS"'[[:space:]]*([)+,]|$)|([^A-Za-z0-9_.]|^)([A-Za-z_][A-Za-z0-9_]*\.)*('"$CONCAT_NAMES"')'"$TEXT_TRANSFORMS"'[[:space:]]*\+[[:space:]]*"'

# `NSLog` and `(Swift.)print` are log calls too. The app target has dozens of
# NSLog call sites, all lifecycle text today, and a list without them leaves
# every one outside this gate's field of view. An `os.Logger` is matched under
# both names this repo gives one (`logger`, `log`) and when it is built in place
# (`Logger(…)` then `.debug(…)`, the chained call allowed on the next line).
LOGGER_LEVEL='(debug|info|notice|warning|error|fault|trace|critical|log)'
LOG_CALL="((?<![.\w])log[(](?=\")|(debugLog|debugLogExternal|(RuntimeLogger|DebugLogger)[.]shared[.]log|(log|[A-Za-z_]*[Ll]ogger|[A-Za-z_]+Log)[?]?[.]${LOGGER_LEVEL}|Logger[(][^)]*[)]\\s*[.]${LOGGER_LEVEL}|os_log|os_signpost|NSLog|(Swift[.])?print)[(])"

# A value wrapped in `String(describing:)` is the value, so every pattern
# below also matches it wrapped. The logger's own sink
# (`DebugLogger.shared.log`) and an optional logger (`logger?.info`) are log
# calls too.
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
#
# A message built before the call (`let msg = "at \(loc)"`, then
# `debugLog(msg)`) carries its value into the call under a name no pattern
# knows. So each identifier the call uses is followed to the nearest local
# `let`/`var` assignment of it above the call (and `+=` onto it), and what was
# assigned is appended to the call's line, two levels deep, where the same
# patterns read it. A waiver on the assignment's line waives that assignment.
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


def code_only(text):
    """`text` with string-literal characters blanked, interpolations kept."""
    out, j, n, in_string, interpolations, depth = [], 0, len(text), False, [], 0
    while j < n:
        c = text[j]
        if in_string:
            if c == "\\" and text.startswith("(", j + 1):
                interpolations.append(depth)
                depth += 1
                in_string = False
                out.append("  ")
                j += 2
                continue
            if c == '"':
                in_string = False
            out.append(" " if c != "\\" else " ")
            j += 1
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
        out.append(c)
        j += 1
    return "".join(out)


IDENTIFIER = re.compile(r"(?<![\w.])([a-z_][A-Za-z0-9_]*)\b(?!\s*[(:])")


def continued(text, j):
    """Whether the line ending at `j` ends in `+` or `=`, so the statement goes on."""
    k = j - 1
    while k >= 0 and text[k] in " \t\r":
        k -= 1
    return k >= 0 and text[k] in "+="


def statement_end(text, i):
    """Index of the newline ending the statement that starts at `i`."""
    depth, j, n = 0, i, len(text)
    while j < n:
        if text.startswith('"""', j):
            close = text.find('"""', j + 3)
            j = n if close < 0 else close + 3
            continue
        c = text[j]
        if c == '"':
            close = j + 1
            while close < n and text[close] not in '"\n':
                close += 2 if text[close] == "\\" else 1
            j = close + 1
            continue
        if c in "([{":
            depth += 1
        elif c in ")]}":
            depth -= 1
        elif c == "\n" and depth <= 0 and not continued(text, j):
            return j
        j += 1
    return n


def assignments(text, name, before, lines):
    """What was assigned to local `name` above offset `before`: the nearest
    `let`/`var` of it and every `+=` onto it after that, within 80 lines."""
    window_start = max(0, text.rfind("\n", 0, max(0, before - 1)) - 1)
    for _ in range(80):
        window_start = text.rfind("\n", 0, window_start)
        if window_start < 0:
            window_start = 0
            break
    region = text[window_start:before]
    decl = None
    for d in re.finditer(r"\b(?:let|var)\s+" + re.escape(name) + r"\b\s*(?::[^=\n]*)?=", region):
        decl = d
    if decl is None:
        return []
    found = []
    for a in [decl] + list(re.finditer(r"\b" + re.escape(name) + r"\s*\+=", region[decl.end():])):
        start = window_start + (a.end() if a is decl else decl.end() + a.end())
        line_no = text.count("\n", 0, start)
        if "log-redaction-ok" in lines[line_no]:
            continue
        found.append(text[start:statement_end(text, start)])
    return found


def followed(text, call, before, lines, depth=2, seen=None):
    """The values assigned to the locals `call` uses, appended for the scan."""
    seen = set() if seen is None else seen
    extra = []
    for name in sorted(set(IDENTIFIER.findall(code_only(call)))):
        if name in seen:
            continue
        seen.add(name)
        for value in assignments(text, name, before, lines):
            extra.append(f"via({name}: {' '.join(value.split())})")
            if depth > 1:
                extra += followed(text, value, before, lines, depth - 1, seen)
    return extra


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
            flat = " ".join(l.strip() for l in call.split("\n"))
            print(f"{path}:{first + 1}:" + " ".join([flat] + followed(text, call, m.start(), lines)))
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
report "user text / place names" "$USER_TEXT_PATTERN"
report "route / place names" "$PLACE_NAME_PATTERN"
report "user-named fields" "$USER_FIELD_PATTERN"
report "location by variable name" "$LOCATION_NAME_PATTERN"
report "location values" "$LOCATION_VALUE_PATTERN"
report "sensitive values concatenated" "$CONCAT_PATTERN"

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
