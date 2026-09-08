#!/usr/bin/env bash
set -euo pipefail

# Every `String(localized:)` / `NSLocalizedString` lookup must name the language
# bundle.
#
# The title is scoped to those two calls on purpose — not "every
# localized-string lookup", which is broader than what this checks and broader
# than what is true. SwiftUI implicit lookups — `Text("Save")`, `Button("Save")`,
# `.navigationTitle("Save")` — take a `LocalizedStringKey` and have no bundle
# parameter to name; they resolve against `Bundle.main`, and the in-app picker
# reaches them through the `AppleLanguages` override, which is why `AppLanguage`
# is documented as requiring a restart. There is nothing here for this gate to
# enforce on them, and `check_localization_resolution.sh` is the gate that does
# cover them.
#
# Scoping the title matters because a broader one implies 100% coverage of a
# thing this script never looks at, and the repo already has one localization
# failure that shipped behind two green gates.
#
# `String(localized:)` and `NSLocalizedString(_:comment:)` default to
# `Bundle.main`. This app ships an in-app language picker, and that picker works
# by swapping the `.lproj` bundle behind `LanguageManager.appBundle` — so a
# lookup without `bundle:` silently ignores the user's choice and renders in the
# device language instead.
#
# It fails silently in the worst way: the string still appears, still looks
# right to a developer running in English, and the key still shows 100%
# translated in `check_localization_coverage.sh` — because the translation
# exists, it is just never read. Such a site carries complete translations in
# all 16 locales that no user can ever see.
#
# Coverage measures whether a translation exists. This measures whether it is
# reachable.

# SCOPE — `EmuquWatch Watch App` is deliberately NOT scanned, and this is the
# one gate where that is correct rather than an oversight.
#
# The watch target's `String(localized:)` calls carry no `bundle:`, and adding
# one would be wrong, not right: `LanguageManager` lives in the iOS target and
# is unreachable from watchOS, and the in-app picker works by writing
# `AppleLanguages` into the *phone* app's defaults, which has no effect on a
# separate watchOS process. A watch app follows the system language. There is
# nothing here for this gate to enforce.
#
# What the watch target DOES need is the catalogue in its own Resources, and it
# had none — so all 99 of its localized literals fell back to their English keys
# in every locale while three localization gates reported perfect scores. That
# is `check_localization_resolution.sh`'s job, and it now scans both targets.
SOURCE_ROOT="${1:-Emuqu/Sources}"

offenders="$(
    python3 - "$SOURCE_ROOT" <<'PY'
import os
import re
import sys

root = sys.argv[1]

# A lookup is fine if `bundle:` appears within the same call.
#
# The call extent is found by matching parentheses from the opening one, with
# string literals treated as opaque so interpolation parens and any bracket
# inside a translated string cannot throw the count off. A single-line test —
# `call on this line and no bundle: on this line` — does not MISS a multi-line
# call, it REPORTS a correctly-written one: a `String(localized:)` split across
# two lines to keep it readable fails the gate while the bundle argument sits
# right there on the next line. True positives are unaffected: a call that
# genuinely names no bundle still has none anywhere between its parentheses.
call = re.compile(r'(String\(localized:|NSLocalizedString\()')
bundle = re.compile(r'\bbundle:')


def mask_literals(text):
    """Same text, with the inside of every string literal blanked out.

    Index-preserving, so positions found in the mask are valid in the original.
    Everything downstream — paren matching and the `bundle:` search — runs on
    the mask, so neither interpolation parens nor a translated string that
    happens to contain the word "bundle:" can be mistaken for code. That second
    case is a false NEGATIVE, which is the dangerous direction: it would let an
    unqualified lookup through.
    """
    out, i, n = [], 0, len(text)
    while i < n:
        ch = text[i]
        if ch != '"':
            out.append(ch)
            i += 1
            continue
        if text.startswith('\"\"\"', i):
            end = text.find('\"\"\"', i + 3)
            end = n if end == -1 else end + 3
        else:
            j = i + 1
            while j < n and text[j] != '"':
                j += 2 if text[j] == '\\' else 1
            end = min(j + 1, n)
        # Keep newlines so line numbers still line up.
        out.append(''.join(c if c == '\n' else ' ' for c in text[i:end]))
        i = end
    return ''.join(out)


def call_extent(masked, open_paren):
    """End index of the call whose '(' is at `open_paren`, counting on the mask."""
    depth = 0
    for i in range(open_paren, len(masked)):
        if masked[i] == '(':
            depth += 1
        elif masked[i] == ')':
            depth -= 1
            if depth == 0:
                return i + 1
    return len(masked)


hits = []
for dirpath, _dirnames, filenames in os.walk(root):
    for name in filenames:
        if not name.endswith(".swift"):
            continue
        path = os.path.join(dirpath, name)
        with open(path, encoding="utf-8", errors="replace") as handle:
            text = handle.read()
        masked = mask_literals(text)
        for match in call.finditer(masked):
            line_start = masked.rfind("\n", 0, match.start()) + 1
            if masked[line_start:match.start()].lstrip().startswith("//"):
                continue
            open_paren = masked.index("(", match.start())
            if bundle.search(masked[match.start():call_extent(masked, open_paren)]):
                continue
            lineno = text.count("\n", 0, match.start()) + 1
            snippet = text[line_start:text.find("\n", match.start())].strip()
            hits.append(f"{path}:{lineno}: {snippet[:120]}")

for hit in hits:
    print(hit)
PY
)"

if [[ -n "$offenders" ]]; then
    echo "ERROR: localized-string lookups without an explicit bundle:" >&2
    echo "$offenders" >&2
    echo >&2
    echo "These read from Bundle.main and therefore ignore the in-app language" >&2
    echo "picker. Add 'bundle: LanguageManager.appBundle' to each call." >&2
    exit 1
fi

count="$(grep -rEo 'String\(localized:|NSLocalizedString\(' "$SOURCE_ROOT" --include='*.swift' | wc -l | tr -d ' ')"
echo "check_localization_bundle: clean. ${count} lookups, all bundle-qualified."
