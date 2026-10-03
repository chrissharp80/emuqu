#!/usr/bin/env bash
#
# CI guard: the catalogue -> code direction. A key nothing requests is a
# translation paid for in sixteen locales and shown to nobody.
#
# Why this exists. Three gates measure localization, and all three can report
# perfect scores at once:
#
#   * check_localization_coverage.sh   catalogue -> locale   100.00% x 16
#   * check_localization_bundle.sh     lookup -> bundle      all qualified
#   * check_localization_resolution.sh code -> catalogue     every literal resolves
#
# None of them measures catalogue -> code. That is the direction an orphan runs
# in: edit a localized literal and the OLD key stays behind, fully translated,
# requested by nothing. `check_localization_resolution.sh`'s own header
# describes exactly this — "translate the new key and delete the orphan it
# replaced" — and nothing else checks whether anyone deletes it.
#
# This is the inverse of that script and deliberately shares its extractor and
# its normalisation, including the permissive specifier match. A hand-rolled
# extractor that only normalises `%@` reports hundreds of orphans, most of them
# `%lld` / `%d` forms that DO resolve. Getting this wrong in the loud direction
# is how a gate stops being believed, so it reuses the machinery that is
# already trusted.
#
# Keys marked `"shouldTranslate": false` are format/punctuation shells and are
# excluded, same as the coverage gate.
#
# Budget in `.ci/localization_orphan_budget.txt`, ratcheting DOWN.
#
# The extractor must look past a literal sitting immediately after the call
# paren. One that stops there cannot see `Text(cond ? a : b)` or a Swift Charts
# `.value(label, x)`, so dozens of live, shipping strings count as orphans —
# both halves of the sleep-editor delta badge, the sleep-target picker option,
# every chart axis label (AT1, RR_n+1, alpha1, Upper, Mean). A gate whose
# failures are one third false positives is a gate people learn to wave
# through. See `first_argument_literals` and `skip_literal_at`.
#
# Exit 0 clean, 1 over budget, 2 on config error.

set -uo pipefail
cd "$(dirname "$0")/.."

SCAN_DIR="${1:-Emuqu/Sources}"
CATALOGUE="${2:-Emuqu/Localizable.xcstrings}"
BUDGET_FILE="${LOCALIZATION_ORPHAN_BUDGET_FILE:-.ci/localization_orphan_budget.txt}"

for required in "$CATALOGUE" "$BUDGET_FILE"; do
    if [[ ! -f "$required" ]]; then
        echo "check_localization_orphans: missing $required" >&2
        exit 2
    fi
done
budget="$(tr -d '[:space:]' < "$BUDGET_FILE")"
if [[ ! "$budget" =~ ^[0-9]+$ ]]; then
    echo "check_localization_orphans: budget file is not an integer: $BUDGET_FILE" >&2
    exit 2
fi

count="$(python3 - "$SCAN_DIR" "$CATALOGUE" <<'PY'
import json
import pathlib
import re
import sys

scan_dir, catalogue_path = sys.argv[1], sys.argv[2]
catalogue = json.loads(pathlib.Path(catalogue_path).read_text(encoding="utf-8"))
strings = catalogue.get("strings", {})

INTERP = "\x00INTERP\x00"


def scan_multiline_literal(text, i):
    """text[i:i+3] is an opening triple quote. Swift's rules: the body starts
    after the newline that follows the delimiter, the closing delimiter's
    indentation is removed from every line, and a backslash at a line's end
    joins it to the next. Read as one-line literals, these all came out as ""
    and their keys were counted as orphans."""
    end = text.find('"""', i + 3)
    if end < 0:
        return "", len(text)
    raw = text[i + 3:end]
    raw = raw[raw.find("\n") + 1:] if "\n" in raw else raw
    lines = raw.split("\n")
    indent = lines[-1] if lines[-1].strip() == "" else ""
    lines = lines[:-1] if lines[-1].strip() == "" else lines
    body = "\n".join(l[len(indent):] if l.startswith(indent) else l for l in lines)
    body = re.sub(r"\\\n", "", body)
    inner, _ = scan_literal('"' + body.replace('"', '\\"') + '"', 0)
    return inner, end + 3


def scan_literal(text, i):
    if text.startswith('"""', i):
        return scan_multiline_literal(text, i)
    i += 1
    out = []
    while i < len(text):
        ch = text[i]
        if ch == "\\":
            if i + 1 < len(text) and text[i + 1] == "(":
                j, depth = i + 2, 1
                while j < len(text) and depth:
                    if text[j] == '"':
                        _, j = scan_literal(text, j)
                        continue
                    if text[j] == "(":
                        depth += 1
                    elif text[j] == ")":
                        depth -= 1
                    j += 1
                out.append(INTERP)
                i = j
                continue
            out.append(text[i:i + 2])
            i += 2
            continue
        if ch == '"':
            return "".join(out), i + 1
        out.append(ch)
        i += 1
    return "".join(out), i


UNICODE_ESCAPE = re.compile(r"\\u\{([0-9A-Fa-f]+)\}")


def unescape(s):
    s = UNICODE_ESCAPE.sub(lambda m: chr(int(m.group(1), 16)), s)
    return (s.replace('\\"', '"').replace("\\n", "\n").replace("\\t", "\t")
             .replace("\\'", "'").replace("\\\\", "\\"))


