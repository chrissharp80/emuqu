#!/usr/bin/env bash
#
# CI guard: every `String(localized:)` literal in the code resolves to a key
# that actually exists in the string catalogue.
#
# Why this exists. The two other localization gates can both report perfect
# scores while a user-facing string ships in English to all sixteen locales:
#
#   * check_localization_coverage.sh measures catalogue -> locale. It asks
#     "does every key have a translation?" and answers 100.00% across 16
#     locales. It cannot see a key that nothing requests.
#   * check_localization_bundle.sh measures whether each lookup is
#     bundle-qualified. It asks "will this read from the right bundle?" and
#     answers "all bundle-qualified". A lookup can be perfectly
#     bundle-qualified and still name a key that does not exist.
#
# Neither measures the remaining direction: code -> catalogue. That is the
# direction this failure runs in.
#
# Edit the English literal in `DeepDiveReportRenderer+Pages.swift` after the
# catalogue is translated — to add "overtraining" and a monitor-for-symptoms
# instruction, say — and the lookup key changes with it: the catalogue entry
# (translated into all 16 locales, every one of them marked `translated`) is
# orphaned and every non-English user falls back to the raw English claim.
# Both gates above stay green through all of it.
#
# The whole class of bug is: edit a localized literal, forget to re-extract.
# It is silent, it is invisible in review, and it de-localises exactly the
# string someone cared enough to hand-edit.
#
# WHAT THIS DOES NOT DO. It does not re-implement Xcode's extractor. It
# normalises the two transforms that matter — interpolations become format
# specifiers, literal `%` doubles — and accepts either form where the
# developer authored a format template by hand. Unrecognised specifier
# spellings (`%lld`, `%1$@`, `%.1f`) are matched permissively rather than
# reported, because a false positive here costs more than a missed edge case:
# this gate has to stay believable to be worth having.
#
# Exit 0 clean, 1 on any unresolved literal, 2 on config error.

set -uo pipefail
cd "$(dirname "$0")/.."

# The Watch target was never scanned. It has 99 localized literals of its own,
# so "every literal resolves to a key" was a statement about the iPhone app
# only — and the catalogue was not even in the Watch target's Resources, which
# meant every one of them fell back to its English key in all sixteen locales
# while three localization gates reported perfect scores.
SCAN_DIRS=("Emuqu/Sources" "EmuquWatch Watch App")
CATALOGUE="Emuqu/Localizable.xcstrings"

for dir in "${SCAN_DIRS[@]}"; do
    [[ -d "$dir" ]] && continue
    echo "check_localization_resolution: scan directory missing: $dir" >&2
    exit 2
done
if [[ ! -f "$CATALOGUE" ]]; then
    echo "check_localization_resolution: catalogue missing: $CATALOGUE" >&2
    exit 2
fi

python3 - "$CATALOGUE" "${SCAN_DIRS[@]}" <<'PY'
import json
import pathlib
import re
import sys

catalogue_path, scan_dirs = sys.argv[1], sys.argv[2:]

try:
    catalogue = json.loads(pathlib.Path(catalogue_path).read_text(encoding="utf-8"))
except Exception as exc:
    sys.stderr.write(f"check_localization_resolution: cannot parse catalogue: {exc}\n")
    sys.exit(2)

keys = set(catalogue.get("strings", {}))
if not keys:
    sys.stderr.write("check_localization_resolution: catalogue has no strings.\n")
    sys.exit(2)

INTERP = "\x00INTERP\x00"


def scan_literal(text, i):
    """text[i] is the opening quote. Return (body, index_after_closing_quote).

    Swift string interpolation nests arbitrarily — `"a \\(f(x, "b")) c"` is one
    literal containing another. A flat regex stops at the inner quote and
    reports the truncated fragment as a missing key — a naive version of this
    check produces hundreds of false positives that way. Walking the literal
    with a paren counter is the only way to get this right.
    """
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
    return (s.replace('\\"', '"')
             .replace("\\n", "\n")
             .replace("\\t", "\t")
             .replace("\\'", "'")
             .replace("\\\\", "\\"))


def candidate_keys(raw):
    """Both plausible extractions of one literal.

    Xcode doubles a literal `%` when it writes the key, because the key doubles
    as a format string. But a developer who hand-authored `"%.1f min"` as a
    template meant that percent literally. Accept either rather than guess.
    """
    body = unescape(raw)
    return {
        body.replace("%", "%%").replace(INTERP, "%@"),
        body.replace(INTERP, "%@"),
    }


