#!/usr/bin/env bash
#
# CI guard: every translation passes its arguments in the order the code
# supplies them.
#
# Why this exists. `String(localized: "\(minutes)-minute \(sport)")` looks up
# the key "%lld-minute %@" and formats the translation with the arguments in
# the ENGLISH order: an integer, then an object. Ten keys shipped with
# translations that reorder those specifiers without numbering them — Spanish
# "%@ de %lld minutos" — so the formatter reads the integer as an object
# pointer. That is not a garbled string: it segfaults. Exporting a workout PDF
# crashed in seven languages and the live chat header in three, while all four
# localization gates read 100% — coverage, bundle, resolution and orphans all
# measure whether a translation exists, none whether it can be formatted.
#
# A translation may reorder its arguments only with positional specifiers
# ("%2$@ de %1$lld minutos"). This gate resolves every specifier in every
# translation to the argument position it reads and fails when that position's
# type differs from the English one, or when it reads a position English never
# supplies. A translation may leave an argument out: the formatter ignores
# unread trailing arguments, so that is a wording choice, not a crash.
#
# Plural and device variations are checked the same way, against the English
# form of the same variation when there is one.

set -euo pipefail

CATALOGUE="${1:-Emuqu/Localizable.xcstrings}"

if [[ ! -f "$CATALOGUE" ]]; then
    echo "check_localization_format_args: catalogue not found: $CATALOGUE" >&2
    exit 2
fi

python3 - "$CATALOGUE" <<'PY'
import json
import re
import sys

path = sys.argv[1]
with open(path, encoding="utf-8") as fh:
    catalogue = json.load(fh)

source = catalogue.get("sourceLanguage", "en")
# No space flag: "% of consecutive pairs" is prose, and Swift interpolation never
# emits a space-flagged specifier.
SPEC = re.compile(
    r"%(?:(\d+)\$)?[-+#0']*(?:\d+|\*)?(?:\.(?:\d+|\*))?(hh|h|ll|l|q|L|z|t|j)?([@dDiuUxXoOfFeEgGaAcCsSp%])"
)
INTEGER = set("dDiuUxXoOcC")
FLOAT = set("fFeEgGaA")


def kind(conv):
    if conv == "@":
        return "object"
    if conv in INTEGER:
        return "integer"
    if conv in FLOAT:
        return "float"
    if conv in "sS":
        return "cstring"
    return "pointer"


def arguments(text):
    """Map argument position -> type for every specifier the text reads."""
    positions = {}
    sequential = 0
    for match in SPEC.finditer(text):
        explicit, _, conv = match.groups()
        if conv == "%":
            continue
        if explicit:
            position = int(explicit)
        else:
            sequential += 1
            position = sequential
        positions.setdefault(position, set()).add(kind(conv))
    return positions


def units(localization):
    """Yield (variation label, value) for a localization, flattening variations."""
    if not localization:
        return
    unit = localization.get("stringUnit")
    if unit and unit.get("value") is not None:
        yield "", unit["value"]
    for family, cases in (localization.get("variations") or {}).items():
        for case, nested in cases.items():
            for label, value in units(nested):
                yield f"{family}.{case}{('.' + label) if label else ''}", value


failures = []
for key, entry in catalogue["strings"].items():
    if entry.get("shouldTranslate") is False:
        continue
    localizations = entry.get("localizations") or {}
    english = dict(units(localizations.get(source))) or {"": key}
    default_english = english.get("", key)
    for locale, localization in localizations.items():
        if locale == source:
            continue
        for label, value in units(localization):
            reference = english.get(label, default_english)
            expected = arguments(reference)
            actual = arguments(value)
            for position, kinds in sorted(actual.items()):
                wanted = expected.get(position)
                if wanted is None:
                    failures.append((key, locale, label, f"reads argument {position}, which the code never passes", value))
                elif len(kinds) > 1 or kinds != wanted:
                    failures.append((key, locale, label,
                                     f"argument {position} is {'/'.join(sorted(wanted))} in English, read as {'/'.join(sorted(kinds))}",
                                     value))

if failures:
    print(f"check_localization_format_args: {len(failures)} translation(s) read an argument as the wrong type.\n", file=sys.stderr)
    for key, locale, label, why, value in failures:
        where = f"{locale}{(' ' + label) if label else ''}"
        print(f"  [{where}] {key!r}\n      {why}\n      translation: {value!r}", file=sys.stderr)
    print("\n  Reordered arguments need positional specifiers: \"%2$@ de %1$lld\".", file=sys.stderr)
    raise SystemExit(1)

print("check_localization_format_args: clean. Every translation reads its arguments as the types the code passes.")
PY