def candidate_keys(raw):
    body = unescape(raw)
    return {body.replace("%", "%%").replace(INTERP, "%@"), body.replace(INTERP, "%@")}


QUOTE = chr(34)


def skip_literal_at(text, start):
    """Whether the literal beginning at `start` is NOT a LocalizedStringKey.

    Two shapes, both genuinely untranslatable rather than merely untranslated:

      * A subscript key. In Text(payload[k] as? String ?? fallback) the k is a
        dictionary lookup, not copy.
      * The right-hand side of a nil-coalescing operator. Text(optional ?? lit)
        resolves to the Text(String) overload, which does NOT localize, so the
        literal has no catalogue key by construction and never gets one.

    Both are recognised by what precedes the opening quote, because neither
    this script nor any regex can do Swift type inference.
    """
    j = start - 1
    while j >= 0 and text[j] in " \t\n":
        j -= 1
    if j < 0:
        return False
    if text[j] == "[":
        return True
    return j >= 1 and text[j] == "?" and text[j - 1] == "?"


def first_argument_literals(text, i):
    """String literals in the FIRST argument of a call, paren already consumed.

    An extractor that only looks at a literal sitting IMMEDIATELY after the
    paren gets nothing at all from a call whose first argument is an
    EXPRESSION, and live, shipping keys are then counted as orphans: the
    sleep-target picker option in SettingsView+Pages, written as
    Text(min < 60 ? a : b), and both halves of the sleep-editor delta badge in
    SleepTimelineEditorView.

    Two deliberate limits, because widening this the wrong way marks keys as
    requested that nothing actually localizes, which HIDES real orphans:

      * First argument only — stop at the first top-level comma. That is where
        the LocalizedStringKey goes. Label(title, systemImage: symbol) must
        contribute the title and never the SF Symbol name.
      * Depth 1 only. A literal nested inside another call within that
        argument belongs to that call, not to this one.
    """
    depth, out = 1, []
    while i < len(text) and depth:
        ch = text[i]
        if ch == QUOTE:
            start = i
            body, i = scan_literal(text, i)
            if depth == 1 and not skip_literal_at(text, start):
                out.append(body)
            continue
        if ch == "," and depth == 1:
            break
        if ch == "(":
            depth += 1
        elif ch == ")":
            depth -= 1
        i += 1
    return out


SWIFTUI_IMPLICIT = ("Text", "Button", "Label", "Toggle", "TextField", "Picker", "Section")
SWIFTUI_MODIFIERS = ("navigationTitle", "navigationBarTitle", "alert",
                     "confirmationDialog", "accessibilityLabel", "accessibilityHint",
                     "value")
CALL = re.compile(
    r"String\(\s*localized:\s*"
    r"|AttributedString\(\s*localized:\s*"
    r"|LocalizedStringKey\(\s*"
    r"|NSLocalizedString\(\s*"
    r"|\b(?:" + "|".join(SWIFTUI_IMPLICIT) + r")\(\s*"
    r"|\.(?:" + "|".join(SWIFTUI_MODIFIERS) + r")\(\s*"
)

requested = set()
patterns = []
SPECIFIER = r"%(?:\d+\$)?(?:@|lld|ld|d|u|\.\d+f|f|s)"
roots = [pathlib.Path(scan_dir), pathlib.Path("EmuquWatch Watch App"), pathlib.Path("Emuqu/EmuquApp.swift")]
for root in roots:
    files = [root] if root.is_file() else (sorted(root.rglob("*.swift")) if root.is_dir() else [])
    for path in files:
        text = path.read_text(encoding="utf-8", errors="ignore")
        for match in CALL.finditer(text):
            i = match.end()
            # Text(verbatim:) is the explicit opt OUT of localization. It has
            # no catalogue key, so counting its literal as a request would mask
            # a real orphan.
            if text.startswith("verbatim:", i):
                continue
            if i < len(text) and text[i] == QUOTE:
                bodies = [scan_literal(text, i)[0]]
            else:
                bodies = first_argument_literals(text, i)
            for body in bodies:
                for candidate in candidate_keys(body):
                    requested.add(candidate)
                    if "%@" in candidate:
                        patterns.append(
                            re.compile("^" + re.escape(candidate).replace(re.escape("%@"), SPECIFIER) + "$", re.S)
                        )

orphans = []
for key, entry in strings.items():
    if entry.get("shouldTranslate") is False:
        continue
    if key in requested:
        continue
    if any(rx.match(key) for rx in patterns):
        continue
    orphans.append(key)

for key in sorted(orphans)[:15]:
    sys.stderr.write(f"    {key[:110]!r}\n")
print(len(orphans))
PY
)"

echo "Catalogue keys no code literal requests: ${count} (budget: ${budget}; ratchet toward 0)"

if (( count > budget )); then
    echo >&2
    echo "ERROR: orphaned catalogue keys exceeded budget (${count} > ${budget})." >&2
    echo "Each one is a phrase translated into 16 locales that no screen can show." >&2
    echo "Delete the key, or point a literal at it." >&2
    exit 1
fi

if (( count < budget )); then
    echo "check_localization_orphans: below budget — lower ${BUDGET_FILE} to ${count} to lock the gain in."
fi
echo "check_localization_orphans: clean."