SPECIFIER = r"%(?:\d+\$)?(?:@|lld|ld|d|u|\.\d+f|f|s)"
# `String(localized:)` is not the only lookup. SwiftUI's `Text("...")` resolves
# the same way and fails the same way, and it is the form most easily retyped
# by hand during a refactor — which is how a P0 string drifts from its key.
# Every SwiftUI form that takes a `LocalizedStringKey` is a catalogue lookup —
# `Button("…")`, `Section("…")`, `.navigationTitle("…")`, `.alert("…")`,
# `.accessibilityLabel("…")`, `Toggle`, `TextField`, `Picker`, `Label` — not
# only `Text(` followed by `bundle:`. A `Text(` without `bundle:` is NOT a plain
# string: it resolves through `.environment(\.locale, …)` against `Bundle.main`
# rather than through an explicit bundle argument, and that is the call form
# the codebase most commonly writes UI copy in. A pattern that stops at `Text(`
# with `bundle:` leaves all of them outside the gate's field of view.
#
# This header claims no catch count on purpose. A gate header that overstates
# what it caught is the same defect the header above it describes, one level
# up — the prose and the code disagreeing, with only the prose being read. The
# script prints the number of call sites scanned on every run, and anyone can
# check that.
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


SWIFTUI_IMPLICIT = (
    "Text", "Button", "Label", "Toggle", "TextField", "Picker", "Section",
)
SWIFTUI_MODIFIERS = (
    "navigationTitle", "navigationBarTitle", "alert", "confirmationDialog",
    "accessibilityLabel", "accessibilityHint",
    "value",
)
CALL = re.compile(
    r"String\(\s*localized:\s*"
    r"|AttributedString\(\s*localized:\s*"
    r"|LocalizedStringKey\(\s*"
    r"|\b(?:" + "|".join(SWIFTUI_IMPLICIT) + r")\(\s*"
    r"|\.(?:" + "|".join(SWIFTUI_MODIFIERS) + r")\(\s*"
)

literals = []
for path in sorted(p for d in scan_dirs for p in pathlib.Path(d).rglob("*.swift")):
    text = path.read_text(encoding="utf-8", errors="ignore")
    for match in CALL.finditer(text):
        i = match.end()
        # Text(verbatim:) is the explicit opt OUT of localization; it has no
        # catalogue key and must not be asked to resolve to one.
        if text.startswith("verbatim:", i):
            continue
        if i < len(text) and text[i] == QUOTE:
            bodies = [scan_literal(text, i)[0]]
        else:
            bodies = first_argument_literals(text, i)
        for body in bodies:
            # A literal with no letters in it is punctuation or a format shell
            # ("%@ · %@", "—"), never a translatable phrase.
            if not re.search(r"[A-Za-z]{2,}", re.sub(r"\x00INTERP\x00", "", body)):
                continue
            literals.append((str(path), text.count("\n", 0, i) + 1, body))

unresolved = []
for path, line, raw in literals:
    candidates = candidate_keys(raw)
    if candidates & keys:
        continue
    matched = False
    for candidate in candidates:
        pattern = re.escape(candidate).replace(re.escape("%@"), SPECIFIER)
        rx = re.compile("^" + pattern + "$", re.S)
        if any(rx.match(k) for k in keys):
            matched = True
            break
    if not matched:
        unresolved.append((path, line, sorted(candidates, key=len)[-1]))

print(f"check_localization_resolution: {len(literals)} localized literals, "
      f"{len(keys)} catalogue keys.")

if not unresolved:
    print("check_localization_resolution: clean. Every literal resolves to a key.")
    sys.exit(0)

print(f"check_localization_resolution: {len(unresolved)} literal(s) resolve to NO "
      f"catalogue key.", file=sys.stderr)
print("These render in English in all locales, whatever the coverage gate says.\n",
      file=sys.stderr)
for path, line, key in unresolved:
    print(f"  {path}:{line}", file=sys.stderr)
    print(f"    key: {key[:200]!r}\n", file=sys.stderr)
print("Fix: re-run string extraction so the catalogue picks up the edited literal,\n"
      "then translate the new key and delete the orphan it replaced.", file=sys.stderr)
sys.exit(1)
PY
